import Darwin
import Foundation
import Testing
@testable import OustDuplicates
import OustScan

@Suite("Les doublons depuis l'arborescence de l'analyse")
struct TreeDuplicateTests {

    /// Les groupes, comparables d'un chemin de recherche à l'autre.
    static func signature(_ groups: [DuplicateGroup]) -> [String] {
        groups.map { group in
            // `FileManager` rend `/private/var/…`, l'arbre le chemin tel qu'on le lui donne.
            group.files.map { "\($0.url.path.replacingOccurrences(of: "/private/var/", with: "/var/")):\($0.logicalSize)" }
                .sorted().joined(separator: "|")
                + " garder=\(group.keep.map { group.files[$0].url.lastPathComponent } ?? "-")"
                + " proposer=\(group.proposed.map { group.files[$0].url.lastPathComponent }.sorted())"
        }.sorted()
    }

    @Test("L'arbre donne les mêmes groupes que le parcours du disque, sans le relire")
    func sameGroupsAsDisk() async throws {
        let pile = try Pile()
        try pile.file("Documents/rapport.pdf")
        try pile.file("Downloads/rapport.pdf")
        try pile.file("a/photo.jpg", bytes: 2_000_000, seed: 3)
        try pile.file("b/photo copie.jpg", bytes: 2_000_000, seed: 3)
        try pile.file("c/autre.jpg", bytes: 2_000_000, seed: 4)
        // Exclus des deux côtés : dossier caché, dossier de construction, paquet.
        try pile.file(".cache/rapport.pdf")
        try pile.file("node_modules/rapport.pdf")
        try pile.file("Outil.app/Contents/rapport.pdf")
        // Ni le lien physique ni le clone ne sont des doublons.
        let original = try pile.file("liens/original.bin", bytes: 1_500_000, seed: 5)
        #expect(Darwin.link(original.path, pile.root.appendingPathComponent("liens/lien.bin").path) == 0)
        _ = clonefile(original.path, pile.root.appendingPathComponent("liens/clone.bin").path, 0)
        // Trop petit.
        try pile.file("petits/un.txt", bytes: 500_000, seed: 6)
        try pile.file("petits/deux.txt", bytes: 500_000, seed: 6)

        let tree = await Scanner.scan([pile.root], options: ScanOptions(leafThreshold: 100_000)).roots[0]
        let diskProgress = DuplicateProgress()
        let fromDisk = await DuplicateFinder.find(pile.options, progress: diskProgress)
        let progress = DuplicateProgress()
        let fromTree = await DuplicateFinder.find(pile.options, tree: tree, progress: progress)

        #expect(fromTree.count == 2)
        #expect(Self.signature(fromTree) == Self.signature(fromDisk))
        // Les mêmes candidats : les fichiers d'au moins 1 Mo hors des dossiers
        // exclus, lien physique et clone compris (écartés ensuite).
        #expect(progress.filesExamined == diskProgress.filesExamined)
        #expect(progress.filesExamined == 8)
    }

    @Test("Un dossier hors de l'arbre est parcouru sur le disque")
    func fallsBackOutsideTree() async throws {
        let pile = try Pile()
        try pile.file("a/x.bin")
        try pile.file("b/x.bin")
        let elsewhere = try Pile()
        let tree = await Scanner.scan([elsewhere.root], options: ScanOptions(leafThreshold: 100_000)).roots[0]

        let groups = await DuplicateFinder.find(pile.options, tree: tree)

        #expect(groups.count == 1)
    }
}
