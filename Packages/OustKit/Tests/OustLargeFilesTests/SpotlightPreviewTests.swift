import Foundation
import Testing
@testable import OustLargeFiles
@testable import OustScan
import OustCore

@Suite("Les gros fichiers selon Spotlight, en attendant l'arbre")
struct SpotlightPreviewTests {

    @Test("Seuls les fichiers assez gros passent, du plus gros au plus petit, paquets signalés")
    func previewFilters() {
        let old = Date(timeIntervalSinceNow: -400 * 86_400)
        let files = [
            SpotlightFile(path: "/Volumes/Exemple/Films/vacances.mov", sizes: Sizes(private: 3_000_000_000), logicalSize: 0,
                          modified: old, fileID: 1),
            SpotlightFile(path: "/Volumes/Exemple/Bureau/petit.zip", sizes: Sizes(private: 50_000_000), logicalSize: 0,
                          modified: old, fileID: 2),
            SpotlightFile(path: "/Applications/Jeu.app/Contents/Resources/data.pak",
                          sizes: Sizes(private: 900_000_000), logicalSize: 0, modified: old, fileID: 3),
            SpotlightFile(path: "/Volumes/Exemple/Documents/recent.iso", sizes: Sizes(private: 2_000_000_000), logicalSize: 0,
                          modified: Date(), fileID: 4),
        ]
        let filter = LargeFileFilter(minimumSize: 100_000_000, unusedSince: Date(timeIntervalSinceNow: -180 * 86_400))

        let result = LargeFileFinder.preview(files, filter: filter)

        #expect(result.files.map(\.url.lastPathComponent) == ["vacances.mov", "data.pak"])
        #expect(result.files.last?.package == "Jeu.app")
        #expect(result.matchBytes == 3_900_000_000)
    }

    @Test("Un paquet Safari compte en espace occupé seulement, dans l'arbre et dans les résultats")
    func safariPackageHasNoGain() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-large-safari-\(UUID())")
        let bundle = home.appendingPathComponent("Downloads/Archive.DOWNLOAD", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let payload = bundle.appendingPathComponent("partiel.txt")
        try Data(repeating: 0x42, count: 2_000_000).write(to: payload)
        let tree = try #require(await Scanner.scan([home]).root)
        #expect(tree.total.allocated >= 2_000_000 && tree.total.freeable == 0)
        let filter = LargeFileFilter(minimumSize: 1_000_000)
        let scan = LargeFileFinder.find(in: tree, filter: filter)
        let preview = LargeFileFinder.preview([
            SpotlightFile(path: payload.path, sizes: Sizes(private: 2_000_000), logicalSize: 2_000_000,
                          modified: nil, fileID: 1)
        ], filter: filter)
        for result in [scan, preview] {
            let file = try #require(result.files.first)
            #expect(result.matchCount == 1 && result.matchBytes == 0)
            #expect(file.sizes.allocated >= 2_000_000 && file.sizes.freeable == 0)
            #expect(file.package == "Archive.DOWNLOAD")
        }
    }
}
