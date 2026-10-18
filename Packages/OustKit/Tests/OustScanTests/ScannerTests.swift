import Darwin
import Foundation
import Testing
@testable import OustScan

@Suite("Le parcours compte juste")
struct ScannerTests {

    @Test("La taille allouée est celle que rapporte stat")
    func allocatedMatchesStat() async throws {
        let fixture = try Fixture()
        let a = try fixture.file("a.bin", bytes: 300_000)
        let b = try fixture.file("dossier/b.bin", bytes: 2_000_000)
        let c = try fixture.file("dossier/profond/c.txt", bytes: 10)

        let measure = await Scanner.measure(fixture.root)

        let expected = [a, b, c].map(Fixture.allocated).reduce(0, +)
        #expect(measure.sizes.allocated == expected)
        #expect(measure.fileCount == 3)
    }

    @Test("Un lien physique n'est compté qu'une fois")
    func hardLinkCountedOnce() async throws {
        let fixture = try Fixture()
        let original = try fixture.file("original.bin", bytes: 1_500_000)
        let link = fixture.root.appendingPathComponent("autre/lien.bin")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(Darwin.link(original.path, link.path) == 0)

        let measure = await Scanner.measure(fixture.root)

        #expect(measure.sizes.allocated == Fixture.allocated(original))
    }

    @Test("Un clone APFS complet n'occupe rien de plus")
    func cloneCountedOnce() async throws {
        let fixture = try Fixture()
        let original = try fixture.file("original.bin", bytes: 4_000_000)
        let clone = fixture.root.appendingPathComponent("clone.bin")
        guard clonefile(original.path, clone.path, 0) == 0 else {
            // Volume sans clones (pas APFS) : rien à vérifier ici.
            return
        }

        let measure = await Scanner.measure(fixture.root)

        #expect(measure.sizes.allocated == Fixture.allocated(original))
        #expect(measure.fileCount == 2)
    }

    @Test("Un lien symbolique n'est jamais suivi")
    func symlinkNotFollowed() async throws {
        let fixture = try Fixture()
        let outside = try Fixture()
        try outside.file("gros.bin", bytes: 5_000_000)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("raccourci"),
                                                   withDestinationURL: outside.root)
        try fixture.file("petit.txt", bytes: 100)

        let measure = await Scanner.measure(fixture.root)

        #expect(measure.sizes.allocated < 1_000_000)
    }

    @Test("Un dossier interdit est signalé, pas ignoré")
    func inaccessibleDirectoryIsReported() async throws {
        let fixture = try Fixture()
        try fixture.file("ferme/secret.bin", bytes: 1_000)
        try fixture.file("ouvert/libre.bin", bytes: 1_000)
        let closed = fixture.root.appendingPathComponent("ferme")
        chmod(closed.path, 0o000)
        defer { chmod(closed.path, 0o755) }

        let result = await Scanner.scan([fixture.root])
        let root = try #require(result.root)
        let node = try #require(root.children.first { $0.name == "ferme" })

        #expect(node.status.isInaccessible)
        #expect(root.inaccessibleCount == 1)
        #expect(root.inaccessiblePaths().contains(closed.path))
    }

    @Test("Les gros fichiers sont montrés un à un, les petits regroupés")
    func leavesAndSmallFiles() async throws {
        let fixture = try Fixture()
        try fixture.file("gros.bin", bytes: 3_000_000)
        try fixture.file("moyen.bin", bytes: 1_200_000)
        for index in 0..<5 { try fixture.file("petit-\(index).txt", bytes: 500) }

        let result = await Scanner.scan([fixture.root], options: ScanOptions(leafThreshold: 1_000_000))
        let root = try #require(result.root)

        #expect(root.files.map(\.name) == ["gros.bin", "moyen.bin"])
        #expect(root.smallFileCount == 5)
        #expect(root.fileCount == 7)
    }

    @Test("Les enfants sont triés du plus gros au plus petit, totaux compris")
    func childrenSortedBySize() async throws {
        let fixture = try Fixture()
        try fixture.file("petit/a.bin", bytes: 100_000)
        try fixture.file("gros/a.bin", bytes: 3_000_000)
        try fixture.file("gros/sous/b.bin", bytes: 3_000_000)
        try fixture.file("moyen/a.bin", bytes: 1_000_000)

        let result = await Scanner.scan([fixture.root])
        let root = try #require(result.root)

        #expect(root.children.map(\.name) == ["gros", "moyen", "petit"])
        let big = try #require(root.children.first)
        #expect(big.total.allocated == big.children[0].total.allocated + big.ownFiles.allocated)
        #expect(root.node(at: fixture.root.path + "/gros/sous")?.name == "sous")
    }

    @Test("Plusieurs éléments se mesurent ensemble, chacun à part")
    func measureSeveral() async throws {
        let fixture = try Fixture()
        let one = try fixture.directory("un")
        let two = try fixture.directory("deux")
        let a = try fixture.file("un/a.bin", bytes: 700_000)
        let b = try fixture.file("deux/b.bin", bytes: 1_700_000)

        let measures = await Scanner.measure([one, two])

        #expect(measures[one]?.sizes.allocated == Fixture.allocated(a))
        #expect(measures[two]?.sizes.allocated == Fixture.allocated(b))
    }

    @Test("Un chemin exclu n'est pas parcouru")
    func excludedPathSkipped() async throws {
        let fixture = try Fixture()
        try fixture.file("garde/a.bin", bytes: 2_000_000)
        try fixture.file("exclu/b.bin", bytes: 2_000_000)
        let excluded = fixture.root.appendingPathComponent("exclu").path

        let result = await Scanner.scan([fixture.root], options: ScanOptions(excludedPaths: [excluded]))
        let root = try #require(result.root)

        #expect(root.children.first { $0.name == "exclu" }?.status == .excluded)
        #expect(root.total.allocated < 3_000_000)
    }

    @Test("La table des montages connaît le volume de données sous ses deux noms")
    func mountTableKnowsDataVolume() {
        let points = MountTable.mountPoints()
        #expect(points.contains("/System/Volumes/Data"))
        #expect(!points.contains("/"))
    }
}
