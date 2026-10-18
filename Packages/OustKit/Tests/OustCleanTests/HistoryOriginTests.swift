import Foundation
import Testing
@testable import OustClean
import OustCore
import OustSafety

@Suite("L'Historique sait qui a nettoyé")
struct HistoryOriginTests {

    /// Une ligne telle que l'app l'écrivait avant que l'origine existe.
    static let lineWithoutOrigin = #"{"bytes":3169165312,"category":"packageCaches","date":"2026-10-18T08:50:08Z","itemID":"cache.npm","method":{"removeNow":{}},"owner":"npm","paths":["/tmp/oust/.npm"],"result":{"removed":{}},"sessionID":"6F1C2B9E-3D4A-4F5B-8C7D-1E2F3A4B5C6D","title":"Cache npm","trashedTo":[]}"#

    @Test("Une ligne d'avant l'origine se lit encore, comme venant de l'app")
    func decodesLineWithoutOrigin() async throws {
        let bench = try Bench()
        try FileManager.default.createDirectory(at: bench.historyFolder, withIntermediateDirectories: true)
        try Data((Self.lineWithoutOrigin + "\n").utf8).write(to: bench.historyFolder.appendingPathComponent("history.jsonl"))

        let entries = await HistoryStore(directory: bench.historyFolder).load()

        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.origin == nil)
        #expect(!entry.isByAgent)
        #expect(entry.method == .removeNow)
        #expect(entry.result == .removed)
        #expect(entry.bytes == 3_169_165_312)
    }

    @Test("L'origine fait l'aller-retour par le journal")
    func roundTrip() async throws {
        let bench = try Bench()
        let store = HistoryStore(directory: bench.historyFolder)
        let item = bench.item(try bench.file("app/node_modules/react/index.js"))
        let origins: [CleanupOrigin?] = [.agent(name: "claude"), .agent(name: nil), .app, nil]
        for (index, origin) in origins.enumerated() {
            var outcome = CleanupOutcome(sessionID: UUID(), date: Date(timeIntervalSince1970: TimeInterval(index)),
                                         item: item, result: .removed, bytes: 1_000)
            outcome.origin = origin
            try await store.append(outcome)
        }

        let loaded = await store.load().reversed()

        #expect(loaded.map(\.origin) == origins)
        #expect(loaded.map(\.isByAgent) == [true, true, false, false])
        let lines = try String(contentsOf: bench.historyFolder.appendingPathComponent("history.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.first?.contains(#""origin":{"agent":{"name":"claude"}}"#) == true)
        // Sans origine, la clé n'est pas écrite : la ligne reste celle d'avant.
        #expect(lines.last?.contains("origin") == false)
    }

    @Test("Le moteur inscrit l'origine que lui donne son lanceur ; par défaut, l'app")
    func engineStampsOrigin() async throws {
        let bench = try Bench()
        let byAgent = bench.root.appendingPathComponent("agent/node_modules")
        let byApp = bench.root.appendingPathComponent("app/node_modules")
        try bench.file("agent/node_modules/react/index.js")
        try bench.file("app/node_modules/react/index.js")
        let engine = CleanupEngine(
            trasher: FolderTrasher(folder: bench.trash),
            history: HistoryStore(directory: bench.historyFolder),
            pathGuard: PathGuard(home: bench.root.appendingPathComponent("maison")),
            processes: { ProcessSnapshot(processes: []) },
            capacity: { _ in nil },
            deleteSnapshots: { _ in false },
            origin: .agent(name: "codex")
        )

        var finished: [CleanupOutcome] = []
        for await event in engine.run([bench.item(byAgent)]) {
            if case .itemFinished(let outcome) = event { finished.append(outcome) }
        }
        _ = await bench.run([bench.item(byApp)])

        #expect(finished.map(\.origin) == [.agent(name: "codex")])
        let history = await HistoryStore(directory: bench.historyFolder).load()
        #expect(history.map(\.origin) == [.app, .agent(name: "codex")])
    }
}
