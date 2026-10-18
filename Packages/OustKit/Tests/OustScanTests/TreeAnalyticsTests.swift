import Foundation
import Testing
@testable import OustScan

@Suite("Les statistiques façon TreeSize")
struct TreeAnalyticsTests {

    func scannedTree(_ fixture: Fixture) async throws -> TreeNode {
        try fixture.file("Films/vacances.mp4", bytes: 3_000_000)
        try fixture.file("Films/Archives/2019.mov", bytes: 2_000_000)
        try fixture.file("Photos/plage.jpg", bytes: 1_200_000)
        try fixture.file("Projets/app/modele.gguf", bytes: 1_500_000)
        try fixture.file("Projets/app/notes.txt", bytes: 300)
        let result = await Scanner.scan([fixture.root], options: ScanOptions(leafThreshold: 1_000_000))
        return try #require(result.root)
    }

    @Test("Les familles de fichiers, du plus lourd au plus léger, petits fichiers à part")
    func kinds() async throws {
        let fixture = try Fixture()
        let root = try await scannedTree(fixture)
        let analytics = TreeAnalytics.compute(root)

        #expect(analytics.kinds.first?.kind == .video)
        #expect(analytics.kinds.first?.tally.count == 2)
        #expect(analytics.kinds.contains { $0.kind == .model })
        #expect(analytics.kinds.contains { $0.kind == .image })
        #expect(analytics.smallFiles.count == 1)
        #expect(analytics.extensions.first?.ext == "mp4")
    }

    @Test("Les dossiers sont comptés descendants compris")
    func folderCounts() async throws {
        let fixture = try Fixture()
        let root = try await scannedTree(fixture)
        let analytics = TreeAnalytics.compute(root)

        // Films, Films/Archives, Photos, Projets, Projets/app
        #expect(analytics.folders(in: root) == 5)
        let films = try #require(root.children.first { $0.name == "Films" })
        #expect(analytics.folders(in: films) == 1)
    }

    @Test("Les plus gros fichiers, bornés et triés")
    func largest() async throws {
        let fixture = try Fixture()
        let root = try await scannedTree(fixture)
        let analytics = TreeAnalytics.compute(root, largestLimit: 2)

        #expect(analytics.largest.map(\.name) == ["vacances.mp4", "2019.mov"])
        #expect(analytics.largest.first?.folder.hasSuffix("/Films") == true)
    }

    @Test("Les âges se rangent selon la dernière modification")
    func ages() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AgeRange.of(now.addingTimeInterval(-5 * 86_400), now: now) == .month)
        #expect(AgeRange.of(now.addingTimeInterval(-100 * 86_400), now: now) == .halfYear)
        #expect(AgeRange.of(now.addingTimeInterval(-900 * 86_400), now: now) == .older)
        #expect(AgeRange.of(nil, now: now) == .unknown)
    }

    @Test("La recherche trouve dossiers et fichiers, du plus gros au plus petit")
    func search() async throws {
        let fixture = try Fixture()
        let root = try await scannedTree(fixture)

        let hits = TreeAnalytics.search(root, query: "ar")
        #expect(hits.map(\.name).contains("Archives"))
        #expect(TreeAnalytics.search(root, query: "a").isEmpty, "une seule lettre ne lance pas de recherche")
        let film = TreeAnalytics.search(root, query: "VACANCES")
        #expect(film.first?.name == "vacances.mp4")
    }

    @Test("Le CSV liste sous-dossiers et gros fichiers, chemins entre guillemets")
    func csv() async throws {
        let fixture = try Fixture()
        let root = try await scannedTree(fixture)
        let films = try #require(root.children.first { $0.name == "Films" })

        let csv = TreeAnalytics.compute(root).csv(for: films)
        let lines = csv.split(separator: "\n")

        #expect(lines.first?.hasPrefix("Chemin;Type") == true)
        #expect(lines.count == 3)
        #expect(lines.contains { $0.contains("Archives\";dossier") })
        #expect(lines.contains { $0.contains("vacances.mp4\";fichier") })
    }

    @Test("L'évolution montre le dossier qui a grossi, pas toute sa lignée")
    func changes() {
        let before = TreeSummary(rootPath: "/d", date: Date(), sizes: [
            "/d": 100_000_000_000, "/d/u": 90_000_000_000, "/d/u/projet": 33_000_000_000, "/d/u/autre": 5_000_000_000,
        ])
        let after = TreeSummary(rootPath: "/d", date: Date(), sizes: [
            "/d": 190_000_000_000, "/d/u": 180_000_000_000, "/d/u/projet": 123_000_000_000, "/d/u/autre": 5_000_000_000,
            "/d/u/nouveau": 2_000_000_000,
        ])

        let changes = before.changes(comparedTo: after)

        #expect(changes.first?.path == "/d/u/projet")
        #expect(changes.first?.delta == 90_000_000_000)
        #expect(!changes.contains { $0.path == "/d/u" }, "son écart vient de « projet »")
        #expect(changes.contains { $0.path == "/d/u/nouveau" && $0.before == nil })
        #expect(!changes.contains { $0.path == "/d/u/autre" })
    }

    @Test("Un résumé se garde et se relit")
    func store() async throws {
        let fixture = try Fixture()
        try fixture.file("gros/a.bin", bytes: 60_000_000)
        let result = await Scanner.scan([fixture.root])
        let root = try #require(result.root)
        let summary = TreeSummary.make(from: root)
        let store = TreeSummaryStore(directory: fixture.root.appendingPathComponent("_resumes"))

        try store.save(summary)
        let loaded = try #require(store.load(rootPath: root.path))

        #expect(loaded.sizes[root.path + "/gros"] != nil)
        #expect(loaded.delta(for: root) == 0)
    }
}
