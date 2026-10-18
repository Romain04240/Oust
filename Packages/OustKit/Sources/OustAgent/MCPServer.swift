import Foundation
import OustLocalization
import OustRules

/// Le serveur MCP d'Oust! : JSON-RPC 2.0, un message par ligne, sur stdin et
/// stdout. Aucun réseau, aucune bibliothèque (RULES.md, règles 11 et 12).
///
/// Trois outils : `scan` (à blanc, rend un jeton), `explain`, et `clean`, qui
/// exige ce jeton. Les limites sont celles de la CLI, puisque c'est le même
/// `AgentService` qui travaille.
///
/// Rien d'autre que des messages ne doit sortir sur stdout : les outils que
/// lancent les moteurs écrivent dans des tubes à eux (`Command.run`).
public final class MCPServer: Sendable {
    let service: AgentService
    let output: Output
    let requests = RequestTable()

    /// Les versions du protocole qu'on sait parler, la plus récente d'abord.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// `scan` en montre au plus autant si l'agent ne dit rien : une analyse
    /// complète noierait son contexte.
    static let defaultLimit = 100

    public init(service: AgentService, write: @escaping @Sendable (String) -> Void) {
        self.service = service
        self.output = Output(write: write)
    }

    /// Sert jusqu'à la fin de l'entrée. Chaque requête a sa tâche : une
    /// annulation, un `ping`, passent pendant qu'un nettoyage tourne.
    public func serve<Lines: AsyncSequence>(_ lines: Lines) async where Lines.Element == String {
        var tasks: [Task<Void, Never>] = []
        do {
            for try await line in lines {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                tasks.append(Task { await self.receive(text) })
            }
        } catch {
            // Une entrée illisible vaut une entrée fermée.
        }
        // Le client a fermé l'entrée : ce qui tourne s'arrête entre deux éléments.
        await requests.closeAll()
        for task in tasks { await task.value }
    }

    // MARK: - Messages

    func receive(_ text: String) async {
        guard let message = try? JSONDecoder.agent().decode(JSONValue.self, from: Data(text.utf8)) else {
            await output.send(Self.failure(id: .null, .parseError))
            return
        }
        if case .array(let batch) = message {
            guard !batch.isEmpty else { return await output.send(Self.failure(id: .null, .invalidRequest)) }
            var responses: [JSONValue] = []
            for one in batch {
                if let response = await process(one) { responses.append(response) }
            }
            if !responses.isEmpty { await output.send(.array(responses)) }
        } else if let response = await process(message) {
            await output.send(response)
        }
    }

