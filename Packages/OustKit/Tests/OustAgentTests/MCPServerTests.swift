import Foundation
import Testing
@testable import OustAgent

/// Un client MCP de test : une ligne JSON-RPC à la fois, et ce que le serveur répond.
struct MCPClient {
    let bench: AgentBench
    let server: MCPServer
    let output = Collector()

    init(_ bench: AgentBench) {
        self.bench = bench
        let output = output
        server = MCPServer(service: bench.service, write: output.append)
    }

    /// Envoie une ligne et rend la réponse qu'elle a produite, s'il y en a une.
    func send(_ line: String) async throws -> JSONValue? {
        let before = output.all.count
        await server.receive(line)
        let after = output.all
        guard after.count > before else { return nil }
        return try after[before].decoded(JSONValue.self)
    }

    func request(_ id: Int64, _ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let message: JSONValue = ["jsonrpc": "2.0", "id": .integer(id), "method": .string(method), "params": params]
        return try #require(try await send(message.line()))
    }

    /// Le résultat structuré d'un outil.
    func tool(_ id: Int64, _ name: String, _ arguments: JSONValue = [:]) async throws -> (isError: Bool, content: JSONValue) {
        let response = try await request(id, "tools/call", ["name": .string(name), "arguments": arguments])
        let result = try #require(response["result"])
        let text = try #require(result["content"]?.array?.first?["text"]?.string)
        // Le texte et le contenu structuré disent la même chose.
        let structured = try #require(result["structuredContent"])
        #expect(try text.decoded(JSONValue.self) == structured)
        return (result["isError"]?.bool == true, structured)
    }
}

@Suite("Le serveur MCP parle JSON-RPC 2.0 sur stdio")
struct MCPServerTests {

