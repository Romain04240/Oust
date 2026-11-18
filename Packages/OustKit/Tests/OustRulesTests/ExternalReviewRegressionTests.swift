import Foundation
import Synchronization
import Testing
@testable import OustRules
import OustCore
import OustScan
import OustSafety

@Suite("Régressions de la revue des volumes externes")
struct ExternalReviewRegressionTests {
    private func context(_ home: FakeHome) async throws -> RuleContext {
        let root = home.root.appendingPathComponent("Volume", isDirectory: true)
        let anchor = try home.openVolume(root)
        let (index, _) = await ScanIndex.refreshBound(nil, root: anchor, options: ScanOptions(), progress: ScanProgress())
        var context = home.context()
        context.volume = VolumeScope(root: anchor.url, name: "Test", fileSystem: "apfs")
        context.volume?.root = anchor.url
        context.volumeAnchor = anchor
        context.projectRoots = [anchor.url]
        context.tree = { index.root }
        return context
    }

    @Test("Un cache vidé sans remplacer le dossier perd son ancien gain")
    func emptiedCache() async throws {
        let home = try FakeHome()
        try home.text("Volume/Dev/package.json", "{}")
        try home.file("Volume/Dev/node_modules/cache", bytes: 1_200_000)
        let context = try await context(home)
        try FileManager.default.removeItem(at: home.root.appendingPathComponent("Volume/Dev/node_modules/cache"))
        let items = await RuleEngine.collect(context, finders: [.projectArtifacts])
        #expect(items.allSatisfy { $0.sizes.freeable < 1_200_000 })
    }

    @Test("Un petit fichier lisible dans la Corbeille garde une mesure disponible")
    func smallTrashFile() async throws {
        let home = try FakeHome()
        try home.file("Volume/.Trashes/\(getuid())/petit", bytes: 4096)
        let context = try await context(home)
        let items = await RuleEngine.collect(context, finders: [.volumeTrash])
        let trash = try #require(items.first)
        #expect(trash.sizes.allocated >= 4096)
        #expect(!trash.protections.contains(.unknownState))
    }

    @Test("Un manifeste ou un verrou nouveau invalide la classification avant publication")
    func dependencyChanged() async throws {
        let home = try FakeHome()
        try home.file("Volume/SteamLibrary/steamapps/common/Jeu/donnees", bytes: 1_200_000)
        try home.text("Volume/Photo/Catalogue.lrcat", "catalogue")
        try home.file("Volume/Photo/Catalogue Previews.lrdata/cache", bytes: 1_200_000)
        let context = try await context(home)
        let steam = await GamesFinder(context: context).find()
        let previews = await ProAppsFinder(context: context).find()
        #expect(steam.contains { $0.item.ruleID == "game.steam.leftover" })
        #expect(previews.contains { $0.item.ruleID == "creative.lightroom.previews" })
        var batches: [RuleBatch] = []
        for await batch in RuleEngine.run(context, finders: [.games, .pro]) { batches.append(batch) }
        try home.text("Volume/SteamLibrary/steamapps/appmanifest_42.acf", #""installdir" "Jeu""#)
        try home.text("Volume/Photo/Catalogue.lrcat.lock", "")
        #expect(!batches.flatMap { $0.revalidatedItems() }.contains {
            $0.ruleID == "game.steam.leftover" || $0.ruleID == "creative.lightroom.previews"
        })
        let measured = await RuleEngine.measure(steam + previews, using: .disk,
                                               pathGuard: PathGuard(home: home.root), volumeAnchor: context.volumeAnchor)
        #expect(!measured.contains { $0.ruleID == "game.steam.leftover" || $0.ruleID == "creative.lightroom.previews" })
    }

    @Test("Un worker expiré conserve son verrou jusqu’à sa sortie réelle")
    func timedOutWorkerRetainsSlot() async {
        let gate = BoundRuleRun()
        let state = Mutex<(calls: Int, release: (@Sendable () -> Void)?)>((0, nil))
        let blocked: @Sendable (@escaping @Sendable () -> Void) -> AsyncStream<RuleBatch> = { release in
            state.withLock { $0.calls += 1; $0.release = release }
            return AsyncStream { _ in }
        }
        for await _ in gate.run(timeout: .milliseconds(30), work: blocked) {}
        for await _ in gate.run(timeout: .milliseconds(30), work: blocked) {}
        #expect(state.withLock { $0.calls } == 1)
        state.withLock { $0.release }?()
        for await _ in gate.run(timeout: .seconds(1), work: { release in
            release()
            return AsyncStream { $0.finish() }
        }) {}
    }
}
