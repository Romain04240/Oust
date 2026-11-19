import Foundation
import Testing
import Synchronization
import OustCore
import OustRules
import OustSafety
@testable import OustModel

@Suite("Analyse automatique de consultation") @MainActor
struct OverviewAutomationTests {
    @MainActor private struct Fixture {
        let root: URL
        let boot: VolumeDescriptor
        let other: VolumeDescriptor
        let model: AppModel
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-overview-\(UUID())")
            let bootRoot = root.appendingPathComponent("boot"), otherRoot = root.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: bootRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
            boot = VolumeDescriptor(name: "Local", mountURL: bootRoot, scanRoot: bootRoot, isBoot: true,
                isInternal: true, isRemovable: false, capacity: Capacity(total: 10000, available: 5000, availableForImportantUsage: 5000))
            other = VolumeDescriptor(name: "External", mountURL: otherRoot, scanRoot: otherRoot, isBoot: false,
                isInternal: false, isRemovable: true, capacity: boot.capacity)
            model = AppModel(home: bootRoot, defaults: OverviewMemoryDefaults(), disk: DiskIndexModel())
            model.volumes = [boot, other]
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func stop() async { let task = model.overviewAnalysisTask; model.stopOverviewAnalysis(); await task?.value }
    }

    @Test("Pas d'analyse au démarrage menu seul ; deux fenêtres réservent une tâche sans présélection")
    func admission() async throws {
        let f = try Fixture(); defer { f.remove() }
        #expect(!f.model.analysis.isRunning && f.model.overviewAnalysisTask == nil)
        f.model.requestOverviewAnalysis()
        let request = try #require(f.model.bootAnalysisRequest)
        f.model.requestOverviewAnalysis()
        #expect(f.model.bootAnalysisRequest?.id == request.id && !request.preselect)
        #expect(f.model.analysis.isRunning && f.model.canStopOverviewAnalysis)
        await f.stop()
        #expect(f.model.analysis == .idle && f.model.overviewAnalysisInterrupted)
        f.model.requestOverviewAnalysis()
        #expect(f.model.overviewAnalysisTask == nil)
        #expect(f.model.reserveBootAnalysis(f.boot, preselect: false) != nil)
        #expect(!f.model.overviewAnalysisInterrupted)
        f.model.bootAnalysisRequest = nil; f.model.analysis = .idle
    }

    @Test("Un disque absent attend une disponibilité locale ; le disque externe reste manuel")
    func localReadiness() async throws {
        let f = try Fixture(); defer { f.remove() }
        f.model.volumes = []
        f.model.requestOverviewAnalysis()
        #expect(f.model.overviewAnalysisTask == nil && !f.model.overviewAnalysisStarted)
        f.model.volumes = [f.boot, f.other]
        f.model.analysisVolumeID = f.other.id
        f.model.drainOverviewAnalysisRequest()
        #expect(f.model.overviewAnalysisTask == nil)
        f.model.analysisVolumeID = nil
        f.model.drainOverviewAnalysisRequest()
        #expect(f.model.bootAnalysisRequest?.volume?.id == f.boot.id)
        await f.stop()
    }

    @Test("Une analyse manuelle terminée satisfait la demande automatique")
    func manualSuccess() throws {
        let f = try Fixture(); defer { f.remove() }
        f.model.volumeAnalysisDates[f.boot.id] = Date()
        f.model.requestOverviewAnalysis()
        #expect(f.model.overviewAnalysisStarted && f.model.overviewAnalysisTask == nil)
    }

    @Test("Une analyse occupée reste seule ; sa fin peut admettre la demande en attente")
    func busy() async throws {
        let f = try Fixture(); defer { f.remove() }
        f.model.analysis = .running
        f.model.analyzingVolumeID = f.other.id
        f.model.requestOverviewAnalysis()
        #expect(f.model.overviewAnalysisTask == nil)
        f.model.analyzingVolumeID = nil
        f.model.analysis = .idle
        #expect(f.model.bootAnalysisRequest?.volume?.id == f.boot.id)
        await f.stop()
    }

