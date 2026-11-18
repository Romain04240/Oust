import Foundation
import Synchronization
import Testing
import OustCore
@testable import OustModel

@Suite("La propriété d’une analyse externe")
struct VolumeAnalysisOwnershipTests {
    @Test("L’admission réserve la phase et une expiration conserve le dernier résultat complet")
    @MainActor func admissionOwnsPhaseBeforeWaiting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-admission-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = volume(root.appendingPathComponent("externe", isDirectory: true), boot: false)
        let boot = volume(root.appendingPathComponent("demarrage", isDirectory: true), boot: true)
        let model = AppModel(home: root)
        model.volumes = [external, boot]
        let item = CleanupItem(title: "Ancien résultat", paths: [external.scanRoot.appendingPathComponent("cache")],
                               category: .projectArtifacts, owner: "", ruleID: "fixture.previous",
                               safety: .safe, method: .removeNow, sizes: Sizes(private: 4096), rebuild: .automatic)
        model.items[item.id] = item
        let previousDate = Date(timeIntervalSince1970: 1000)
        model.volumeAnalysisDates[external.id] = previousDate
        let gate = StorageTaskGate()
        let suspension = Mutex<CheckedContinuation<Void, Never>?>(nil)
        defer {
            suspension.withLock { value in
                value?.resume()
                value = nil
            }
        }
        let holder = Task {
            await gate.run(timeout: .seconds(2)) {
                await withCheckedContinuation { continuation in
                    suspension.withLock { $0 = continuation }
                }
            }
        }
        for _ in 0..<100 where suspension.withLock({ $0 == nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(suspension.withLock { $0 != nil })
        let request = Task { await model.analyzeOtherVolume(external, storageGate: gate, timeout: .milliseconds(200)) }
        for _ in 0..<100 where model.volumeAnalysisAttempt == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let attempt = try #require(model.volumeAnalysisAttempt)
        #expect(model.analysis.isRunning && model.analyzingVolumeID == external.id)

        await model.analyzeOtherVolume(external, storageGate: gate, timeout: .milliseconds(20))
        model.selectAnalysisVolume(boot)
        await model.analyze()
        #expect(model.volumeAnalysisAttempt == attempt)
        #expect(model.analysis.isRunning && model.analyzingVolumeID == external.id)
        await request.value
        #expect(!model.analysis.isRunning)
        #expect(model.volumeAnalysisAttempt == nil && model.analyzingVolumeID == nil)
        #expect(model.items[item.id] == item)
        #expect(model.volumeAnalysisDates[external.id] == previousDate)

        suspension.withLock { value in
            value?.resume()
            value = nil
        }
        await holder.value
    }

    private func volume(_ root: URL, boot: Bool) -> VolumeDescriptor {
        VolumeDescriptor(name: root.lastPathComponent, mountURL: root, scanRoot: root, isBoot: boot,
                         isInternal: boot, isRemovable: !boot,
                         capacity: Capacity(total: 100, available: 50, availableForImportantUsage: 50))
    }
}
