import Foundation
import Synchronization
import Testing
import OustCore
import OustRules
import OustScan
import OustSafety
@testable import OustModel

@Suite("Régressions de la revue compacte") @MainActor
struct OverviewCorrectionsTests {
    @MainActor private struct Fixture {
        let root: URL
        let boot: VolumeDescriptor
        let external: VolumeDescriptor
        let model: AppModel
        let file: URL
        let brew: String
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-overview-corrections-\(UUID())").resolvingSymlinksInPath()
            let home = root.appendingPathComponent("boot"), other = root.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let marker = home.appendingPathComponent("Library/Caches/Homebrew/api/formula.jws.json")
            file = home.appendingPathComponent("Cellar/fixture/old.bin")
            for url in [marker, file] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 53, count: 16384).write(to: url)
            }
            brew = home.appendingPathComponent("bin/brew").path
            let capacity = Capacity(total: 100_000_000, available: 40_000_000, availableForImportantUsage: 50_000_000)
            boot = VolumeDescriptor(name: "Local", mountURL: home, scanRoot: home, isBoot: true,
                isInternal: true, isRemovable: false, capacity: capacity)
            external = VolumeDescriptor(name: "External", mountURL: other, scanRoot: other, isBoot: false,
                isInternal: false, isRemovable: true, capacity: capacity)
            model = AppModel(home: home, defaults: CorrectionsDefaults(),
                disk: DiskIndexModel(store: TreeStore(directory: root.appendingPathComponent("Index"))))
            model.volumes = [boot, external]
        }
        var chosen: CleanupItem {
            CleanupItem(id: "brew-cleanup|\(brew)", title: "Fixture", paths: [file], category: .toolVersions,
                owner: "Fixture", ruleID: "tool.brew_cleanup", safety: .safe,
                method: .brewCleanup(executable: brew), sizes: Sizes(private: 16384), rebuild: .nothing)
        }
        func context(_ gate: PausedRead? = nil) -> RuleContext {
            let brew = brew, file = file
            let tools = ToolRunner(locate: { $0.contains { $0.hasSuffix("/bin/brew") } ? brew : nil },
                run: { _, args, _, _ in
                    guard args == ["cleanup", "--dry-run"] else { return .notRun }
                    #expect(CommandCancellationContext.cancelsReadOnlyCommands)
                    if let gate { await gate.wait() }
                    return CommandResult(status: 0, stdout: Data("Would remove: \(file.path)".utf8), stderr: Data(), timedOut: false)
                })
            return RuleContext(home: boot.scanRoot, projectRoots: [], processes: ProcessSnapshot(processes: []),
                applications: root, systemLibrary: root, sharedFolder: root, temporaryDirectory: root,
                tools: tools, runningApps: [])
        }
        func start(_ context: RuleContext, finders: [FinderKind] = [.toolCleanups], preselect: Bool = false,
                   browser: (@MainActor @Sendable () async -> BrowserAnalysisSnapshot?)? = nil) throws -> Task<Void, Never> {
            let request = try #require(model.reserveBootAnalysis(boot, preselect: preselect))
            let task = AppModel.backgroundStorageTask {
                defer { model.overviewAnalysisTask = nil }
                await model.runBootAnalysis(request, context: context, finders: finders, readBrowsers: browser)
            }
            model.overviewAnalysisTask = task
            return task
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Arrêter garde l'admission et les choix jusqu'au retrait du worker", arguments: ["keep", "uncheck", "veto"])
    func stopOwnsWorkerAndCart(_ change: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let gate = PausedRead(); defer { gate.release() }
        f.model.items[f.chosen.id] = f.chosen; f.model.cart = [f.chosen.id]
        let work = try f.start(f.context(gate))
        try await gate.waitUntilEntered()
        #expect(f.model.cartItems.map(\.id) == [f.chosen.id])
        f.model.analysisVolumeID = f.external.id
        #expect(!f.model.canStopOverviewAnalysis(on: f.external))
        f.model.stopOverviewAnalysis(on: f.external)
        #expect(!f.model.overviewAnalysisStopping && f.model.analysis.isRunning)
        f.model.stopOverviewAnalysis(on: f.boot)
        #expect(f.model.overviewAnalysisStopping)
        #expect(f.model.reserveBootAnalysis(f.boot, preselect: false) == nil)
        await f.model.analyzeOtherVolume(f.external)
        #expect(f.model.analyzingVolumeID == f.boot.id && gate.active == 1)
        if change == "uncheck" { f.model.toggle(f.chosen) }
        if change == "veto" { f.model.items[f.chosen.id]?.protect(.inUse) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.model.analysis.isRunning && f.model.canStopOverviewAnalysis(on: f.boot))
        gate.release(); await work.value
        #expect(gate.active == 0 && f.model.analysis == .idle && f.model.overviewAnalysisInterrupted)
        #expect(f.model.volumeAnalysisDates[f.boot.id] == nil && f.model.analysisReview(for: f.boot) == nil)
        #expect(f.model.cartItems.map(\.id) == (change == "keep" ? [f.chosen.id] : []))
        #expect(f.model.cart == (change == "keep" ? [f.chosen.id] : []))
        #expect(try Data(contentsOf: f.file) == Data(repeating: 53, count: 16384))
        if change != "veto" {
            let retry = try f.start(f.context()); await retry.value
            #expect(f.model.analysis.hasRun && !f.model.overviewAnalysisStopping)
            #expect(f.model.cartItems.map(\.id) == (change == "keep" ? [f.chosen.id] : []))
        }
        var forbidden = f.chosen; forbidden.method = .trash
        #expect(!f.model.canSelectForCleanup(forbidden) && !f.model.canMoveFiles)
        #expect(f.model.cleaning == .idle)
    }

    @Test("Une collecte manuelle ne recochera pas une case décochée pendant l'attente")
    func manualPreselectionRespectsLiveChanges() async throws {
        let f = try Fixture(); defer { f.remove() }
        let gate = PausedRead(); defer { gate.release() }
        f.model.items[f.chosen.id] = f.chosen
        let work = try f.start(f.context(gate), preselect: true)
        try await gate.waitUntilEntered()
        f.model.toggle(f.chosen); f.model.toggle(f.chosen)
        #expect(f.model.cart.isEmpty)
        gate.release(); await work.value
        #expect(f.model.analysis.hasRun && f.model.items[f.chosen.id] != nil)
        #expect(f.model.cart.isEmpty && f.model.cleaning == .idle)
    }

    @Test("Une sélection admise sans gain chiffré garde l'accès au panier")
    func zeroGainSelectionCount() throws {
        let f = try Fixture(); defer { f.remove() }
        var item = f.chosen; item.sizes = .zero
        f.model.items[item.id] = item; f.model.toggle(item)
        #expect(f.model.cartCount(on: f.boot) == 1 && f.model.cartTotal(on: f.boot) == 0)
        #expect(f.model.cartCount(on: f.external) == 0 && f.model.cleaning == .idle)
        var forbidden = item; forbidden.method = .trash
        #expect(!f.model.canSelectForCleanup(forbidden))
    }

    @Test("Une lecture native retardée reste possédée après Arrêter")
    func delayedNativeRead() async throws {
        let f = try Fixture(); defer { f.remove() }
        let release = DispatchSemaphore(value: 0)
        let entered = Mutex(false)
        defer { release.signal() }
        let request = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false))
        let context = f.context()
        let work = AppModel.backgroundStorageTask {
            defer { f.model.overviewAnalysisTask = nil }
            await f.model.runBootAnalysis(request, context: context, finders: [], readLocation: { url in
                entered.withLock { $0 = true }
                release.wait()
                return AnalysisReview.Location(url)
            })
        }
        f.model.overviewAnalysisTask = work
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(entered.withLock { $0 })
        f.model.stopOverviewAnalysis(on: f.boot)
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.model.analysis.isRunning && f.model.overviewAnalysisStopping)
        #expect(f.model.reserveBootAnalysis(f.boot, preselect: false) == nil)
        release.signal(); await work.value
        #expect(f.model.analysis == .idle && f.model.items.isEmpty && f.model.overviewAnalysisInterrupted)
        #expect(f.model.volumeAnalysisDates[f.boot.id] == nil && !f.model.canMoveFiles)
    }

    @Test("Une ancienne mesure navigateur ne publie pas dans une autre génération")
    func lateBrowserGeneration() async throws {
        let f = try Fixture(); defer { f.remove() }
        let gate = PausedRead(); defer { gate.release() }
        var old = f.chosen; old.category = .browsers; old.sizes = Sizes(private: 900)
        let oldSnapshot = BrowserAnalysisSnapshot(profiles: [], items: [old])
        let pendingFirst = f.model.startBrowserRefresh(read: { await gate.wait(); return oldSnapshot })
        let first = try #require(pendingFirst)
        try await gate.waitUntilEntered()
        var fresh = old; fresh.sizes = Sizes(private: 100); fresh.protect(.inUse)
        let snapshot = BrowserAnalysisSnapshot(profiles: [], items: [fresh])
        let pendingSecond = f.model.startBrowserRefresh(read: { snapshot })
        let second = try #require(pendingSecond)
        #expect(f.model.items[old.id] == nil)
        gate.release(); await first.value; await second.value
        #expect(f.model.items[old.id] == fresh && gate.active == 0)
        #expect(!f.model.canSelectForCleanup(fresh))
    }

    @Test("L'arrêt pendant la mesure navigateur attend puis ignore la réponse")
    func cancelledBrowserResult() async throws {
        let f = try Fixture(); defer { f.remove() }
        let gate = PausedRead(); defer { gate.release() }
        let snapshot = BrowserAnalysisSnapshot(profiles: [], items: [f.chosen])
        let work = try f.start(f.context(), finders: [], browser: { await gate.wait(); return snapshot })
        try await gate.waitUntilEntered()
        f.model.stopOverviewAnalysis(on: f.boot)
        #expect(f.model.reserveBootAnalysis(f.boot, preselect: false) == nil)
        #expect(f.model.analysis.isRunning)
        gate.release(); await work.value
        #expect(f.model.items.isEmpty && f.model.cart.isEmpty && gate.active == 0)
        #expect(f.model.volumeAnalysisDates[f.boot.id] == nil && f.model.cleaning == .idle)
    }

    @Test("Un dossier remplacé après collecte ne publie pas ses résultats tardifs")
    func rootReplacedDuringCollection() async throws {
        let f = try Fixture(); defer { f.remove() }
        let gate = PausedRead(); defer { gate.release() }
        let work = try f.start(f.context(gate)); try await gate.waitUntilEntered()
        try FileManager.default.moveItem(at: f.boot.scanRoot, to: f.root.appendingPathComponent("previous"))
        try FileManager.default.createDirectory(at: f.boot.scanRoot, withIntermediateDirectories: true)
        gate.release(); await work.value
        #expect(f.model.items.isEmpty && f.model.volumeAnalysisDates[f.boot.id] == nil)
        #expect(f.model.overviewAnalysisInterrupted && !f.model.canMoveFiles)
    }

    @Test("L'actualisation locale produit une répartition sans remplir le panier")
    func explicitClassificationRefresh() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = f.boot.scanRoot.appendingPathComponent("document.txt")
        try Data(repeating: 42, count: 700_000).write(to: document)
        f.model.analysis = .running
        f.model.refreshStorageClassification(for: f.boot)
        #expect(!f.model.isRefreshingStorageClassification(for: f.boot))
        f.model.analysis = .idle
        f.model.refreshStorageClassification(for: f.boot)
        #expect(f.model.isRefreshingStorageClassification(for: f.boot))
        let scan = await f.model.disk.refresh().value
        #expect(scan != nil)
        let fresh = await f.model.storageClassification(for: f.boot)
        #expect(fresh.hasClassification && fresh.date == scan?.scannedAt)
        #expect(!fresh.breakdown.observed.isEmpty && f.model.cart.isEmpty && f.model.cleaning == .idle)
        #expect(f.model.section == .overview && !f.model.canMoveFiles)
        #expect(try Data(contentsOf: document) == Data(repeating: 42, count: 700_000))
        // Attendre l'export atomique du petit index fictif avant son retrait.
        let deadline = ContinuousClock.now + .seconds(1)
        while !FileManager.default.fileExists(atPath: f.model.disk.store.directory.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("La répartition absente et sa date ne deviennent pas une collecte récente")
    func classificationSource() async throws {
        let f = try Fixture(); defer { f.remove() }
        f.model.volumeAnalysisDates[f.boot.id] = Date()
        let missing = await f.model.storageClassification(for: f.boot)
        #expect(!missing.hasClassification && missing.date == nil && missing.breakdown.observed.isEmpty)
        try Data(repeating: 84, count: 700_000).write(to: f.external.scanRoot.appendingPathComponent("document.txt"))
        let index = await ScanIndex.refresh(nil, root: f.external.scanRoot, options: ScanOptions()).index
        f.model.volumeIndexes[f.external.id] = index
        f.model.volumeAnalysisDates[f.external.id] = index.scannedAt.addingTimeInterval(3600)
        let classified = await f.model.storageClassification(for: f.external)
        #expect(classified.hasClassification && classified.date == index.scannedAt)
        #expect(classified.date != f.model.volumeAnalysisDates[f.external.id])
        #expect(!classified.breakdown.observed.isEmpty)
        f.model.volumeIndexes.removeValue(forKey: f.external.id)
        #expect(classified.hasClassification && classified.date == index.scannedAt)
        #expect(!f.model.canMoveFiles && f.model.cart.isEmpty && f.model.cleaning == .idle)
    }
}

private final class PausedRead: Sendable {
    private let state = Mutex((active: 0, entered: 0, released: false, waiters: [CheckedContinuation<Void, Never>]()))
    var active: Int { state.withLock { $0.active } }
    func wait() async {
        await withCheckedContinuation { c in state.withLock {
            $0.entered += 1
            if $0.released { c.resume() } else { $0.active += 1; $0.waiters.append(c) }
        } }
        state.withLock { if $0.active > 0 { $0.active -= 1 } }
    }
    func release() {
        let waiting = state.withLock { s in s.released = true; let result = s.waiters; s.waiters = []; return result }
        waiting.forEach { $0.resume() }
    }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while state.withLock({ $0.entered == 0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(state.withLock { $0.entered > 0 })
    }
}

private final class CorrectionsDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey key: String) -> Any? { nil }
    override func data(forKey key: String) -> Data? { nil }
    override func stringArray(forKey key: String) -> [String]? { nil }
    override func bool(forKey key: String) -> Bool { false }
    override func set(_ value: Any?, forKey key: String) {}
}
