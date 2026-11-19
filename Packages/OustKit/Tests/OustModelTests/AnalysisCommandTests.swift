import Foundation
import Synchronization
import Testing
import OustCore
import OustRules
import OustSafety
import OustScan
@testable import OustModel

@Suite("La commande d’analyse garde la section du clic") @MainActor
struct AnalysisCommandTests {
    @Test("La Vue d’ensemble reste sans présélection ; l’analyse manuelle conserve ses choix automatiques",
          arguments: [AppSection.overview, .developer], [false, true])
    func capturedSection(_ clicked: AppSection, _ navigateBeforeExecution: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let model = fixture.model
        model.section = clicked
        let captured = model.section
        let capturedSearch = model.isSearching
        let work = Task {
            await model.performAnalysisCommand(from: captured, isSearching: capturedSearch,
                                               overview: { await fixture.collect(preselect: false) },
                                               manual: { await fixture.collect(preselect: true) })
        }
        let destination: AppSection = navigateBeforeExecution ? (clicked == .overview ? .developer : .overview) : clicked
        model.section = destination
        if navigateBeforeExecution { model.searchText = "Recherche après le clic" }
        await work.value

        let item = try #require(model.items.values.first { $0.ruleID == "tool.brew_cleanup" })
        #expect(model.canSelectForCleanup(item) && PreselectionPolicy(recencyDays: model.preferences.recencyDays).preselects(item))
        #expect(model.cart == (clicked == .overview ? [] : [item.id]))
        #expect(model.analysis.hasRun && model.section == destination && model.cleaning == .idle)
        #expect(model.isSearching == navigateBeforeExecution)
        #expect(fixture.calls.values == [["cleanup", "--dry-run"]])
        #expect(try Data(contentsOf: fixture.file) == Data(repeating: 53, count: 16_384))
        var forbidden = item; forbidden.method = .trash
        #expect(!model.canSelectForCleanup(forbidden) && !model.canMoveFiles)
    }

    @Test("Depuis la recherche, les deux sections d’origine gardent l’analyse manuelle même après navigation",
          arguments: [AppSection.overview, .developer], [false, true])
    func searchKeepsManualPolicy(_ origin: AppSection, _ navigateBeforeExecution: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let model = fixture.model
        model.section = origin
        model.searchText = "Recherche fictive"
        let captured = model.section
        let capturedSearch = model.isSearching
        #expect(capturedSearch)
        let work = Task {
            await model.performAnalysisCommand(from: captured, isSearching: capturedSearch,
                                               overview: { await fixture.collect(preselect: false) },
                                               manual: { await fixture.collect(preselect: true) })
        }
        let destination: AppSection = navigateBeforeExecution ? (origin == .overview ? .developer : .overview) : origin
        if navigateBeforeExecution {
            model.searchText = ""
            model.section = destination
        }
        await work.value

        let item = try #require(model.items.values.first { $0.ruleID == "tool.brew_cleanup" })
        #expect(model.canSelectForCleanup(item) && PreselectionPolicy(recencyDays: model.preferences.recencyDays).preselects(item))
        #expect(model.cart == [item.id] && model.analysis.hasRun && model.cleaning == .idle)
        #expect(model.section == destination && model.isSearching == !navigateBeforeExecution)
        #expect(fixture.calls.values == [["cleanup", "--dry-run"]])
        #expect(try Data(contentsOf: fixture.file) == Data(repeating: 53, count: 16_384))
        var forbidden = item; forbidden.method = .trash
        #expect(!model.canSelectForCleanup(forbidden) && !model.canMoveFiles)
    }

    @MainActor private struct Fixture {
        let root: URL
        let boot: VolumeDescriptor
        let model: AppModel
        let file: URL
        let brew: String
        let calls = RecordedCalls()

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("oust-analysis-command-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
            let home = root.appendingPathComponent("boot", isDirectory: true)
            let file = home.appendingPathComponent("Cellar/fixture/old.bin")
            let marker = home.appendingPathComponent("Library/Caches/Homebrew/api/formula.jws.json")
            do {
                for url in [file, marker] {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(repeating: 53, count: 16_384).write(to: url)
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
            self.root = root
            self.file = file
            self.brew = home.appendingPathComponent("bin/brew").path
            self.boot = VolumeDescriptor(name: "Local fictif", mountURL: home, scanRoot: home, isBoot: true,
                                         isInternal: true, isRemovable: false,
                                         capacity: Capacity(total: 100_000_000, available: 40_000_000,
                                                            availableForImportantUsage: 50_000_000))
            self.model = AppModel(home: home, defaults: CommandDefaults(),
                                  disk: DiskIndexModel(store: TreeStore(directory: root.appendingPathComponent("Index"))))
            model.volumes = [boot]
        }

        func collect(preselect: Bool) async {
            guard let request = model.reserveBootAnalysis(boot, preselect: preselect) else {
                Issue.record("La collecte fictive doit être admise.")
                return
            }
            let brew = brew, file = file, calls = calls
            let tools = ToolRunner(locate: { $0.contains { $0.hasSuffix("/bin/brew") } ? brew : nil },
                                   run: { _, arguments, _, _ in
                calls.append(arguments)
                guard arguments == ["cleanup", "--dry-run"] else { return .notRun }
                return CommandResult(status: 0, stdout: Data("Would remove: \(file.path)".utf8),
                                     stderr: Data(), timedOut: false)
            })
            let context = RuleContext(home: boot.scanRoot, projectRoots: [], processes: ProcessSnapshot(processes: []),
                                      applications: root, systemLibrary: root, sharedFolder: root,
                                      temporaryDirectory: root, tools: tools, runningApps: [])
            await model.runBootAnalysis(request, context: context, finders: [.toolCleanups])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class RecordedCalls: Sendable {
    private let storage = Mutex<[[String]]>([])
    var values: [[String]] { storage.withLock { $0 } }
    func append(_ arguments: [String]) { storage.withLock { $0.append(arguments) } }
}

private final class CommandDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey key: String) -> Any? { nil }
    override func data(forKey key: String) -> Data? { nil }
    override func stringArray(forKey key: String) -> [String]? { nil }
    override func bool(forKey key: String) -> Bool { false }
    override func set(_ value: Any?, forKey key: String) {}
}
