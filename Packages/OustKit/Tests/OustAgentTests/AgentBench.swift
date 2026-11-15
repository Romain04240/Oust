import Foundation
import Synchronization
@testable import OustAgent
import OustClean
import OustCore
import OustRules
import OustSafety

/// Un Mac en miniature dans un dossier temporaire : dossier personnel, dossiers
/// de projets, corbeille, journal et aperçus à lui (RULES.md, règle 8). Rien
/// de la machine ne passe : ni ses outils, ni ses applications, ni ses processus.
final class AgentBench: Sendable {
    let root: URL
    var home: URL { root.appendingPathComponent("maison") }
    var projects: URL { home.appendingPathComponent("Developpement") }
    var trash: URL { root.appendingPathComponent("_corbeille") }
    var historyFolder: URL { root.appendingPathComponent("_historique") }
    var stateFolder: URL { root.appendingPathComponent("_etat") }

    /// Ce qui « tourne » sur ce Mac fictif, modifiable en cours de test.
    let processes = Mutex<[ActiveProcess]>([])
    /// Les processus qui « demandent » (l'agent, son shell).
    let requester = Mutex<Set<Int32>>([])
    let clock = Mutex<Date>(Date())

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-agent-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("maison/Developpement"),
                                                withIntermediateDirectories: true)
    }

    deinit {
        // Un test peut avoir fermé le journal en écriture : on le rouvre pour pouvoir tout retirer.
        chmod(root.appendingPathComponent("_historique").path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 40_000, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    @discardableResult
    func text(_ relative: String, _ content: String = "{}") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Un projet Node avec ses dépendances installées.
    @discardableResult
    func nodeProject(_ name: String, under folder: String = "maison/Developpement") throws -> URL {
        try text("\(folder)/\(name)/package.json")
        try text("\(folder)/\(name)/pnpm-lock.yaml", "")
        try file("\(folder)/\(name)/node_modules/react/index.js")
        try text("\(folder)/\(name)/src/main.js", "console.log(1)")
        return root.appendingPathComponent("\(folder)/\(name)")
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    func environment() -> AgentEnvironment {
        AgentEnvironment(
            home: home,
            projectRoots: [projects],
            largeDownloadBytes: 100_000,
            applications: root.appendingPathComponent("_Applications"),
            systemLibrary: root.appendingPathComponent("_Library"),
            applicationName: { _ in nil },
            tools: .none,
            runningApps: { [] },
            processes: { [self] in ProcessSnapshot(processes: processes.withLock { $0 }) },
            requester: { [self] in requester.withLock { $0 } },
            agentName: { "claude" },
            history: HistoryStore(directory: historyFolder),
            stateDirectory: stateFolder,
            trasher: FolderTrasher(folder: trash),
            allowsPathBasedRemoval: true,
            capacity: { _ in nil },
            now: { [self] in clock.withLock { $0 } },
            workingDirectory: root
        )
    }

    var service: AgentService { AgentService(environment: environment()) }

    func history() async -> [CleanupOutcome] {
        await HistoryStore(directory: historyFolder).load()
    }

    /// `oust …` tel qu'un agent le lance, sorties comprises.
    func cli(_ arguments: [String]) async -> (code: Int32, out: String, err: String) {
        let out = Collector()
        let err = Collector()
        let code = await OustCommand.run(arguments, service: service,
                                         output: CommandOutput(out: out.append, err: err.append))
        return (code, out.text, err.text)
    }
}

/// Des lignes écrites depuis n'importe quelle tâche.
final class Collector: Sendable {
    private let lines = Mutex<[String]>([])

    @Sendable func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var all: [String] { lines.withLock { $0 } }
    var text: String { all.joined(separator: "\n") }
}

extension String {
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder.agent().decode(type, from: Data(utf8))
    }
}
