import Foundation
import Testing
import OustScan
@testable import OustSunburst

/// Une arborescence réelle, analysée par `OustScan`, dans un dossier temporaire
/// à soi (RULES.md, règle 8).
final class Garden {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-sunburst-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ relative: String, blocks: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: blocks * 4_096).write(to: url)
    }

    /// Un gros dossier (« Grand »), un moyen (« Moyen »), quarante brins trop fins
    /// pour un segment, et des petits fichiers à la racine.
    func plant() async throws -> TreeNode {
        try file("Grand/a.bin", blocks: 1_000)
        try file("Grand/Sous/b.bin", blocks: 500)
        try file("Moyen/c.bin", blocks: 400)
        for index in 0..<40 { try file("Brins/brin-\(index)/d.txt", blocks: 1) }
        try file("note.txt", blocks: 60)
        return try #require(await Scanner.scan([root]).root)
    }
}

@Suite("La vue soleil : chaque anneau un niveau, chaque segment sa vraie part")
struct SunburstTests {

    @Test("L'anneau intérieur fait le tour, du plus gros au plus petit")
    func firstRing() async throws {
        let garden = try Garden()
        let root = try await garden.plant()
        let layout = SunburstLayout(root: root, rings: 3)

        let ring = layout.segments.filter { $0.depth == 1 }
        #expect(ring.first?.name == "Grand")
        #expect(ring.first?.start == 0)
        #expect(abs((ring.last?.end ?? 0) - 1) < 1e-9)
        for (left, right) in zip(ring, ring.dropFirst()) {
            #expect(abs(left.end - right.start) < 1e-9)
        }
        let named = ring.filter { $0.kind == .directory }
        #expect(named.map(\.bytes) == named.map(\.bytes).sorted(by: >))
        #expect(named.map(\.branch) == Array(0..<named.count).map(Optional.some))
    }

    @Test("Les enfants restent dans la part de leur parent")
    func childrenNest() async throws {
        let garden = try Garden()
        let root = try await garden.plant()
        let layout = SunburstLayout(root: root, rings: 3)
        let grand = try #require(layout.segments.first { $0.name == "Grand" })

        let inside = layout.segments.filter { $0.depth == 2 && $0.path.hasPrefix(grand.path + "/") }
        #expect(Set(inside.map(\.name)) == ["a.bin", "Sous"])
        #expect(inside.allSatisfy { $0.start >= grand.start - 1e-9 && $0.end <= grand.end + 1e-9 })
        #expect(inside.allSatisfy { $0.branch == grand.branch })
        let file = try #require(inside.first { $0.name == "a.bin" })
        #expect(file.kind == .file)
        #expect(file.node == nil)
        #expect(layout.segments.allSatisfy { $0.depth <= 3 })
    }

    @Test("Ce qui est trop fin rejoint « Autres », les petits fichiers restent groupés")
    func groups() async throws {
        let garden = try Garden()
        let root = try await garden.plant()
        let layout = SunburstLayout(root: root, rings: 2, minimumSpan: 0.01)

        let brins = try #require(layout.segments.first { $0.name == "Brins" })
        let others = layout.segments.filter { segment in
            if case .others = segment.kind { segment.path == brins.path } else { false }
        }
        #expect(others.count == 1)
        if case .others(let count) = others.first?.kind { #expect(count == 40) }
        #expect(others.first?.branch == nil)
        let small = layout.segments.first { if case .smallFiles = $0.kind { $0.depth == 1 } else { false } }
        #expect(small?.bytes == Int64(60 * 4_096))
        #expect(small?.branch == nil)
    }

    @Test("Le survol trouve le segment sous la souris, et rien au centre")
    func hitTesting() async throws {
        let garden = try Garden()
        let root = try await garden.plant()
        let layout = SunburstLayout(root: root, rings: 3)
        let center = CGPoint(x: 200, y: 200)

        // Midi, sens horaire : juste à droite de midi, c'est le début du plus gros.
        let polar = SunburstLayout.polar(CGPoint(x: 201, y: 130), center: center, holeRadius: 50, ringWidth: 40)
        #expect(polar?.ring == 1)
        #expect((polar?.turn ?? 1) < 0.01)
        #expect(SunburstLayout.polar(CGPoint(x: 290, y: 200), center: center, holeRadius: 50, ringWidth: 40).map { abs($0.turn - 0.25) < 1e-9 } == true)
        #expect(SunburstLayout.polar(CGPoint(x: 210, y: 200), center: center, holeRadius: 50, ringWidth: 40) == nil)

        let hit = layout.segment(at: CGPoint(x: 201, y: 130), center: center, holeRadius: 50, ringWidth: 40)
        #expect(hit?.name == "Grand")
        #expect(layout.segment(at: CGPoint(x: 200, y: 200), center: center, holeRadius: 50, ringWidth: 40) == nil)
        #expect(layout.segment(at: CGPoint(x: 200, y: 0), center: center, holeRadius: 50, ringWidth: 40) == nil)
    }
}
