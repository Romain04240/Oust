import AppKit
import Foundation
import SwiftUI
import Testing
import OustCore
import OustScan
import FeatureOverview
@testable import OustModel

@Suite("Cadre natif du parcours", .serialized) @MainActor
struct GuidedReviewLayoutTests {
    @Test("Le bandeau garde sa hauteur avec avertissement, dans les deux langues",
          arguments: ["fr", "en"])
    func bannerHeight(_ language: String) throws {
        let f = try LayoutFixture(); defer { f.remove() }
        f.model.startGuidedReviewFromSidebar()
        for _ in 0..<4 {
            let session = try #require(f.model.guidedReview)
            f.model.skipGuidedReview(token: session.token)
        }
        for width: CGFloat in [760, 840, 1160] {
            var heights: [CGFloat] = []
            for foreign in [false, true] {
                var volume = f.volume
                if foreign { volume.scanRoot = f.root.appendingPathComponent("other") }
                f.model.treeVolume = volume
                let view = NSHostingView(rootView: GuidedReviewBanner(model: f.model)
                    .environment(\.locale, Locale(identifier: language)).frame(width: width))
                heights.append(view.fittingSize.height)
            }
            #expect(heights[0] == heights[1] && heights[0] == 80)
        }
    }

    @Test("L’entrée permanente conserve son empreinte en pause et sans analyse",
          arguments: ["fr", "en"])
    func launcherHeight(_ language: String) throws {
        let f = try LayoutFixture(); defer { f.remove() }
        for width: CGFloat in [204, 224, 264] {
            for state in ["ready", "active", "paused", "required", "running", "external"] {
                if let session = f.model.guidedReview { f.model.endGuidedReview(token: session.token) }
                f.model.analysis = .idle
                f.model.analysisVolumeID = nil
                f.model.recordVolumeAnalysis(for: f.volume)
                switch state {
                case "active", "paused":
                    f.model.startGuidedReviewFromSidebar()
                    if state == "paused", let s = f.model.guidedReview { f.model.pauseGuidedReview(token: s.token) }
                case "required": f.model.volumeAnalysisDates.removeAll()
                case "running": f.model.analysis = .running
                case "external": f.model.analysisVolumeID = f.external.id
                default: break
                }
                let view = NSHostingView(rootView: GuidedReviewLauncher(model: f.model)
                    .environment(\.locale, Locale(identifier: language)).frame(width: width))
                #expect(view.fittingSize.height == 84)
                #expect(f.model.cart.isEmpty && !f.model.canMoveFiles)
            }
        }
    }
}

@MainActor private struct LayoutFixture {
    let root: URL
    let volume: VolumeDescriptor
    let external: VolumeDescriptor
    let model: AppModel
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-guide-layout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("fixture.bin"))
        var boot = VolumeDescriptor(name: "Fixture", mountURL: root, scanRoot: root,
            isBoot: true, isInternal: true, isRemovable: false,
            capacity: Capacity(total: 1000, available: 500, availableForImportantUsage: 500))
        boot.mountIdentity = VolumeMountIdentity(device: 7, inode: 101, createdSeconds: 1, createdNanoseconds: 0)
        volume = boot
        external = VolumeDescriptor(name: "External", mountURL: root.appendingPathComponent("external"),
            scanRoot: root.appendingPathComponent("external"), isBoot: false, isInternal: false,
            isRemovable: true, capacity: boot.capacity)
        model = AppModel(home: root, defaults: LayoutDefaults(), disk: DiskIndexModel(store: TreeStore(directory: root.appendingPathComponent("Index"))))
        model.volumes = [volume, external]
        model.recordVolumeAnalysis(for: volume)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class LayoutDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey key: String) -> Any? { nil }
    override func data(forKey key: String) -> Data? { nil }
    override func stringArray(forKey key: String) -> [String]? { nil }
    override func bool(forKey key: String) -> Bool { false }
    override func set(_ value: Any?, forKey key: String) {}
}
