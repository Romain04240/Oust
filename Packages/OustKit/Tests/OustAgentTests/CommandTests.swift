import Foundation
import Testing
@testable import OustAgent

@Suite("La ligne de commande : options, JSON et codes de sortie stables")
struct CommandTests {

    @Test("Les options se lisent sous toutes leurs formes")
    func parsing() throws {
        #expect(try OustCommand.parse([]) == .help)
        #expect(try OustCommand.parse(["clean", "x", "--help"]) == .help)
        #expect(try OustCommand.parse(["--version"]) == .version)
        #expect(try OustCommand.parse(["mcp"]) == .mcp)
        #expect(try OustCommand.parse(["scan", "--json", "--finders", "projectArtifacts,agents", "--path=/a",
                                       "--path", "b", "--limit", "5"])
                == .scan(json: true, finders: ["projectArtifacts,agents"], paths: ["/a", "b"], limit: 5))
        #expect(try OustCommand.parse(["explain", "cache.npm|/x"]) == .explain(id: "cache.npm|/x", json: false))
        #expect(try OustCommand.parse(["clean", "a", "b", "--token", "t", "--allow-review", "--dry-run", "--", "--c"])
                == .clean(ids: ["a", "b", "--c"], token: "t", allowReview: true, dryRun: true, json: false))
    }

    @Test("Ce qui n'est pas compris est une erreur d'usage")
    func usageErrors() {
        #expect(throws: AgentError.self) { try OustCommand.parse(["nettoie"]) }
        #expect(throws: AgentError.self) { try OustCommand.parse(["scan", "--force"]) }
        #expect(throws: AgentError.self) { try OustCommand.parse(["scan", "--limit", "0"]) }
        #expect(throws: AgentError.self) { try OustCommand.parse(["scan", "--path"]) }
        #expect(throws: AgentError.self) { try OustCommand.parse(["clean"]) }
        #expect(throws: AgentError.self) { try OustCommand.parse(["clean", "x", "--allow-review=oui"]) }
        #expect(throws: AgentError.self) { try OustCommand.parse(["explain", "a", "b"]) }
        #expect(throws: AgentError.self) { try OustCommand.parse(["mcp", "--port", "80"]) }
    }

    @Test("Les codes de sortie ne bougent pas")
    func exitCodes() {
        let codes = Dictionary(uniqueKeysWithValues: AgentExitCode.allCases.map { ($0, $0.rawValue) })
        #expect(codes == [.success: 0, .failure: 1, .usage: 2, .notFound: 3, .refused: 4, .incomplete: 5,
                          .previewRequired: 6])
    }

    @Test("scan --json, puis clean : 0 ; le dossier est parti")
    func scanThenClean() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")

        let scan = await bench.cli(["scan", "--json", "--finders", "projectArtifacts"])
        #expect(scan.code == 0)
        let report = try scan.out.decoded(ScanReport.self)
        #expect(report.schema == "oust.scan/1")
        let id = try #require(report.items.first?.id)

        // Sans --token : le plus récent des aperçus qui le montre.
        let clean = await bench.cli(["clean", id, "--json"])
        #expect(clean.code == 0)
        #expect(try clean.out.decoded(CleanReport.self).outcomes.map(\.result) == ["removed"])
        #expect(!bench.exists("maison/Developpement/web/node_modules"))
    }

    @Test("Refusé : 4 et l'erreur en JSON ; sans aperçu : 6 ; inconnu : 3 ; usage : 2")
    func errorCodes() async throws {
        let bench = try AgentBench()
        try bench.file("maison/Downloads/film.mov", bytes: 200_000, modified: Date().addingTimeInterval(-60 * 86_400))

        let none = await bench.cli(["clean", "downloads.large|/x", "--json"])
        #expect(none.code == 6)
        #expect(try none.out.decoded(ErrorReport.self).error.code == "previewRequired")

        let scan = try await bench.cli(["scan", "--json", "--finders", "userContent"]).out.decoded(ScanReport.self)
        let id = try #require(scan.items.first?.id)
        let token = try #require(scan.token)

        let refused = await bench.cli(["clean", id, "--token", token, "--json"])
        #expect(refused.code == 4)
        let error = try refused.out.decoded(ErrorReport.self).error
        #expect(error.code == "refused" && error.exitCode == 4)
        #expect(error.items.map(\.reason) == ["needsAllowReview"])
        #expect(bench.exists("maison/Downloads/film.mov"))

        #expect(await bench.cli(["clean", "inconnu", "--token", token]).code == 3)
        #expect(await bench.cli(["explain", "inconnu"]).code == 3)
        #expect(await bench.cli(["scan", "--finders", "bidule"]).code == 2)

        let dry = await bench.cli(["clean", id, "--token", token, "--allow-review", "--dry-run"])
        #expect(dry.code == 0)
        #expect(bench.exists("maison/Downloads/film.mov"))
    }

    @Test("En partie fait : 5")
    func incomplete() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        let scan = try await bench.cli(["scan", "--json", "--finders", "projectArtifacts"]).out.decoded(ScanReport.self)
        let id = try #require(scan.items.first?.id)
        try FileManager.default.removeItem(at: bench.projects.appendingPathComponent("web/node_modules"))

        #expect(await bench.cli(["clean", id]).code == 5)
    }
}
