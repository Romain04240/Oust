import Foundation
import OustCore
import OustRules
import OustSafety
import OustScan
import Synchronization
import Testing
@testable import OustModel

@Suite("Admission commune de l'actualisation du stockage") @MainActor
struct StorageClassificationAdmissionTests {
    @MainActor private struct Fixture {
        let root: URL
        let file: URL
        let boot: VolumeDescriptor
        let external: VolumeDescriptor
        let model: AppModel
        let contents = Data(repeating: 61, count: 8192)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-classification-admission-\(UUID())")
                .resolvingSymlinksInPath()
            let home = root.appendingPathComponent("boot"), other = root.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            file = home.appendingPathComponent("fixture.bin")
            try Data(repeating: 61, count: 8192).write(to: file)
            let capacity = Capacity(total: 1_000_000, available: 400_000, availableForImportantUsage: 500_000)
            boot = VolumeDescriptor(name: "Local", mountURL: home, scanRoot: home, isBoot: true,
                isInternal: true, isRemovable: false, capacity: capacity)
            external = VolumeDescriptor(name: "External", mountURL: other, scanRoot: other, isBoot: false,
                isInternal: false, isRemovable: true, capacity: capacity)
            model = AppModel(home: home, defaults: ClassificationAdmissionDefaults(),
                disk: DiskIndexModel(store: TreeStore(directory: root.appendingPathComponent("Index"))))
            model.volumes = [boot, external]
        }

        func assertRefused(_ volume: VolumeDescriptor) async {
            let phase = model.explorer, displayedVolume = model.treeVolume, progress = model.scanProgress
            #expect(!model.canRefreshStorageClassification(for: volume))
            model.refreshStorageClassification(for: volume)
            #expect(!model.disk.isRefreshing && model.scanTask == nil && model.tree == nil)
            #expect(model.explorer == phase && model.treeVolume == displayedVolume && model.scanProgress === progress)
            #expect(model.cart.isEmpty && model.cleaning == .idle)
            // Même en cas de régression, aucun parcours lancé par ce test ne
            // doit continuer après le retrait de sa racine fictive.
            let diskWork = model.disk.isRefreshing ? model.disk.refresh() : nil
            let externalWork = model.scanTask
            if diskWork != nil || externalWork != nil {
                model.cancelExploration()
                await externalWork?.value
                _ = await diskWork?.value
            }
        }

        func context() -> RuleContext {
            RuleContext(home: boot.scanRoot, projectRoots: [], processes: ProcessSnapshot(processes: []),
                applications: root, systemLibrary: root, sharedFolder: root, temporaryDirectory: root,
                tools: .none, runningApps: [])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Une collecte réellement suspendue refuse les actualisations locale et externe")
    func collectionOwnsAdmission() async throws {
        let f = try Fixture(); defer { f.remove() }
        let entered = Mutex(false), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let request = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false))
        let context = f.context()
        let work = AppModel.backgroundStorageTask {
            await f.model.runBootAnalysis(request, context: context, finders: [], readLocation: { url in
                entered.withLock { $0 = true }
                release.wait()
                return AnalysisReview.Location(url)
            })
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(entered.withLock { $0 } && f.model.analysis.isRunning)
        await f.assertRefused(f.boot)
        await f.assertRefused(f.external)
        work.cancel()
        release.signal()
        await work.value
        #expect(f.model.analysis == .idle && f.model.disk.currentTree == nil)
        #expect(f.model.canRefreshStorageClassification(for: f.boot))
        #expect(try Data(contentsOf: f.file) == f.contents)
    }

    @Test("Un parcours externe en cours ne peut pas être remplacé par l'actualisation")
    func existingVolumeScanIsPreserved() async throws {
        let f = try Fixture(); defer { f.remove() }
        f.model.treeVolume = f.external
        f.model.explorer = .running
        await f.assertRefused(f.external)
        #expect(f.model.explorer == .running && f.model.treeVolume == f.external)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }

    @Test("Une ancienne fiche ne lance rien pour un volume absent, remplacé ou protégé",
          arguments: ["missingBoot", "missingExternal", "bootMount", "externalMount", "timeMachine"])
    func unavailableVolumeDoesNotStart(_ change: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let target = change == "missingBoot" || change == "bootMount" ? f.boot : f.external
        if change.hasPrefix("missing") {
            f.model.volumes.removeAll { $0.id == target.id }
        } else if change == "timeMachine" {
            f.model.timeMachineMounts.insert(PathNormalizer.normalize(f.external.mountURL.standardizedFileURL.path))
        } else {
            var replacement = target
            replacement.mountIdentity = VolumeMountIdentity(device: 7, inode: 202, createdSeconds: 2, createdNanoseconds: 0)
            f.model.volumes = f.model.volumes.map { $0.id == target.id ? replacement : $0 }
        }
        await f.assertRefused(target)
        #expect(f.model.disk.currentTree == nil && f.model.section == .overview)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }

    @Test("L'admission réserve immédiatement l'index et attend son retrait après annulation")
    func admittedRefreshReservesSynchronously() async throws {
        let f = try Fixture(); defer { f.remove() }
        #expect(f.model.canRefreshStorageClassification(for: f.boot))
        #expect(f.model.canRefreshStorageClassification(for: f.external))
        f.model.refreshStorageClassification(for: f.boot)
        let progress = f.model.scanProgress
        #expect(f.model.disk.isRefreshing && !f.model.canRefreshStorageClassification(for: f.boot))
        let pending = f.model.disk.refresh()
        f.model.refreshStorageClassification(for: f.boot)
        #expect(f.model.scanProgress === progress)
        // Annuler avant de rendre le fil principal évite tout parcours, export
        // d'index ou inventaire natif dans cette vérification d'admission.
        f.model.cancelExploration()
        #expect(f.model.disk.isRefreshing && !f.model.canRefreshStorageClassification(for: f.boot))
        let result = await pending.value
        #expect(result == nil && !f.model.disk.isRefreshing)
        #expect(f.model.canRefreshStorageClassification(for: f.boot))
        #expect(f.model.disk.currentTree == nil && f.model.tree == nil && f.model.cart.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.model.disk.store.directory.path))
        #expect(f.model.cleaning == .idle && !f.model.canMoveFiles)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }
}

private final class ClassificationAdmissionDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey key: String) -> Any? { nil }
    override func data(forKey key: String) -> Data? { nil }
    override func stringArray(forKey key: String) -> [String]? { nil }
    override func bool(forKey key: String) -> Bool { false }
    override func set(_ value: Any?, forKey key: String) {}
}