    /// La réponse à un message, ou `nil` pour une notification.
    func process(_ message: JSONValue) async -> JSONValue? {
        guard case .object(let object) = message else { return Self.failure(id: .null, .invalidRequest) }
        let id = object["id"]
        guard let method = object["method"]?.string else {
            // Une réponse du client : nous ne lui envoyons pas de requêtes.
            if object["result"] != nil || object["error"] != nil { return nil }
            return Self.failure(id: id ?? .null, .invalidRequest)
        }
        guard object["jsonrpc"]?.string == "2.0" else { return Self.failure(id: id ?? .null, .invalidRequest) }
        let params = object["params"] ?? .object([:])
        guard let id else {
            await notify(method, params)
            return nil
        }
        do {
            // Annulée : le client n'attend plus de réponse (spécification MCP).
            guard let result = try await requests.run(id: id, { try await self.call(method, params) }) else { return nil }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let error as RPCError {
            return Self.failure(id: id, error)
        } catch {
            return Self.failure(id: id, .internalError)
        }
    }

    func notify(_ method: String, _ params: JSONValue) async {
        switch method {
        case "notifications/cancelled":
            if let id = params["requestId"] { await requests.cancel(id) }
        default:
            // `notifications/initialized` et le reste : rien à faire.
            break
        }
    }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            await requests.setVersion(version)
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "oust", "title": "Oust!", "version": .string(OustCommand.version)],
                "instructions": .string(L10n.string("mcp.instructions")),
            ]
        case "ping":
            return .object([:])
        case "tools/list":
            return ["tools": .array(Self.tools())]
        case "tools/call":
            return try await callTool(params)
        default:
            throw RPCError.methodNotFound
        }
    }

    // MARK: - Outils

    func callTool(_ params: JSONValue) async throws -> JSONValue {
        guard let name = params["name"]?.string else { throw RPCError.invalidParams }
        let arguments = params["arguments"] ?? .object([:])
        guard case .object = arguments else { throw RPCError.invalidParams }
        let structured = await requests.structuredContent
        do {
            switch name {
            case "scan":
                let finders = try service.finders(named: try Self.strings(arguments["finders"], name: "finders"))
                let paths = try service.paths(try Self.strings(arguments["paths"], name: "paths"))
                let limit = arguments["limit"]?.integer.map { Int(min(max($0, 1), 1_000)) } ?? Self.defaultLimit
                return try Self.result(await service.scan(finders: finders, paths: paths, limit: limit), structured)
            case "explain":
                guard let id = arguments["id"]?.string, !id.isEmpty else {
                    throw AgentError.usage(L10n.string("agent.error.missingArgument", "id"))
                }
                return try Self.result(try await service.explain(id), structured)
            case "clean":
                // L'aperçu est obligatoire ici : pas de repli sur le plus récent.
                guard let token = arguments["token"]?.string, !token.isEmpty else { throw AgentError.previewRequired }
                let ids = try Self.strings(arguments["ids"], name: "ids")
                let report = try await service.clean(ids: ids, token: token,
                                                     allowReview: arguments["allowReview"]?.bool ?? false,
                                                     dryRun: arguments["dryRun"]?.bool ?? false)
                return try Self.result(report, structured)
            default:
                throw RPCError(code: -32602, message: L10n.string("mcp.error.unknownTool", name))
            }
        } catch let error as AgentError {
            // Une erreur d'outil se rend comme un résultat : c'est l'agent qui doit
            // la lire, pas le client qui la transporte.
            return try Self.result(ErrorReport(error), structured, isError: true)
        }
    }

    static func strings(_ value: JSONValue?, name: String) throws -> [String] {
        switch value {
        case nil, .null?: return []
        case .string(let one)?: return [one]
        case .array(let values)?:
            let strings = values.compactMap(\.string)
            if strings.count == values.count { return strings }
        default: break
        }
        throw AgentError.usage(L10n.string("agent.error.badArgument", name))
    }

    /// Le JSON en texte (tous les clients le lisent) et, depuis 2025-06-18, tel quel.
    static func result(_ value: some Encodable, _ structured: Bool, isError: Bool = false) throws -> JSONValue {
        let json = try JSONValue(encoding: value)
        var result: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(json.line())]],
            "isError": .bool(isError),
        ]
        if structured { result["structuredContent"] = json }
        return .object(result)
    }

    static func tools() -> [JSONValue] {
        let finders = JSONValue.array(FinderKind.homeCases.map { .string($0.rawValue) })
        let scan: JSONValue = [
            "name": "scan",
            "title": .string(L10n.string("mcp.tool.scan.title")),
            "description": .string(L10n.string("mcp.tool.scan.description")),
            "inputSchema": [
                "type": "object",
                "properties": [
                    "finders": ["type": "array", "items": ["type": "string", "enum": finders],
                                "description": .string(L10n.string("mcp.param.finders"))],
                    "paths": ["type": "array", "items": ["type": "string"],
                              "description": .string(L10n.string("mcp.param.paths"))],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 1_000,
                              "default": .integer(Int64(defaultLimit)),
                              "description": .string(L10n.string("mcp.param.limit"))],
                ],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ]
        let explain: JSONValue = [
            "name": "explain",
            "title": .string(L10n.string("mcp.tool.explain.title")),
            "description": .string(L10n.string("mcp.tool.explain.description")),
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": .string(L10n.string("mcp.param.id"))]],
                "required": ["id"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "idempotentHint": true, "openWorldHint": false],
        ]
        let clean: JSONValue = [
            "name": "clean",
            "title": .string(L10n.string("mcp.tool.clean.title")),
            "description": .string(L10n.string("mcp.tool.clean.description")),
            "inputSchema": [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": .string(L10n.string("mcp.param.token"))],
                    "ids": ["type": "array", "items": ["type": "string"], "minItems": 1,
                            "description": .string(L10n.string("mcp.param.ids"))],
                    "allowReview": ["type": "boolean", "default": false,
                                    "description": .string(L10n.string("mcp.param.allowReview"))],
                    "dryRun": ["type": "boolean", "default": false,
                               "description": .string(L10n.string("mcp.param.dryRun"))],
                ],
                "required": ["token", "ids"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false,
                            "openWorldHint": false],
        ]
        return [scan, explain, clean]
    }

    // MARK: - Erreurs JSON-RPC

    /// Les messages sont ceux de la spécification JSON-RPC 2.0, des noms
    /// techniques que le client journalise, et non des phrases de l'interface.
    struct RPCError: Error {
        let code: Int64
        let message: String

        static let parseError = RPCError(code: -32700, message: "Parse error")
        static let invalidRequest = RPCError(code: -32600, message: "Invalid Request")
        static let methodNotFound = RPCError(code: -32601, message: "Method not found")
        static let invalidParams = RPCError(code: -32602, message: "Invalid params")
        static let internalError = RPCError(code: -32603, message: "Internal error")
    }

    static func failure(id: JSONValue, _ error: RPCError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .integer(error.code), "message": .string(error.message)]]
    }
}

// MARK: - État partagé

/// Une ligne à la fois sur stdout : deux réponses ne s'entremêlent jamais.
actor Output {
    let write: @Sendable (String) -> Void

    init(write: @escaping @Sendable (String) -> Void) {
        self.write = write
    }

    func send(_ message: JSONValue) {
        write(message.line())
    }
}

/// Les requêtes en cours, pour les annuler, et la version négociée.
actor RequestTable {
    private var running: [JSONValue: Task<JSONValue, any Error>] = [:]
    private var cancelled: Set<JSONValue> = []
    private var closed = false
    private var version = MCPServer.protocolVersions[0]

    /// `structuredContent` n'existe que depuis la version 2025-06-18.
    var structuredContent: Bool { version >= "2025-06-18" }

    func setVersion(_ version: String) {
        self.version = version
    }

    /// Le résultat, ou `nil` si la requête a été annulée entre-temps.
    func run(id: JSONValue, _ body: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue? {
        let task = Task { try await body() }
        running[id] = task
        if closed { task.cancel() }
        defer { running[id] = nil }
        do {
            let result = try await task.value
            return cancelled.remove(id) == nil ? result : nil
        } catch {
            if cancelled.remove(id) != nil { return nil }
            throw error
        }
    }

    func cancel(_ id: JSONValue) {
        guard let task = running[id] else { return }
        cancelled.insert(id)
        task.cancel()
    }

    func closeAll() {
        closed = true
        for task in running.values { task.cancel() }
    }
}
