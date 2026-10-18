import Foundation
import Testing
@testable import OustAgent
import OustClean
import OustCore
import OustModel

@Suite("Ce qu'un agent nettoie arrive dans l'Historique de l'app")
struct AgentHistoryTests {

    @Test("Le journal dit « un agent », et qui a lancé oust")
    func journalsOrigin() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        let scan = await bench.service.scan(finders: [.projectArtifacts])
        let item = try #require(scan.items.first)

        _ = try await bench.service.clean(ids: [item.id], token: scan.token)

        let history = await bench.history()
        #expect(history.map(\.origin) == [.agent(name: "claude")])
        #expect(history.allSatisfy { $0.isByAgent })
    }

    @Test("L'Historique se relit quand un agent nettoie, sans relancer l'app")
    func refreshesWhileOpen() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        // Le journal tel que l'app le tient : un autre `HistoryStore` que celui
        // de `oust`, comme deux processus.
        let app = HistoryStore(directory: bench.historyFolder)
        #expect(await app.load().isEmpty)
        let changes = app.changes(latency: 0.05)

        let scan = await bench.service.scan(finders: [.projectArtifacts])
        let item = try #require(scan.items.first)
        _ = try await bench.service.clean(ids: [item.id], token: scan.token)

        #expect(await signalled(changes, within: .seconds(10)))
        let entries = await app.load()
        #expect(entries.map(\.itemID) == [item.id])
        #expect(entries.first?.origin == .agent(name: "claude"))
    }

    @Test("Le nom de l'agent : celui de son exécutable, ou du dossier qui tient ses versions")
    func agentNames() {
        #expect(Requester.displayName(ofExecutable: "/opt/claude/versions/2.1.289") == "claude")
        #expect(Requester.displayName(ofExecutable: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex") == "codex")
        #expect(Requester.displayName(ofExecutable: "/usr/local/bin/node") == "node")
        // Un numéro hors d'un dossier `versions` reste ce qu'il est.
        #expect(Requester.displayName(ofExecutable: "/opt/outil/2.0") == "2.0")
        #expect(Requester.intermediaries.isSuperset(of: ["zsh", "bash", "sh", "login"]))
    }

    /// Vrai si le journal a signalé un changement avant `limit`.
    private func signalled(_ changes: AsyncStream<Void>, within limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in changes { return true }
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
