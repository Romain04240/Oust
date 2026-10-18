import Darwin
import Foundation
import Testing
@testable import OustDuplicates
import OustCore

final class Pile {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-dup-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 1_200_000, seed: UInt8 = 7, created: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(repeating: seed, count: bytes)
        data[bytes / 2] = seed &+ 1
        try data.write(to: url)
        if let created {
            try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        }
        return url
    }

    var options: DuplicateOptions {
        DuplicateOptions(roots: [root], minimumSize: 1_000_000,
                         preferredForRemoval: [root.appendingPathComponent("Downloads")])
    }
}

@Suite("Les doublons, octet pour octet")
struct DuplicateTests {

    @Test("Trois copies identiques forment un groupe ; un fichier de même taille mais différent n'en est pas")
    func findsIdenticalOnly() async throws {
        let pile = try Pile()
        try pile.file("a/photo.jpg")
        try pile.file("b/photo.jpg")
        try pile.file("c/photo.jpg")
        try pile.file("d/autre.jpg", seed: 9)

        let groups = await DuplicateFinder.find(pile.options)

        #expect(groups.count == 1)
        #expect(groups.first?.files.count == 3)
    }

    @Test("Un lien physique ou un clone n'est pas un doublon : il ne rendrait rien")
    func linksAndClonesIgnored() async throws {
        let pile = try Pile()
        let original = try pile.file("original.bin")
        #expect(Darwin.link(original.path, pile.root.appendingPathComponent("lien.bin").path) == 0)
        let cloned = clonefile(original.path, pile.root.appendingPathComponent("clone.bin").path, 0) == 0

        let groups = await DuplicateFinder.find(pile.options)

        #expect(groups.isEmpty, "lien physique\(cloned ? " et clone" : "") écartés")
    }

    @Test("La copie des Téléchargements est proposée, l'original gardé")
    func downloadsCopyProposed() async throws {
        let pile = try Pile()
        try pile.file("Documents/rapport.pdf")
        try pile.file("Downloads/rapport.pdf")

        let group = try #require(await DuplicateFinder.find(pile.options).first)
        let keep = try #require(group.keep)

        #expect(group.files[keep].url.path.contains("/Documents/"))
        #expect(group.proposed.map { group.files[$0].url.path.contains("/Downloads/") } == [true])
        #expect(group.reclaimable > 0)
    }

    @Test("Un nom de copie est proposé, l'autre gardé")
    func copyNameProposed() async throws {
        let pile = try Pile()
        try pile.file("photos/vacances.jpg")
        try pile.file("photos/vacances copie.jpg")

        let group = try #require(await DuplicateFinder.find(pile.options).first)

        #expect(group.proposed.map { group.files[$0].url.lastPathComponent } == ["vacances copie.jpg"])
    }

    @Test("Égalité parfaite : rien n'est proposé")
    func tieProposesNothing() async throws {
        let pile = try Pile()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try pile.file("x/fichier.bin", created: date)
        try pile.file("y/fichier.bin", created: date)

        let group = try #require(await DuplicateFinder.find(pile.options).first)

        #expect(group.keep == nil)
        #expect(group.proposed.isEmpty)
        #expect(group.cleanupItems().isEmpty)
    }

    @Test("Le plus ancien est gardé quand rien d'autre ne départage")
    func oldestKept() async throws {
        let pile = try Pile()
        try pile.file("x/fichier.bin", created: Date(timeIntervalSince1970: 1_600_000_000))
        try pile.file("y/fichier.bin", created: Date(timeIntervalSince1970: 1_700_000_000))

        let group = try #require(await DuplicateFinder.find(pile.options).first)
        let keep = try #require(group.keep)

        #expect(group.files[keep].url.path.contains("/x/"))
        let items = group.cleanupItems(asClones: true)
        #expect(items.count == 1)
        #expect(items.first?.method == .cloneOf(original: group.files[keep].url.path))
    }

    @Test("Jamais toutes les copies d'un groupe")
    func neverAll() {
        let files = (0..<3).map { index in
            DuplicateFile(url: URL(fileURLWithPath: "/t/Downloads/f\(index).bin"), logicalSize: 1, allocated: 1,
                          privateSize: 1, modified: nil, created: nil)
        }
        let options = DuplicateOptions(roots: [], preferredForRemoval: [URL(fileURLWithPath: "/t/Downloads")])
        let choice = SmartSelection(options: options).choose(files)
        #expect(choice.remove.count < files.count)
    }

    @Test("Reconnaître un nom de copie", arguments: [
        ("rapport copie.pdf", true), ("Copy of photo.jpg", true), ("image (2).png", true), ("film 2.mkv", true),
        ("photo.jpg", false), ("2026-rapport.pdf", false), ("copieur.pdf", false),
    ])
    func copyNames(name: String, expected: Bool) {
        #expect(SmartSelection.looksLikeCopy(URL(fileURLWithPath: "/t/" + name)) == expected)
    }
}

@Suite("Les doublons d'un autre disque")
struct VolumeDuplicateTests {

    @Test("Ni dans les sauvegardes Time Machine, ni dans une bibliothèque Final Cut, ni dans une machine virtuelle")
    func skipsProtectedPackages() async throws {
        let pile = try Pile()
        try pile.file("Rushes/plan.mov")
        try pile.file("Copie/plan.mov")
        try pile.file("Backups.backupdb/Mac/2026-10-01-101500/Rushes/plan.mov")
        try pile.file("Montage/Film.fcpbundle/Tournage/Original Media/plan.mov")
        try pile.file("VM/Windows.utm/Data/plan.mov")
        try pile.file("Mac.backupbundle/bands/plan.mov")

        let groups = await DuplicateFinder.find(DuplicateOptions(roots: [pile.root], minimumSize: 1_000_000))

        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(Set(group.files.map { $0.url.deletingLastPathComponent().lastPathComponent }) == ["Rushes", "Copie"])
    }
}
