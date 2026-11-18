import Darwin
import Foundation
import Testing
@testable import OustScan
import OustCore

@Suite("Lecture partielle d’un dossier")
struct PartialReadTests {
    @Test("Une erreur après un fichier valide conserve le statut incomplet", arguments: [false, true])
    func partialRead(entryError: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 3, count: 4096).write(to: root.appendingPathComponent("lisible"))
        let walk = Walk(options: ScanOptions(measurePrivateSizes: false), progress: ScanProgress(),
                        ownership: Ownership(), deviceBackupDirectory: .unknown,
                        readDirectory: { fd, extended, buffer, visit in
            let status = BulkReader.read(directoryFD: fd, extended: extended, buffer: buffer, visit: visit)
            guard status == 0 else { return status }
            if entryError {
                var failed = RawEntry()
                failed.name = "illisible"
                failed.error = UInt32(EIO)
                visit(failed)
                return 0
            }
            return EIO
        })
        let nodes = await walk.run(roots: [root.path])
        let node = try #require(nodes.first)
        #expect(node.status == .inaccessible(code: EIO))
        #expect(node.total.allocated >= 4096)
        #expect(node.inaccessibleCount > 0)
    }
}
