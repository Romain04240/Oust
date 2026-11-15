import Foundation
import OustClean
import OustCore
import OustSafety
import Testing
@testable import OustRules

struct AccountArchivesTests {
    @Test("Les images directes apparaissent en lecture seule avec la taille occupée et un gain nul")
    func readOnlyMetadata() async throws {
        let home = try FakeHome()
        let parent = home.root.appendingPathComponent("Users")
        let archives = parent.appendingPathComponent("Deleted Users")
        let name = "Compte.DMG"
        try home.file("Users/Deleted Users/\(name)", bytes: 180_000)
        try home.text("Users/Deleted Users/Notes.txt", "hors périmètre")
        try home.file("Users/Deleted Users/SousDossier/HorsPerimetre.dmg")
        try home.file("Downloads/Ordinaire.dmg")
        let outside = home.root.appendingPathComponent("Downloads/Ordinaire.dmg")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: archives.appendingPathComponent("Lien.dmg"), withDestinationURL: outside)
        try fm.linkItem(at: outside, to: archives.appendingPathComponent("LienPhysique.dmg"))
        var context = home.context()
        context.accountArchivesRoot = archives
        var stream = RuleEngine.run(context, finders: [.accountArchives]).makeAsyncIterator()
        let batch = try #require(await stream.next())
        let item = try #require(batch.items.first)
        let file = archives.appendingPathComponent(name)
        #expect(batch.items.map(\.title) == [name])
        #expect(item.category == .accountArchives && item.category.section == .system)
        #expect(item.sizes.allocated == FileFacts.of(file.path)?.allocated && item.sizes.allocated > 0)
        #expect(item.sizes.freeable == 0 && item.method == .manual && item.safety == .protected)
        #expect(!item.isSelectable && !PreselectionPolicy().preselects(item))
        #expect(item.notes.isEmpty)

        let moved = parent.appendingPathComponent("AnciennesArchives")
        try fm.moveItem(at: archives, to: moved)
        try fm.createSymbolicLink(at: archives, withDestinationURL: moved)
        #expect(batch.items.isEmpty)
        #expect(await RuleEngine.collect(context, finders: [.accountArchives]).isEmpty)
    }

    @Test("Le gain cloud exclut le dossier d’archives redirigé et ses groupes parents")
    func redirectedArchivesDoNotContributeToCloudGain() throws {
        let home = try FakeHome()
        let fm = FileManager.default
        let providerRoot = home.root.appendingPathComponent("Library/CloudStorage/Fictif")
        let archives = home.root.appendingPathComponent("Users/Deleted Users")
        let account = providerRoot.appendingPathComponent("Lot/Archives/Compte.dmg")
        let groupedNeighbour = providerRoot.appendingPathComponent("Lot/Texte.txt")
        let ordinary = providerRoot.appendingPathComponent("Ordinaire.dmg")
        for file in [account, groupedNeighbour, ordinary] {
            try home.file(String(file.path.dropFirst(home.root.path.count + 1)))
        }
        try fm.createDirectory(at: archives.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: archives, withDestinationURL: account.deletingLastPathComponent())
        var context = home.context()
        context.accountArchivesRoot = archives
        let provider = CloudCopiesFinder.Provider(root: providerRoot, name: "Fictif", rule: "cloud.file_provider")
        let finder = CloudCopiesFinder(context: context)
        let candidates = finder.candidates(for: provider) { _, visit in
            _ = visit(account, 3_000_000, nil)
            _ = visit(groupedNeighbour, 2_000_000, nil)
            _ = visit(ordinary, 1_000_000, nil)
        }

        let item = try #require(candidates.first?.item)
        #expect(candidates.count == 1 && item.paths == [ordinary])
        #expect(item.sizes.allocated == 1_000_000 && item.sizes.freeable == 0)
    }

    @Test("Le moteur refuse une Corbeille générique par chemin direct ou redirigé")
    func vetoOnDirectAndRedirectedPaths() async throws {
        let home = try FakeHome()
        let archives = home.root.appendingPathComponent("Users/Deleted Users")
        let fm = FileManager.default
        try home.file("Users/Deleted Users/Compte.dmg")
        try home.file("Downloads/Ordinaire.dmg")
        let file = archives.appendingPathComponent("Compte.dmg")
        let ordinary = home.root.appendingPathComponent("Downloads/Ordinaire.dmg")
        let viaParent = home.root.appendingPathComponent("AliasUsers")
        try fm.createSymbolicLink(at: viaParent, withDestinationURL: archives.deletingLastPathComponent())
        let redirected = viaParent.appendingPathComponent("Deleted Users/Compte.dmg")
        let trash = home.root.appendingPathComponent("CorbeilleFictive")
        let pathGuard = PathGuard(home: home.root, accountArchivesRoot: archives)
        let engine = CleanupEngine(trasher: FolderTrasher(folder: trash), history: nil, pathGuard: pathGuard,
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil })
        func generic(_ url: URL) -> CleanupItem {
            CleanupItem(title: url.lastPathComponent, paths: [url], category: .explorer,
                        owner: "", ruleID: "explorer.item", safety: .review, method: .trash, rebuild: .irreversible)
        }

        #expect(!pathGuard.allows(file) && !pathGuard.allows(redirected) && pathGuard.allows(ordinary))
        for await _ in engine.run([file, redirected, ordinary].map(generic)) {}
        #expect(fm.fileExists(atPath: file.path))
        #expect(!fm.fileExists(atPath: ordinary.path))
        #expect(try fm.contentsOfDirectory(atPath: trash.path).count == 1)

        let parent = home.root.appendingPathComponent("Entrepot")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let physical = parent.appendingPathComponent("Archives")
        try fm.moveItem(at: archives, to: physical)
        try fm.createSymbolicLink(at: archives, withDestinationURL: physical)
        let archived = physical.appendingPathComponent("Compte.dmg")
        #expect(!pathGuard.allows(archived) && !pathGuard.allows(parent))
        for await _ in engine.run([archived, parent].map(generic)) {}
        #expect(fm.fileExists(atPath: archived.path))
        #expect(try fm.contentsOfDirectory(atPath: trash.path).count == 1)
    }
}
