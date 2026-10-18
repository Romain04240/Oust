import Foundation
import Testing
import OustScan

@Suite("Le suivi en direct du disque")
struct WatchTests {

    @Test("Un fichier écrit après le départ du suivi est vu")
    func seesNewFile() async throws {
        let fixture = try Fixture()
        let events = FileSystemEvents.watch([fixture.root.path], latency: 0.05)
        try Data("{}\n".utf8).write(to: fixture.root.appendingPathComponent("history.jsonl"))

        let seen = await firstBatch(of: events, within: .seconds(10)) { batch in
            batch.contains { $0.hasSuffix("/history.jsonl") }
        }
        #expect(seen)
    }

    @Test("Un dossier qui n'existe pas encore est suivi dès sa création")
    func seesFolderCreatedLater() async throws {
        let fixture = try Fixture()
        let folder = fixture.root.appendingPathComponent("Oust", isDirectory: true)
        let events = FileSystemEvents.watch([folder.path], latency: 0.05)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("history.jsonl"))

        let seen = await firstBatch(of: events, within: .seconds(10)) { batch in
            batch.contains { $0.hasSuffix("/Oust/history.jsonl") }
        }
        #expect(seen)
    }

    /// Vrai si un lot répond à `match` avant `limit` ; FSEvents ne promet pas
    /// de délai, on ne l'attend donc pas indéfiniment.
    private func firstBatch(of events: AsyncStream<Set<String>>, within limit: Duration,
                            where match: @escaping @Sendable (Set<String>) -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await batch in events where match(batch) { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
