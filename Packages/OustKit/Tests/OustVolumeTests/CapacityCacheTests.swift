import Foundation
import Testing
@testable import OustVolume

@Suite("La capacité est relue, pas tirée d'un cache")
struct CapacityCacheTests {
    /// Le 18/10/2026, le bilan relisait avant et après le nettoyage une capacité
    /// que Foundation garde en cache pour tout le volume, et accusait les
    /// snapshots de retenir ce que le volume avait déjà rendu. Une URL neuve ne
    /// suffisait pas : 64 Mo passaient, 400 Mo restaient invisibles.
    @Test("Écrire 400 Mo se voit dans l'espace libre, même relu par la même URL")
    func capacityIsFresh() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-volume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try #require(VolumeService.capacity(of: folder)).available

        let file = folder.appendingPathComponent("plein.bin")
        try Data(repeating: 0x5A, count: 400_000_000).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.synchronize()
        try handle.close()

        // Pas l'égalité exacte : d'autres processus écrivent et libèrent aussi.
        let after = try #require(VolumeService.capacity(of: folder)).available
        #expect(before - after > 200_000_000, "avant \(before), après \(after)")
    }
}
