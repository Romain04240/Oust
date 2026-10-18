import Darwin
import Foundation
import OustLocalization
import OustRules

/// Où la CLI écrit : stdout pour le résultat, stderr pour le reste.
public struct CommandOutput: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.out = out
        self.err = err
    }

    public static let standard = CommandOutput(
        out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    )
}

/// L'exécutable `oust` : `scan`, `explain`, `clean`, `mcp`.
public enum OustCommand {

    /// Ce que `oust` a compris de sa ligne de commande.
    enum Invocation: Equatable, Sendable {
        case help
        case version
        case scan(json: Bool, finders: [String], paths: [String], limit: Int?)
        case explain(id: String, json: Bool)
        case clean(ids: [String], token: String?, allowReview: Bool, dryRun: Bool, json: Bool)
        case mcp
    }

    /// La version de l'app qui l'embarque ; « dev » hors de l'app.
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    public static func main(_ arguments: [String]) async -> Int32 {
        await run(arguments, service: AgentService(environment: .standard()), output: .standard)
    }

    public static func run(_ arguments: [String], service: AgentService, output: CommandOutput) async -> Int32 {
        let invocation: Invocation
        do {
            invocation = try parse(arguments)
        } catch {
            let error = error as? AgentError ?? .usage(String(describing: error))
            return fail(error, json: arguments.contains("--json"), output: output)
        }

        switch invocation {
        case .help:
            output.out(L10n.string("cli.usage", FinderKind.names))
            return AgentExitCode.success.rawValue

        case .version:
            output.out("oust \(version)")
            return AgentExitCode.success.rawValue

        case .mcp:
            let server = MCPServer(service: service, write: output.out)
            await server.serve(FileHandle.standardInput.bytes.lines)
            return AgentExitCode.success.rawValue

        case .scan(let json, let finderNames, let rawPaths, let limit):
            do {
                let finders = try service.finders(named: finderNames)
                let paths = try service.paths(rawPaths)
                let report = await service.scan(finders: finders, paths: paths, limit: limit)
                for warning in report.warnings { output.err("oust: " + warning) }
                if json { output.out(encode(report)) } else { HumanText.scan(report).forEach(output.out) }
                return AgentExitCode.success.rawValue
            } catch {
                return fail(error, json: json, output: output)
            }

        case .explain(let id, let json):
            do {
                let report = try await service.explain(id)
                if json { output.out(encode(report)) } else { HumanText.explain(report).forEach(output.out) }
                return AgentExitCode.success.rawValue
            } catch {
                return fail(error, json: json, output: output)
            }

        case .clean(let ids, let token, let allowReview, let dryRun, let json):
            do {
                // Au fil de l'eau sur stderr ; le bilan sur stdout.
                let progress: (@Sendable (OutcomeReport) -> Void)? = json ? nil : { @Sendable outcome in
                    output.err(HumanText.outcome(outcome))
                }
                let report = try await service.clean(ids: ids, token: token, allowReview: allowReview, dryRun: dryRun,
                                                     progress: progress)
                if json { output.out(encode(report)) } else { HumanText.clean(report).forEach(output.out) }
                let complete = report.outcomes.allSatisfy(\.succeeded)
                return (complete ? AgentExitCode.success : .incomplete).rawValue
            } catch {
                return fail(error, json: json, output: output)
            }
        }
    }

    static func fail(_ error: any Error, json: Bool, output: CommandOutput) -> Int32 {
        let error = error as? AgentError ?? .failure(error.localizedDescription)
        if json {
            output.out(encode(ErrorReport(error)))
        } else {
            output.err("oust: " + error.message)
        }
        return error.exitCode.rawValue
    }

