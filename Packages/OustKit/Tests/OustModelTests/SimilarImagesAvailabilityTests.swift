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
        #expect(await similar.thumbnail(for: copy.url, side: 16) != nil)

        var alreadySelected = group.cleanupItem(for: copy)
        alreadySelected.method = .brewCleanup(executable: "/fictif/brew")
        app.add([alreadySelected])
        #expect(similar.isInCart(copy) && similar.canToggle(copy, in: group))
        similar.toggle(copy, in: group)
        #expect(app.cart.isEmpty)
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
        let context = try #require(CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        let drawing = try #require(context.makeImage())
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
