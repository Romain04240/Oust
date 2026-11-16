import Darwin
import Foundation
import Testing
@testable import OustScan

@Suite("Le parcours compte juste")
struct ScannerTests {

    @Test("Une sauvegarde d’appareil imbriquée ou redirigée occupe de la place et ne promet aucun gain")
    func deviceBackupDirectory() async throws {
        let fixture = try Fixture()
        let file = try fixture.file("stockage/copied/device/payload.bin", bytes: 250_000)
        let ordinary = try fixture.file("ordinaire.bin", bytes: 250_000, byte: 0x42)
        let parent = try fixture.directory("Library/Application Support/MobileSync")
        let backups = parent.appendingPathComponent("Backup")
        try FileManager.default.createSymbolicLink(at: backups,
                                                  withDestinationURL: fixture.root.appendingPathComponent("stockage/copied"))
        let options = ScanOptions(leafThreshold: 1, deviceBackupsDirectory: backups.path)
        let result = await Scanner.scan([fixture.root], options: options)
        let tree = try #require(result.root)
        let backup = try #require(tree.descendant(atPath: file.deletingLastPathComponent().path))
        #expect(backup.total.allocated == Fixture.allocated(file))
        #expect(backup.total.freeable == 0)
        #expect(tree.total.freeable == Fixture.allocated(ordinary))
        let spotlight = Spotlight.parse(Data((file.path + "\0" + ordinary.path + "\0").utf8), minimumBytes: 1,
                                        deviceBackupsDirectory: backups.path)
        #expect(spotlight.first { $0.path == file.path }?.sizes.freeable == 0)
        #expect(spotlight.first { $0.path == ordinary.path }?.sizes.freeable == Fixture.allocated(ordinary))
    }

    @Test("Un lien individuel ajouté après le scan invalide les gains et s’applique au nouveau parcours")
    func redirectedDeviceInvalidatesIndex() async throws {
        let fixture = try Fixture()
        let file = try fixture.file("stockage/appareil/payload.bin", bytes: 260_000)
        let backups = try fixture.directory("MobileSync/Backup")
        let options = ScanOptions(leafThreshold: 1, deviceBackupsDirectory: backups.path)
        let initial = await ScanIndex.refresh(nil, root: fixture.root, options: options).index
        #expect(initial.root.total.freeable > 0)
        try FileManager.default.createSymbolicLink(at: backups.appendingPathComponent("device"),
                                                  withDestinationURL: file.deletingLastPathComponent())
        #expect(!initial.hasCurrentProtectionRoots)
        #expect(initial.checkedForDisplay().root.total.freeable == 0)
        let current = await ScanIndex.refresh(initial, root: fixture.root, options: options).index
        let backup = try #require(current.root.descendant(atPath: file.deletingLastPathComponent().path))
        #expect(backup.total.allocated > 0 && backup.total.freeable == 0)
        let spotlight = Spotlight.parse(Data((file.path + "\0").utf8), minimumBytes: 1,
                                         deviceBackupsDirectory: backups.path)
        #expect(spotlight.first?.sizes.freeable == 0)
    }

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
