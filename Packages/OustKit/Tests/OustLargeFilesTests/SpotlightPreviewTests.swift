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
}
