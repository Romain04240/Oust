import Darwin
import Foundation
import Synchronization
import Testing
@testable import OustScan
import OustCore

@Suite("Exclusions des racines et gain des liens physiques")
struct ExcludedRootsAndLinksTests {
    private func anchor(_ fixture: Fixture) throws -> AnalysisRoot {
        let physical = try #require(realpath(fixture.root.path, nil))
        defer { free(physical) }
        let url = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        return try #require(AnalysisRoot(url))
    }

    @Test("Une racine exclue et ses descendants ne sont jamais ouverts", arguments: [false, true])
    func excludedRoot(shortenedAlias: Bool) async throws {
        let fixture = try Fixture()
        try fixture.file("Backups.backupdb/Mac/fichier", bytes: 4096)
        let root = try anchor(fixture)
        let excluded = root.url.appendingPathComponent("Backups.backupdb", isDirectory: true)
        let exclusion: String
        if shortenedAlias, excluded.path.hasPrefix("/private/var/") {
            exclusion = String(excluded.path.dropFirst("/private".count))
        } else {
            exclusion = excluded.path
        }
        var options = ScanOptions(excludedPaths: [exclusion])
        options.bindMeasurementsToRoots = true
        let reads = Mutex(0)
        let walk = Walk(options: options, progress: ScanProgress(), ownership: Ownership(),
                        deviceBackupDirectory: .unknown, boundRoot: root,
                        readDirectory: { _, _, _, _ in
            reads.withLock { $0 += 1 }
            Issue.record("Une exclusion de racine ne doit pas appeler le lecteur natif")
            return EIO
        })
        let nodes = await walk.run(roots: [excluded.path, excluded.appendingPathComponent("Mac", isDirectory: true).path])
        #expect(nodes.count == 2)
        #expect(nodes.allSatisfy { $0.status == .excluded && $0.total == .zero })
        #expect(reads.withLock { $0 } == 0)
        let measured = await Scanner.measureBound([excluded], root: root, options: options)
        #expect(measured[excluded]?.sizes == .zero)
        #expect(measured[excluded]?.inaccessible == true)
    }

    @Test("Un lien conservé hors sélection annule le gain du nom choisi")
    func survivingUnselectedLink() async throws {
        let fixture = try Fixture()
        let selected = try fixture.file("Corbeille/original", bytes: 32_768)
        let kept = fixture.root.appendingPathComponent("garde", isDirectory: false)
        try FileManager.default.linkItem(at: selected, to: kept)
        let root = try anchor(fixture)
        let target = root.url.appendingPathComponent("Corbeille/original", isDirectory: false)
        let measured = await Scanner.measureBound([target], root: root)
        let sizes = try #require(measured[target]?.sizes)
        #expect(sizes.allocated == Fixture.allocated(selected))
        #expect(sizes.freeable == 0)
    }

    @Test("Un dossier choisi ne récupère pas les blocs d’un lien gardé ailleurs")
    func directoryWithSurvivingLink() async throws {
        let fixture = try Fixture()
        let selected = try fixture.file("Corbeille/original", bytes: 32_768)
        try FileManager.default.linkItem(at: selected, to: fixture.root.appendingPathComponent("garde", isDirectory: false))
        let root = try anchor(fixture)
        let folder = root.url.appendingPathComponent("Corbeille", isDirectory: true)
        let measured = await Scanner.measureBound([folder], root: root)
        #expect(measured[folder]?.sizes.allocated == Fixture.allocated(selected))
        #expect(measured[folder]?.sizes.freeable == 0)
    }

    @Test("Des racines fichier et dossier couvrant tous les liens conservent un gain dédupliqué")
    func selectedDirectoryAndFile() async throws {
        let fixture = try Fixture()
        let selected = try fixture.file("Corbeille/original", bytes: 32_768)
        try FileManager.default.linkItem(at: selected, to: fixture.root.appendingPathComponent("autre", isDirectory: false))
        let root = try anchor(fixture)
        let folder = root.url.appendingPathComponent("Corbeille", isDirectory: true)
        let other = root.url.appendingPathComponent("autre", isDirectory: false)
        let measured = await Scanner.measureBound([folder, other], root: root)
        let sizes = measured.values.reduce(Sizes.zero) { $0 + $1.sizes }
        #expect(sizes.allocated == Fixture.allocated(selected))
        #expect(sizes.freeable > 0 && sizes.freeable <= sizes.allocated)
    }
}
