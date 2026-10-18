import Darwin
import Foundation
import Testing
@testable import OustLargeFiles
import OustCore
import OustSafety
import OustScan

/// Un disque en miniature dans un dossier temporaire à soi (RULES.md, règle 8).
final class Shelf {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-largefiles-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Un fichier, et ses dates d'accès et de modification reculées de `days` jours.
    @discardableResult
    func file(_ relative: String, bytes: Int, days: Double = 0) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        if days > 0 {
            let seconds = Int(Date().addingTimeInterval(-days * 86_400).timeIntervalSince1970)
            var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
            utimes(url.path, &times)
        }
        return url
    }

    func scan() async throws -> TreeNode {
        try #require(await Scanner.scan([root]).root)
    }
}

@Suite("Gros et vieux fichiers : filtrés depuis l'arborescence, jamais cochés d'office")
struct LargeFilesTests {

    @Test("Taille, nature et date filtrent ; les plus gros d'abord")
    func filters() async throws {
        let shelf = try Shelf()
        try shelf.file("Films/ancien.mov", bytes: 3_000_000, days: 800)
        try shelf.file("Films/recent.mp4", bytes: 4_000_000)
        try shelf.file("Documents/notes.pdf", bytes: 2_000_000, days: 800)
        try shelf.file("Documents/petit.txt", bytes: 20_000, days: 800)
        let root = try await shelf.scan()

        let all = LargeFileFinder.find(in: root, filter: LargeFileFilter(minimumSize: 1_000_000))
        #expect(all.files.map(\.url.lastPathComponent) == ["recent.mp4", "ancien.mov", "notes.pdf"])
        #expect(all.matchCount == 3)

        let videos = LargeFileFinder.find(in: root, filter: LargeFileFilter(minimumSize: 1_000_000, kinds: [.video]))
        #expect(videos.files.map(\.url.lastPathComponent) == ["recent.mp4", "ancien.mov"])

        let yearAgo = Date().addingTimeInterval(-365 * 86_400)
        let old = LargeFileFinder.find(in: root, filter: LargeFileFilter(minimumSize: 1_000_000, unusedSince: yearAgo))
        #expect(old.files.map(\.url.lastPathComponent) == ["ancien.mov", "notes.pdf"])
        let ancient = try #require(old.files.first)
        #expect(ancient.accessed.map { $0 < yearAgo } == true)

        let big = LargeFileFinder.find(in: root, filter: LargeFileFilter(minimumSize: 3_500_000))
        #expect(big.files.map(\.url.lastPathComponent) == ["recent.mp4"])

        let capped = LargeFileFinder.find(in: root, filter: LargeFileFilter(minimumSize: 1_000_000), limit: 1)
        #expect(capped.files.count == 1)
        #expect(capped.matchCount == 3)
    }

    @Test("À examiner, à la corbeille du Mac ; protégé dans un paquet ou hors garde")
    func items() async throws {
        let shelf = try Shelf()
        try shelf.file("Montage.fcpbundle/Rendus/rendu.mov", bytes: 2_000_000, days: 400)
        try shelf.file("Telechargements/archive.zip", bytes: 2_000_000, days: 400)
        let root = try await shelf.scan()
        let files = LargeFileFinder.find(in: root, filter: LargeFileFilter(minimumSize: 1_000_000)).files
        let pathGuard = PathGuard(home: shelf.root.appendingPathComponent("maison"))

        let zip = try #require(files.first { $0.kind == .archive }).cleanupItem(volume: "Disque", guard: pathGuard)
        #expect(zip.safety == .review)
        #expect(zip.method == .trash)
        #expect(zip.isSelectable)
        #expect(!PreselectionPolicy().preselects(zip))

        let render = try #require(files.first { $0.kind == .video })
        #expect(render.package == "Montage.fcpbundle")
        #expect(render.cleanupItem(volume: "Disque", guard: pathGuard).protections == [.insidePackage(name: "Montage.fcpbundle")])
        #expect(!render.cleanupItem(volume: "Disque", guard: pathGuard).isSelectable)

        let system = LargeFileMatch(url: URL(fileURLWithPath: "/System/Library/gros.bin"), sizes: Sizes(private: 2_000_000),
                               modified: nil, accessed: nil, kind: .other, fileID: 1, isClone: false, package: nil)
        #expect(system.cleanupItem(volume: "Disque", guard: pathGuard).protections == [.systemPath])
    }

    @Test("Sans date, un fichier n'est jamais déclaré vieux")
    func undatedIsNeverOld() {
        let file = LargeFileMatch(url: URL(fileURLWithPath: "/tmp/x.bin"), sizes: Sizes(private: 5_000_000), modified: nil,
                             accessed: nil, kind: .other, fileID: 1, isClone: false, package: nil)
        #expect(LargeFileFilter(minimumSize: 1).accepts(file))
        #expect(!LargeFileFilter(minimumSize: 1, unusedSince: Date()).accepts(file))
    }
}
