import Darwin
import Foundation
import Synchronization
import Testing
@testable import OustScan
import OustCore

@Suite("Les mesures attachées au volume")
struct BoundMeasurementTests {
    private func anchor(_ fixture: Fixture) throws -> AnalysisRoot {
        let pointer = try #require(realpath(fixture.root.path, nil))
        defer { free(pointer) }
        let url = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        return try #require(AnalysisRoot(url))
    }

    @Test("Les protections redirigées de Preferences et MobileSync accompagnent la remesure")
    func preservesProtectedRoots() async throws {
        let fixture = try Fixture()
        try fixture.file("Volume/Cache/Preferences/invalide.plist", bytes: 4096)
        try fixture.file("Volume/Cache/Appareils/device/payload", bytes: 8192)
        let library = try fixture.directory("Maison/Library")
        let mobile = try fixture.directory("Maison/Library/Application Support/MobileSync")
        let fs = FileManager.default
        try fs.createSymbolicLink(at: library.appendingPathComponent("Preferences", isDirectory: true),
                                  withDestinationURL: fixture.root.appendingPathComponent("Volume/Cache/Preferences", isDirectory: true))
        try fs.createSymbolicLink(at: mobile.appendingPathComponent("Backup", isDirectory: true),
                                  withDestinationURL: fixture.root.appendingPathComponent("Volume/Cache/Appareils", isDirectory: true))
        let anchor = try anchor(fixture)
        let preferences = anchor.url.appendingPathComponent("Volume/Cache/Preferences", isDirectory: true)
        let backups = anchor.url.appendingPathComponent("Volume/Cache/Appareils", isDirectory: true)
        let options = ScanOptions(readOnlyPreferencesDirectory: library.appendingPathComponent("Preferences").path,
                                  deviceBackupsDirectory: mobile.appendingPathComponent("Backup").path)
        let measured = await Scanner.measureBound([preferences, backups], root: anchor, options: options)
        #expect(measured.count == 2)
        #expect(measured.values.allSatisfy { $0.sizes.allocated > 0 && $0.sizes.freeable == 0 })
    }

    @Test("Deux noms d’un même fichier direct ne doublent pas le gain")
    func deduplicatesHardlinkedRoots() async throws {
        let fixture = try Fixture()
        let original = try fixture.file("Corbeille/original", bytes: 32_768)
        let linked = fixture.root.appendingPathComponent("Corbeille/lien", isDirectory: false)
        try FileManager.default.linkItem(at: original, to: linked)
        let anchor = try anchor(fixture)
        let paths = ["original", "lien"].map { anchor.url.appendingPathComponent("Corbeille/" + $0, isDirectory: false) }
        let measured = await Scanner.measureBound(paths, root: anchor)
        let sizes = measured.values.reduce(Sizes.zero) { $0 + $1.sizes }
        #expect(measured.count == 2)
        #expect(sizes.allocated == Fixture.allocated(original))
        #expect(sizes.freeable <= sizes.allocated)
    }

    @Test("Une taille privée inconnue conserve l’occupation et interdit le gain", arguments: [true, false])
    func unknownPrivateSize(directRoot: Bool) async throws {
        let fixture = try Fixture()
        try fixture.file("fichier", bytes: 32_768)
        let anchor = try anchor(fixture)
        var options = ScanOptions.measuring
        options.bindMeasurementsToRoots = true
        let reader: Walk.DirectoryReader?
        if directRoot {
            reader = nil
        } else {
            reader = { _, _, _, visit in
                var entry = RawEntry()
                entry.name = "fichier"
                entry.type = Attr.typeRegular
                entry.device = anchor.identity.directory.device
                entry.fileID = 1
                entry.allocated = 32_768
                entry.logicalSize = 32_768
                visit(entry)
                return 0
            }
        }
        let walk = Walk(options: options, progress: ScanProgress(), ownership: Ownership(),
                        deviceBackupDirectory: .unknown, boundRoot: anchor, readDirectory: reader,
                        blockSharing: { _, _ in (nil, nil) })
        let path = directRoot ? anchor.url.appendingPathComponent("fichier", isDirectory: false) : anchor.url
        let nodes = await walk.run(roots: [path.path])
        let node = try #require(nodes.first)
        #expect(node.status == .inaccessible(code: EIO))
        #expect(node.total.allocated > 0 && node.total.freeable == 0)
    }

    @Test("L’annulation rejoint le parcours natif avant de demander le lot suivant")
    func cancellationReachesNativeWalk() async throws {
        let fixture = try Fixture()
        try fixture.file("dossier/fichier", bytes: 4096)
        let anchor = try anchor(fixture)
        let progress = ScanProgress()
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        var options = ScanOptions()
        options.bindMeasurementsToRoots = true
        let scanOptions = options
        let task = Task {
            await Scanner.scan([anchor.url], options: scanOptions, progress: progress, boundRoot: anchor,
                               readDirectory: { fd, extended, buffer, visit in
                started.signal()
                resume.wait()
                return BulkReader.read(directoryFD: fd, extended: extended, buffer: buffer,
                                       isCancelled: { progress.isCancelled }, visit: visit)
            })
        }
        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + 2) == .success)
            }
        }
        task.cancel()
        #expect(progress.isCancelled)
        resume.signal()
        let result = await task.value
        #expect(didStart)
        #expect(result.roots.first?.status == .inaccessible(code: ECANCELED))
        #expect(progress.fileCount == 0)
    }
}
