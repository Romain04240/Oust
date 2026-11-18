import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import OustCore
import OustDuplicates
@testable import OustModel

@Suite("La disponibilité d'Images similaires")
@MainActor
struct SimilarImagesAvailabilityTests {
    @Test("Le veto bloque les deux commandes et le gain, tout en laissant la vignette lisible")
    func suspendedTrashKeepsPreview() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-similar-model-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let group = try fixtureGroup(in: home)
        let copy = try #require(group.images.last)
        let before = try Data(contentsOf: copy.url)
        let app = AppModel(home: home)
        let similar = app.similarImages

        #expect(group.potential > 0)
        #expect(similar.reclaimableBytes(in: group) == 0)
        let presentation = similar.item(for: copy, in: group)
        #expect(presentation.sizes.freeable == 0 && presentation.sizes.allocated > 0)
        #expect(!presentation.isSelectable)
        #expect(!similar.canToggle(copy, in: group))
        #expect(!similar.canKeepBest(in: group))
        similar.toggle(copy, in: group)
        similar.keepBest(in: group)
        #expect(app.cart.isEmpty)
        #expect(try Data(contentsOf: copy.url) == before)
        similar.addFolder(home)
        await similar.search()
        let shown = try #require(similar.groups.flatMap(\.images).first {
            $0.url.lastPathComponent == copy.url.lastPathComponent
        })
        #expect(await similar.thumbnail(for: shown.url, side: 16) != nil)

        var alreadySelected = group.cleanupItem(for: copy)
        alreadySelected.method = .brewCleanup(executable: "/fictif/brew")
        app.add([alreadySelected])
        #expect(similar.isInCart(copy) && similar.canToggle(copy, in: group))
        similar.toggle(copy, in: group)
        #expect(app.cart.isEmpty)
        try fm.moveItem(at: shown.url, to: home.appendingPathComponent("ancienne.png"))
        try before.write(to: shown.url)
        #expect(await similar.thumbnail(for: shown.url, side: 16) == nil)
    }

    @Test("Le libellé du veto se distingue de la protection du dernier exemplaire")
    func selectionRestrictionLabel() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-similar-label-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let group = try fixtureGroup(in: home)
        let last = try #require(group.images.last)
        let checked = Set(group.images.dropLast().map(\.url.path))
        let app = AppModel(home: home)

        for image in group.images.dropFirst() {
            let restriction = app.similarImages.selectionRestriction(for: image, in: group, paths: [])
            #expect(restriction?.localizationKey == "similar.trash_unavailable")
        }
        #expect(app.similarImages.selectionRestriction(for: last, in: group, paths: checked) == .trashUnavailable)
        let lastKept = SimilarImagesModel.selectionRestriction(for: last, in: group, checked: checked, canAdd: true)
        #expect(lastKept?.localizationKey == "similar.last_kept")
        #expect(SimilarImagesModel.selectionRestriction(for: last, in: group, checked: [], canAdd: true) == nil)
    }

    private func fixtureGroup(in home: URL) throws -> SimilarImageGroup {
        let side = 400
        var noise: UInt32 = 42
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            noise = noise &* 1_664_525 &+ 1_013_904_223
            bytes[offset] = UInt8(truncatingIfNeeded: noise >> 24)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: noise >> 16)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: noise >> 8)
        }
        let pixels = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let drawing = try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                           bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                           provider: pixels, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let images = try ["a.png", "b.png", "c.png"].map { name in
            let url = home.appendingPathComponent(name)
            let png = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(png, drawing, nil)
            try #require(CGImageDestinationFinalize(png))
            return SimilarImage(url: url, logicalSize: Int64(try Data(contentsOf: url).count),
                                allocated: 4096, privateSize: 4096, modified: nil, captured: nil,
                                pixelWidth: drawing.width, pixelHeight: drawing.height)
        }
        return SimilarImageGroup(images: images)
    }
}
