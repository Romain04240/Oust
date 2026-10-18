import Foundation
import Testing
@testable import OustDuplicates

@Suite("La sélection automatique à égalité")
struct TieBreakTests {
    private func file(_ path: String, created: Date? = Date(timeIntervalSince1970: 1_000)) -> DuplicateFile {
        DuplicateFile(url: URL(fileURLWithPath: path), logicalSize: 10, allocated: 16, privateSize: 16,
                      modified: created, created: created)
    }

    @Test("À dates égales, le chemin le plus court est gardé et les autres sont cochés")
    func shortestPath() throws {
        let files = [file("/u/Documents/Projet/plan.pdf"), file("/u/plan.pdf"), file("/u/Archives/plan.pdf")]
        let selection = SmartSelection(options: DuplicateOptions(roots: []))
        #expect(selection.choose(files).keep == nil)
        let choice = try #require(selection.tieBreak(files))
        #expect(choice.keep == 1)
        #expect(choice.remove == [0, 2])
    }

    @Test("Le plus ancien passe avant le chemin le plus court")
    func oldestFirst() throws {
        let files = [file("/u/a/b/c/photo.jpg", created: Date(timeIntervalSince1970: 10)), file("/u/photo.jpg")]
        let choice = try #require(SmartSelection(options: DuplicateOptions(roots: [])).tieBreak(files))
        #expect(choice.keep == 0)
        #expect(choice.remove == [1])
    }

    @Test("Un dossier de référence est gardé et n'est jamais coché")
    func referenceFolders() throws {
        let options = DuplicateOptions(roots: [], referenceFolders: [URL(fileURLWithPath: "/u/Référence")])
        let files = [file("/u/x.mov"), file("/u/Référence/longue/route/x.mov"), file("/u/Référence/x.mov")]
        let choice = try #require(SmartSelection(options: options).tieBreak(files))
        #expect(choice.keep == 2)
        #expect(choice.remove == [0])
    }

    @Test("Un fichier seul, ou rien à retirer : aucune sélection")
    func nothing() {
        let selection = SmartSelection(options: DuplicateOptions(roots: [], referenceFolders: [URL(fileURLWithPath: "/u")]))
        #expect(selection.tieBreak([file("/u/seul.txt")]) == nil)
        #expect(selection.tieBreak([file("/u/a.txt"), file("/u/b.txt")]) == nil)
    }
}
