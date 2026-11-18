import Foundation
import OustCore
import OustScan
import Testing
@testable import OustRules

@Suite("Caches de création sur le volume ouvert")
struct BoundCreativeRulesTests {
    @Test("Une racine redirigée ne change pas les bibliothèques ni leurs événements")
    func retainedVolume() async throws {
        let home = try FakeHome()
        try home.text("Volume/Montage/Film.fcpbundle/Tournage/Render Files/original.mov", "")
        try home.text("Volume/Backups.backupdb/Copie.fcpbundle/Événement/Render Files/copie.mov", "")
        try home.text("Autre/Montage/Leurre.fcpbundle/Événement/Render Files/leurre.mov", "")
        try home.text("Événement externe/Render Files/externe.mov", "")
        let fs = FileManager.default
        let volume = home.root.appendingPathComponent("Volume", isDirectory: true)
        let linkedEvent = volume.appendingPathComponent("Montage/Film.fcpbundle/Événement redirigé")
        try fs.createSymbolicLink(at: linkedEvent, withDestinationURL: home.root.appendingPathComponent("Événement externe"))
        let context = try boundContext(home, volume: volume)
        try fs.moveItem(at: volume, to: home.root.appendingPathComponent("Volume initial"))
        try fs.createSymbolicLink(at: volume, withDestinationURL: home.root.appendingPathComponent("Autre"))

        let items = await CreativeAppsFinder(context: context).find().map(\.item)

        #expect(items.map(\.title) == ["Film"])
        #expect(items.flatMap(\.paths).map { $0.deletingLastPathComponent().lastPathComponent } == ["Tournage"])
    }

    @Test("Lightroom et Capture One exigent leurs marqueurs dans le volume ouvert")
    func catalogEvidence() async throws {
        let home = try FakeHome()
        try home.text("Volume/Photos/Studio.lrcat", "")
        try home.text("Volume/Photos/Studio Previews.lrdata/normal", "")
        try home.text("Volume/Photos/Studio Smart.lrcat", "")
        try home.text("Volume/Photos/Studio Smart Previews.lrdata/a-garder", "")
        try home.text("Volume/Photos/Redirigé Previews.lrdata/normal", "")
        try home.text("Externe.lrcat", "")
        try home.text("Volume/Session/CaptureOne/Settings153/image.cos", "")
        try home.text("Volume/Session/CaptureOne/Cache/vignette", "")
        try home.text("Volume/Leurre/CaptureOne/Cache/vignette", "")
        let fs = FileManager.default
        let volume = home.root.appendingPathComponent("Volume", isDirectory: true)
        try fs.createSymbolicLink(at: volume.appendingPathComponent("Photos/Studio.lrcat.lock"),
                                  withDestinationURL: home.root.appendingPathComponent("Verrou disparu"))
        try fs.createSymbolicLink(at: volume.appendingPathComponent("Photos/Redirigé.lrcat"),
                                  withDestinationURL: home.root.appendingPathComponent("Externe.lrcat"))
        try fs.createSymbolicLink(at: volume.appendingPathComponent("Leurre/CaptureOne/Settings153"),
                                  withDestinationURL: volume.appendingPathComponent("Session/CaptureOne/Settings153"))
        let context = try boundContext(home, volume: volume)

        let items = await ProAppsFinder(context: context).find().map(\.item)

        #expect(Set(items.map(\.title)) == ["Studio", "Session"])
        let lightroom = try #require(items.first { $0.title == "Studio" })
        #expect(lightroom.protections.contains(.unknownState))
        #expect(!lightroom.isSelectable)
    }

    @Test("L’index ne valide pas un nouveau CacheClip ni une base Adobe redirigée")
    func staleDirectoryHint() async throws {
        let home = try FakeHome()
        try home.text("Volume/Resolve/CacheClip/rendu", "")
        try home.text("Volume/Resolve/ProxyMedia/proxy", "")
        try home.text("Volume/Adobe/Media Cache Files/audio", "")
        try home.text("Base Adobe externe/base", "")
        let fs = FileManager.default
        let volume = home.root.appendingPathComponent("Volume", isDirectory: true)
        try fs.createSymbolicLink(at: volume.appendingPathComponent("Adobe/Media Cache"),
                                  withDestinationURL: home.root.appendingPathComponent("Base Adobe externe"))
        var context = try boundContext(home, volume: volume)
        let anchor = try #require(context.volumeAnchor)
        let snapshot = await ScanIndex.refreshBound(nil, root: anchor, options: ScanOptions(), progress: ScanProgress())
        context.tree = { snapshot.index.root }
        try fs.moveItem(at: volume.appendingPathComponent("Resolve/CacheClip"),
                        to: home.root.appendingPathComponent("CacheClip initial"))
        try home.text("Volume/Resolve/CacheClip/remplacement", "")

        let items = await CreativeAppsFinder(context: context).find().map(\.item)

        #expect(items.map(\.ruleID) == ["creative.adobe.media_cache"])
        #expect(items.flatMap(\.paths).map(\.lastPathComponent) == ["Media Cache Files"])
    }

    private func boundContext(_ home: FakeHome, volume: URL) throws -> RuleContext {
        var context = home.context()
        let anchor = try home.openVolume(volume)
        context.volume = VolumeScope(root: anchor.url, name: "Disque", fileSystem: "apfs")
        context.volume?.root = anchor.url
        context.volumeAnchor = anchor
        return context
    }
}
