import Foundation
import Testing
@testable import OustRules
import OustCore
import OustSafety

@Suite("Les identités publiées et le gain par fiche")
struct PublicationIdentityAndGainTests {
    private func context(_ home: FakeHome) throws -> RuleContext {
        let anchor = try home.openVolume(home.root.appendingPathComponent("Volume", isDirectory: true))
        var context = home.context()
        context.volume = VolumeScope(root: anchor.url, name: "Test", fileSystem: "apfs")
        context.volume?.root = anchor.url
        context.volumeAnchor = anchor
        context.projectRoots = [anchor.url]
        return context
    }

    @Test("Une cible remplacée, disparue ou redirigée invalide le lot en attente",
          arguments: ["replace", "remove", "redirect"])
    func stagedTargetChanges(change: String) async throws {
        let home = try FakeHome()
        try home.text("Volume/projet/package.json", "{}")
        try home.file("Volume/projet/node_modules/cache", bytes: 1_200_000)
        let context = try context(home)
        var batches: [RuleBatch] = []
        for await batch in RuleEngine.run(context, finders: [.projectArtifacts]) { batches.append(batch) }
        let batch = try #require(batches.first)
        #expect(batch.items.contains { $0.ruleID == "artifact.node_modules" })
        let target = home.root.appendingPathComponent("Volume/projet/node_modules", isDirectory: true)
        try FileManager.default.moveItem(at: target, to: home.root.appendingPathComponent("initial", isDirectory: true))
        if change == "replace" {
            try home.file("Volume/projet/node_modules/remplacement", bytes: 4096)
        } else if change == "redirect" {
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: home.root.appendingPathComponent("initial"))
        }
        #expect(batch.revalidatedItems().isEmpty)
        #expect(!batch.items.isEmpty)
    }

    @Test("Tous les chemins d’une fiche groupée sont revérifiés")
    func groupedTargetChanges() async throws {
        let home = try FakeHome()
        try home.file("Volume/projet/a/__pycache__/a.pyc", bytes: 50_000)
        try home.file("Volume/projet/b/__pycache__/b.pyc", bytes: 50_000)
        var batches: [RuleBatch] = []
        for await batch in RuleEngine.run(try context(home), finders: [.projectArtifacts]) { batches.append(batch) }
        let batch = try #require(batches.first)
        let row = try #require(batch.items.first { $0.ruleID == "artifact.pycache" })
        #expect(row.paths.count == 2)
        let changed = try #require(row.paths.last)
        try FileManager.default.moveItem(at: changed, to: home.root.appendingPathComponent("initial"))
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        #expect(batch.revalidatedItems().isEmpty)
    }

    @Test("Deux fiches indépendantes ne promettent aucun gain pour leurs liens partagés")
    func hardlinksAcrossRows() async throws {
        let home = try FakeHome()
        let first = "Volume/SteamLibrary/steamapps/downloading/1/chunk"
        try home.file(first, bytes: 1_200_000)
        let second = home.root.appendingPathComponent("Volume/SteamLibrary/steamapps/downloading/2/chunk")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: home.root.appendingPathComponent(first), to: second)
        let rows = await RuleEngine.collect(try context(home), finders: [.games]).filter { $0.ruleID == "game.steam.download" }
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.sizes.freeable == 0 })
    }

    @Test("Une fiche couvrant tous les liens garde un gain dédupliqué")
    func hardlinksWithinRow() async throws {
        let home = try FakeHome()
        let first = "Volume/SteamLibrary/steamapps/downloading/1/chunk"
        try home.file(first, bytes: 1_200_000)
        try FileManager.default.linkItem(at: home.root.appendingPathComponent(first),
                                       to: home.root.appendingPathComponent("Volume/SteamLibrary/steamapps/downloading/1/other"))
        let rows = await RuleEngine.collect(try context(home), finders: [.games]).filter { $0.ruleID == "game.steam.download" }
        let row = try #require(rows.first)
        #expect(row.sizes.freeable > 0)
        #expect(row.sizes.freeable <= row.sizes.allocated)
    }
}