    @Test("Le remplacement du dossier pendant une attente invalide les résultats")
    func replacedRoot() async throws {
        let f = try Fixture(); defer { f.remove() }
        let request = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false))
        let location = try #require(AnalysisReview.Location(f.boot.scanRoot))
        #expect(await f.model.isCurrentBootAnalysis(request, location: location))
        try FileManager.default.moveItem(at: f.boot.scanRoot, to: f.root.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: f.boot.scanRoot, withIntermediateDirectories: true)
        #expect(!(await f.model.isCurrentBootAnalysis(request, location: location)))
        f.model.bootAnalysisRequest = nil
        f.model.analysis = .idle
    }

    @Test("Une lecture distante suspendue ne retarde pas le disque local ni l’admission")
    func remoteInventoryDoesNotBlock() async throws {
        let f = try Fixture(); defer { f.remove() }
        let suspended = Mutex<CheckedContinuation<[VolumeDescriptor], Never>?>(nil)
        let returned = await f.model.refreshVolumeInventory(waitForOtherVolumes: false, generation: f.model.mountGeneration,
            readStartup: { f.boot }, readVolumes: {
                await withCheckedContinuation { continuation in suspended.withLock { $0 = continuation } }
            })
        #expect(!returned && f.model.bootVolume?.id == f.boot.id)
        f.model.requestOverviewAnalysis()
        #expect(f.model.bootAnalysisRequest?.volume?.id == f.boot.id)
        await f.stop()
        for _ in 0..<100 where suspended.withLock({ $0 == nil }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let continuation = try #require(suspended.withLock { value in let result = value; value = nil; return result })
        continuation.resume(returning: [f.boot, f.other])
    }

    @Test("Une ancienne génération ne publie pas dans une nouvelle analyse")
    func generation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let old = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false))
        let location = try #require(AnalysisReview.Location(f.boot.scanRoot))
        f.model.bootAnalysisRequest = nil; f.model.analysis = .idle
        let current = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false))
        #expect(!(await f.model.isCurrentBootAnalysis(old, location: location)))
        #expect(await f.model.isCurrentBootAnalysis(current, location: location))
        f.model.volumes = [f.other]
        #expect(!(await f.model.isCurrentBootAnalysis(current, location: location)))
        f.model.bootAnalysisRequest = nil; f.model.analysis = .idle
    }

    @Test("Une action réellement sélectionnable reste décochée après la collecte automatique")
    func selectableToolRemainsUnselected() async throws {
        let f = try Fixture(); defer { f.remove() }
        let marker = f.boot.scanRoot.appendingPathComponent("Library/Caches/Homebrew/api/formula.jws.json")
        let target = f.boot.scanRoot.appendingPathComponent("Cellar/fixture/old")
        let executable = f.boot.scanRoot.appendingPathComponent("bin/brew").path
        for url in [marker, target] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 53, count: 16384).write(to: url)
        }
        let calls = Mutex<[[String]]>([])
        let tools = ToolRunner(locate: { candidates in candidates.contains { $0.hasSuffix("/bin/brew") } ? executable : nil },
            run: { _, arguments, _, _ in
                calls.withLock { $0.append(arguments) }
                guard arguments == ["cleanup", "--dry-run"] else { return .notRun }
                return CommandResult(status: 0, stdout: Data("Would remove: \(target.path)".utf8), stderr: Data(), timedOut: false)
            })
        let context = RuleContext(home: f.boot.scanRoot, projectRoots: [], processes: ProcessSnapshot(processes: []),
            applications: f.root, systemLibrary: f.root, sharedFolder: f.root, temporaryDirectory: f.root,
            tools: tools, runningApps: [])
        let request = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false))
        await f.model.runBootAnalysis(request, context: context, finders: [.toolCleanups])
        let item = try #require(f.model.items.values.first { $0.ruleID == "tool.brew_cleanup" })
        #expect(f.model.canSelectForCleanup(item) && PreselectionPolicy().preselects(item))
        #expect(f.model.cart.isEmpty && calls.withLock { $0 } == [["cleanup", "--dry-run"]])
        #expect(try Data(contentsOf: target) == Data(repeating: 53, count: 16384))
        f.model.toggle(item)
        #expect(f.model.cart == [item.id])
        let second = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false))
        await f.model.runBootAnalysis(second, context: context, finders: [.toolCleanups])
        #expect(f.model.cart == [item.id])
    }

    @Test("La vraie collecte sur fichiers fictifs ne sélectionne rien et conserve le choix externe")
    func pipeline() async throws {
        let f = try Fixture(); defer { f.remove() }
        let cache = f.boot.scanRoot.appendingPathComponent(".npm/_cacache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("fixture"); try Data(repeating: 7, count: 8192).write(to: file)
        let chosen = CleanupItem(title: "Fixture", paths: [f.other.scanRoot.appendingPathComponent("keep")],
            category: .projectArtifacts, owner: "", ruleID: "fixture", safety: .safe,
            method: .simulatorDevice(udid: "fixture-never-executed"), sizes: .zero, rebuild: .automatic)
        f.model.items[chosen.id] = chosen; f.model.cart = [chosen.id]
        let request = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false))
        let context = RuleContext(home: f.boot.scanRoot, projectRoots: [], applications: f.root,
            systemLibrary: f.root, sharedFolder: f.root, temporaryDirectory: f.root, tools: .none, runningApps: [])
        await f.model.runBootAnalysis(request, context: context, finders: [.packageCaches])
        #expect(f.model.analysis.hasRun && f.model.volumeAnalysisDates[f.boot.id] != nil)
        #expect(f.model.items.values.contains { $0.paths.contains { $0.path == cache.path } })
        #expect(f.model.cart == [chosen.id] && f.model.cleaning == .idle)
        #expect(try Data(contentsOf: file) == Data(repeating: 7, count: 8192))
        #expect(!f.model.canMoveFiles && AnalysisReview.estimatedGain == 0)
    }
}

private final class OverviewMemoryDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey key: String) -> Any? { nil }
    override func data(forKey key: String) -> Data? { nil }
    override func stringArray(forKey key: String) -> [String]? { nil }
    override func bool(forKey key: String) -> Bool { false }
    override func set(_ value: Any?, forKey key: String) {}
}
