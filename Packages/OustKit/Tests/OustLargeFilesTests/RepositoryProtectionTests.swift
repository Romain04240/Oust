import Foundation
import Testing
@testable import OustLargeFiles
import OustCore
import OustSafety

@Suite("Ce qui ne se retire pas fichier par fichier")
struct RepositoryProtectionTests {
    /// Le 18/10/2026, Gros fichiers proposait seul un pack git de 4,6 Go :
    /// le jeter cassait le dépôt.
    @Test("Un pack git, un .dSYM et le disque d'une VM sont protégés ; un film ne l'est pas")
    func protectsInsides() async throws {
        let shelf = try Shelf()
        try shelf.file("Projets/Meteo/.git/objects/pack/pack-1234.pack", bytes: 3_000_000)
        try shelf.file("Projets/Outil.git/objects/pack/pack-5678.pack", bytes: 2_500_000)
        try shelf.file("Archives/App.app.dSYM/Contents/Resources/DWARF/App", bytes: 2_000_000)
        try shelf.file("Machines/Windows.vmwarevm/Disque.vmdk", bytes: 4_000_000)
        try shelf.file("Films/vacances.mov", bytes: 1_500_000)
        let root = try await shelf.scan()

        let found = LargeFileFinder.find(in: root, filter: LargeFileFilter(minimumSize: 1_000_000)).files
        let items = Dictionary(uniqueKeysWithValues: found.map {
            ($0.url.lastPathComponent, $0.cleanupItem(volume: "Test", guard: PathGuard(home: shelf.root)))
        })
        #expect(items["pack-1234.pack"]?.protections.first == .insidePackage(name: "Meteo/.git"))
        #expect(items["pack-5678.pack"]?.protections.first == .insidePackage(name: "Outil.git"))
        #expect(items["App"]?.protections.first == .insidePackage(name: "App.app.dSYM"))
        #expect(items["Disque.vmdk"]?.protections.first == .insidePackage(name: "Windows.vmwarevm"))
        #expect(items["vacances.mov"]?.isSelectable == true)
    }
}
