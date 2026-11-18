import Foundation
import OustCore
import OustSafety
import Testing
@testable import OustRules

@Suite("Les preuves du catalogue Lightroom")
struct LightroomProofRegressionTests {
    private func context(_ home: FakeHome) throws -> RuleContext {
        let anchor = try home.openVolume(home.root.appendingPathComponent("Volume", isDirectory: true))
        var context = home.context()
        context.volume = VolumeScope(root: anchor.url, name: "Test", fileSystem: "apfs")
        context.volume?.root = anchor.url
        context.volumeAnchor = anchor
        return context
    }

    @Test("Un catalogue disparu ou redirigé conserve une preuve obligatoire et invalide", arguments: [false, true])
    func missingOrRedirectedCatalog(redirected: Bool) async throws {
        let home = try FakeHome()
        try home.text("Volume/Photos/Studio.lrcat", "catalogue")
        try home.file("Volume/Photos/Studio Previews.lrdata/apercu", bytes: 4096)
        try home.text("Autre.lrcat", "catalogue extérieur")
        let context = try context(home)
        let candidates = await ProAppsFinder(context: context).lightroomPreviews()
        let candidate = try #require(candidates.first)
        #expect(candidate.item.protections.isEmpty)
        let proof = try #require(candidate.boundProof)
        #expect(proof())

        let catalog = home.root.appendingPathComponent("Volume/Photos/Studio.lrcat", isDirectory: false)
        try FileManager.default.removeItem(at: catalog)
        if redirected {
            try FileManager.default.createSymbolicLink(at: catalog,
                                                       withDestinationURL: home.root.appendingPathComponent("Autre.lrcat"))
        }
        #expect(!proof())
        let items = await RuleEngine.measure(candidates, using: Measurer { _ in
            Issue.record("Un catalogue invérifiable ne doit pas atteindre la mesure.")
            return [:]
        }, pathGuard: PathGuard(home: home.root), volumeAnchor: context.volumeAnchor)
        #expect(items.isEmpty)
    }

    @Test("L’apparition du catalogue de base invalide les aperçus dynamiques")
    func smartCatalogAppears() async throws {
        let home = try FakeHome()
        try home.text("Volume/Photos/Studio Smart.lrcat", "catalogue")
        try home.file("Volume/Photos/Studio Smart Previews.lrdata/apercu", bytes: 4096)
        let context = try context(home)
        let candidates = await ProAppsFinder(context: context).lightroomPreviews()
        let candidate = try #require(candidates.first)
        let proof = try #require(candidate.boundProof)
        #expect(proof())

        try home.text("Volume/Photos/Studio.lrcat", "catalogue de base")
        #expect(!proof())
        let items = await RuleEngine.measure(candidates, using: Measurer { _ in
            Issue.record("Un aperçu dynamique reconnu après la détection doit être écarté.")
            return [:]
        }, pathGuard: PathGuard(home: home.root), volumeAnchor: context.volumeAnchor)
        #expect(items.isEmpty)
        let refreshed = await ProAppsFinder(context: context).lightroomPreviews()
        #expect(refreshed.isEmpty)
    }
}
