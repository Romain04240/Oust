import Darwin
import Foundation
import Testing
@testable import OustDuplicates
import OustScan

@Suite("Ce que rend une copie")
struct PrivateSizeTests {
    /// Le 18/10/2026, chaque copie affichait « — » : APFS rend une part privée
    /// de 0 pour un fichier qui ne partage aucun bloc, et elle était prise telle
    /// quelle au lieu de la taille allouée.
    @Test("Une copie ordinaire rend toute sa taille allouée")
    func plainCopy() async throws {
        let pile = try Pile()
        try pile.file("a/photo.raw", bytes: 2_000_000)
        try pile.file("b/photo.raw", bytes: 2_000_000)
        let group = try #require(await DuplicateFinder.find(pile.options).first)
        #expect(Scanner.privateSize(of: group.files[0].url) == nil)
        #expect(group.files.allSatisfy { $0.privateSize == $0.allocated && $0.allocated >= 2_000_000 })
        #expect(group.potential >= 2_000_000)
    }

    @Test("Un clone APFS partage ses blocs : sa part privée est lue, pas sa taille")
    func clonedFile() throws {
        let pile = try Pile()
        let original = try pile.file("original.bin", bytes: 2_000_000)
        let clone = pile.root.appendingPathComponent("clone.bin")
        try #require(clonefile(original.path, clone.path, 0) == 0)
        let shared = try #require(Scanner.privateSize(of: clone))
        #expect(shared < 2_000_000)
    }
}