    @Test("initialize négocie la version et annonce les outils")
    func initialize() async throws {
        let client = MCPClient(try AgentBench())

        let response = try await client.request(1, "initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"],
        ])
        #expect(response["jsonrpc"] == "2.0" && response["id"] == .integer(1))
        let result = try #require(response["result"])
        #expect(result["protocolVersion"] == "2025-06-18")
        #expect(result["serverInfo"]?["name"] == "oust")
        #expect(result["capabilities"]?["tools"] != nil)
        #expect(result["instructions"]?.string?.isEmpty == false)

        // Une version inconnue : on répond avec la nôtre, la plus récente.
        let other = try await client.request(2, "initialize", ["protocolVersion": "1999-01-01"])
        #expect(other["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions[0]))
    }

    @Test("tools/list : scan, explain, clean, et clean exige le jeton")
    func toolsList() async throws {
        let client = MCPClient(try AgentBench())
        let response = try await client.request(1, "tools/list")
        let tools = try #require(response["result"]?["tools"]?.array)
        #expect(tools.compactMap { $0["name"]?.string } == ["scan", "explain", "clean"])
        let clean = try #require(tools.first { $0["name"] == "clean" })
        #expect(clean["inputSchema"]?["required"] == ["token", "ids"])
        #expect(clean["annotations"]?["destructiveHint"] == true)
        #expect(tools.first?["annotations"]?["readOnlyHint"] == true)
    }

    @Test("tools/call : scan, clean à blanc, puis clean pour de bon")
    func scanThenClean() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        let client = MCPClient(bench)
        _ = try await client.request(1, "initialize", ["protocolVersion": "2025-06-18"])

        let scan = try await client.tool(2, "scan", ["finders": ["projectArtifacts"]])
        #expect(!scan.isError)
        let token = try #require(scan.content["token"])
        let id = try #require(scan.content["items"]?.array?.first?["id"])

        let dry = try await client.tool(3, "clean", ["token": token, "ids": [id], "dryRun": true])
        #expect(!dry.isError)
        #expect(dry.content["outcomes"]?.array?.first?["result"] == "wouldClean")
        #expect(bench.exists("maison/Developpement/web/node_modules"))

        let clean = try await client.tool(4, "clean", ["token": token, "ids": [id]])
        #expect(!clean.isError)
        #expect(clean.content["outcomes"]?.array?.first?["result"] == "removed")
        #expect(!bench.exists("maison/Developpement/web/node_modules"))

        let explain = try await client.tool(5, "explain", ["id": id])
        #expect(explain.content["rule"] == "artifact.node_modules")
    }

    @Test("clean sans jeton, ou sur une classe refusée : une erreur d'outil, rien n'est touché")
    func refusals() async throws {
        let bench = try AgentBench()
        try bench.file("maison/Downloads/film.mov", bytes: 200_000, modified: Date().addingTimeInterval(-60 * 86_400))
        let client = MCPClient(bench)
        _ = try await client.request(1, "initialize", ["protocolVersion": "2025-06-18"])

        let scan = try await client.tool(2, "scan", ["finders": ["userContent"]])
        let id = try #require(scan.content["items"]?.array?.first?["id"])

        let noToken = try await client.tool(3, "clean", ["ids": [id]])
        #expect(noToken.isError)
        #expect(noToken.content["error"]?["code"] == "previewRequired")

        let refused = try await client.tool(4, "clean", ["token": scan.content["token"] ?? .null, "ids": [id]])
        #expect(refused.isError)
        #expect(refused.content["error"]?["code"] == "refused")
        #expect(bench.exists("maison/Downloads/film.mov"))

        let badArguments = try await client.tool(5, "scan", ["finders": [1, 2]])
        #expect(badArguments.isError && badArguments.content["error"]?["code"] == "usage")
    }

    @Test("Les erreurs du protocole : -32700, -32600, -32601, -32602")
    func protocolErrors() async throws {
        let client = MCPClient(try AgentBench())

        let parse = try #require(try await client.send("{pas du json"))
        #expect(parse["error"]?["code"] == -32700 && parse["id"] == .null)

        let invalid = try #require(try await client.send(#"{"id":1,"method":"ping"}"#))
        #expect(invalid["error"]?["code"] == -32600)

        let unknown = try await client.request(2, "resources/list")
        #expect(unknown["error"]?["code"] == -32601)

        let tool = try await client.request(3, "tools/call", ["name": "format_disk", "arguments": [:]])
        #expect(tool["error"]?["code"] == -32602)
    }

    @Test("ping, notifications et lots")
    func pingNotificationsBatches() async throws {
        let client = MCPClient(try AgentBench())

        let ping = try await client.request(1, "ping")
        #expect(ping["result"] == [:])

        // Une notification n'appelle pas de réponse ; une réponse du client non plus.
        #expect(try await client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try await client.send(#"{"jsonrpc":"2.0","id":9,"result":{}}"#) == nil)

        let batch = try #require(try await client.send(
            #"[{"jsonrpc":"2.0","id":2,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#))
        #expect(batch.array?.count == 1)
        #expect(batch.array?.first?["id"] == 2)
    }

    @Test("Avant 2025-06-18, pas de contenu structuré, le texte seul")
    func olderProtocol() async throws {
        let client = MCPClient(try AgentBench())
        _ = try await client.request(1, "initialize", ["protocolVersion": "2024-11-05"])
        let response = try await client.request(2, "tools/call", ["name": "explain", "arguments": ["id": "cache.npm"]])
        let result = try #require(response["result"])
        #expect(result["structuredContent"] == nil)
        #expect(result["content"]?.array?.first?["type"] == "text")
    }

    @Test("Servir jusqu'à la fin de l'entrée")
    func serve() async throws {
        let client = MCPClient(try AgentBench())
        let (lines, input) = AsyncStream<String>.makeStream()
        let serving = Task { await client.server.serve(lines) }
        input.yield(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        input.yield("")
        input.yield(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        // Les réponses arrivent avant que l'entrée ne se ferme.
        for _ in 0..<200 where client.output.all.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        input.finish()
        await serving.value

        let ids = try client.output.all.map { try $0.decoded(JSONValue.self)["id"] }
        #expect(Set(ids.compactMap(\.self)) == [1, 2])
        // Une ligne par message, comme l'exige le transport stdio.
        #expect(client.output.all.allSatisfy { !$0.contains("\n") })
    }

    @Test("Une requête annulée ne reçoit pas de réponse")
    func cancellation() async throws {
        let table = RequestTable()
        let running = Task {
            try await table.run(id: 7) {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return "trop tard"
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        await table.cancel(7)
        #expect(try await running.value == nil)
    }
}
