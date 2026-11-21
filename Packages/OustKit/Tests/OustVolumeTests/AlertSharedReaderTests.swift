import Foundation
import Testing
import OustCore
@testable import OustVolume
private actor SharedReadGate {
    var started = false; var open = false; var calls = 0
    var waiter: CheckedContinuation<Void, Never>?; var ready: CheckedContinuation<Void, Never>?
    func read(_ v: VolumeDescriptor) async -> SharedAlertSnapshotReader.Snapshot? {
        calls += 1; started = true; ready?.resume(); ready = nil
        if !open { await withCheckedContinuation { waiter = $0 } }
        return ("qa",v)
    }
    func entered() async { if !started { await withCheckedContinuation { ready = $0 } } }
    func finish() { open = true; waiter?.resume(); waiter = nil }
}
@Suite struct AlertSharedReaderTests {
    @Test func twoConsumersShareOneReadWithoutFalseInvalidation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fictif.bin"); try Data([1,2]).write(to: file)
        let v = VolumeDescriptor(name: "QA", mountURL: dir, scanRoot: dir, isBoot: false, isInternal: false, isRemovable: true, capacity: Capacity(total: 1000,available: 10,availableForImportantUsage: 10))
        let reader = SharedAlertSnapshotReader(), gate = SharedReadGate()
        let first = Task { await reader.read(v) { await gate.read($0) } }
        await gate.entered()
        let second = Task { await reader.read(v) { await gate.read($0) } }
        // Laisser l'acteur inscrire le second consommateur avant de finir la lecture.
        try await Task.sleep(for: .milliseconds(20))
        await gate.finish()
        let a = await first.value; let b = await second.value; let calls = await gate.calls
        #expect(a?.uuid == "qa" && b?.uuid == "qa" && calls == 1)
        #expect(try Data(contentsOf: file) == Data([1,2]))
    }
}