    static func encode(_ value: some Encodable) -> String {
        let data = (try? JSONEncoder.agent(pretty: true).encode(value)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Ligne de commande

    static func parse(_ arguments: [String]) throws -> Invocation {
        guard let command = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        if ["help", "--help", "-h"].contains(command) || rest.contains("--help") || rest.contains("-h") { return .help }
        switch command {
        case "version", "--version":
            return .version
        case "mcp":
            let options = try Options(rest, flags: [], values: [])
            guard options.positionals.isEmpty else { throw unexpected(options.positionals[0]) }
            return .mcp
        case "scan":
            let options = try Options(rest, flags: ["--json"], values: ["--finders", "--path", "--limit"])
            guard options.positionals.isEmpty else { throw unexpected(options.positionals[0]) }
            var limit: Int?
            if let text = options.values["--limit"]?.last {
                guard let value = Int(text), value > 0 else {
                    throw AgentError.usage(L10n.string("agent.error.badArgument", "--limit"))
                }
                limit = value
            }
            return .scan(json: options.flags.contains("--json"), finders: options.values["--finders"] ?? [],
                         paths: options.values["--path"] ?? [], limit: limit)
        case "explain":
            let options = try Options(rest, flags: ["--json"], values: [])
            guard let id = options.positionals.first else {
                throw AgentError.usage(L10n.string("agent.error.missingArgument", "ID"))
            }
            guard options.positionals.count == 1 else { throw unexpected(options.positionals[1]) }
            return .explain(id: id, json: options.flags.contains("--json"))
        case "clean":
            let options = try Options(rest, flags: ["--json", "--allow-review", "--dry-run"], values: ["--token"])
            guard !options.positionals.isEmpty else { throw AgentError.usage(L10n.string("agent.error.noIDs")) }
            return .clean(ids: options.positionals, token: options.values["--token"]?.last,
                          allowReview: options.flags.contains("--allow-review"),
                          dryRun: options.flags.contains("--dry-run"), json: options.flags.contains("--json"))
        default:
            throw AgentError.usage(L10n.string("agent.error.unknownCommand", command))
        }
    }

    static func unexpected(_ argument: String) -> AgentError {
        .usage(L10n.string("agent.error.unknownOption", argument))
    }

    /// Options `--nom`, `--nom valeur` ou `--nom=valeur` ; après `--`, tout est argument.
    struct Options {
        var flags: Set<String> = []
        var values: [String: [String]] = [:]
        var positionals: [String] = []

        init(_ arguments: [String], flags allowedFlags: Set<String>, values allowedValues: Set<String>) throws {
            var index = 0
            var literal = false
            while index < arguments.count {
                let argument = arguments[index]
                index += 1
                if literal || !argument.hasPrefix("-") || argument == "-" {
                    positionals.append(argument)
                    continue
                }
                if argument == "--" {
                    literal = true
                    continue
                }
                let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0]
                if allowedFlags.contains(name), parts.count == 1 {
                    flags.insert(name)
                } else if allowedValues.contains(name) {
                    if parts.count == 2 {
                        values[name, default: []].append(parts[1])
                    } else if index < arguments.count {
                        values[name, default: []].append(arguments[index])
                        index += 1
                    } else {
                        throw AgentError.usage(L10n.string("agent.error.missingValue", name))
                    }
                } else {
                    throw OustCommand.unexpected(argument)
                }
            }
        }
    }

    // MARK: - Lancement

    /// Lancé par un lien symbolique (`~/.local/bin/oust`), `Bundle.main` serait
    /// le dossier du lien et non Oust.app : le catalogue des phrases resterait
    /// introuvable, et l'accesseur de ressources s'arrêterait net (constaté le
    /// 18/10/2026). On se relance donc une fois par le vrai chemin, avant tout
    /// le reste ; si cela échoue, on continue tel quel.
    public static func relaunchFromRealPathIfNeeded() {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return }
        let invoked = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let resolved = realpath(invoked, nil) else { return }
        let real = String(cString: resolved)
        free(resolved)
        // Hors d'une app, le bundle de ressources est à côté de l'exécutable :
        // rien à faire.
        guard real != invoked, real.contains(".app/Contents/MacOS/") else { return }
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(real, &argv)
    }
}
