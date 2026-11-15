import Foundation
import OustCore
import OustSafety
import OustScan
import OustUninstall
import OustVolume
import Testing
@testable import OustModel

@MainActor
struct PreferencePresentationTests {
    @Test("La sélection revérifie le disque de démarrage déjà visible et le domicile redirigé",
          arguments: [true, false])
    func selectAfterRedirect(isBoot: Bool) async throws {
        let fixture = try Fixture()
        let indexed = fixture.root.appendingPathComponent("Volume")
        let a = indexed.appendingPathComponent("A")
        let b = indexed.appendingPathComponent("B")
        let fm = FileManager.default
        for folder in [a, b] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 180_000).write(to: folder.appendingPathComponent("Fictif.plist"))
        }
        try fm.createSymbolicLink(at: fixture.preferences, withDestinationURL: a)
        let home = isBoot ? fixture.root : fixture.root.appendingPathComponent("Domicile")
        if !isBoot { try fm.createSymbolicLink(at: home, withDestinationURL: fixture.root) }
        let volume = VolumeDescriptor(name: "Fictif", mountURL: indexed, scanRoot: indexed, isBoot: isBoot,
                                      isInternal: isBoot, isRemovable: !isBoot,
                                      capacity: Capacity(total: 1_000_000, available: 500_000, availableForImportantUsage: 500_000))
        let options = isBoot ? DiskIndexModel.options(for: home) : AppModel.volumeScanOptions(for: volume, home: home)
        let (index, _) = await ScanIndex.refresh(nil, root: indexed, options: options)
        #expect(index.root.descendant(atPath: a.path)?.total.freeable == 0)
        let priorGain = try #require(index.root.descendant(atPath: b.path)?.total.freeable)
        #expect(priorGain > 0)
        let app = AppModel(home: home, defaults: MemoryDefaults())
        if isBoot {
            app.showSharedTree(index, volume: volume)
            try fm.removeItem(at: fixture.preferences)
            try fm.createSymbolicLink(at: fixture.preferences, withDestinationURL: b)
        } else {
            app.volumeIndexes[volume.id] = index
            let otherHome = fixture.root.appendingPathComponent("Autre")
            let otherPreferences = PreferenceDirectory.url(in: otherHome)
            try fm.createDirectory(at: otherPreferences.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: otherPreferences, withDestinationURL: b)
            try fm.removeItem(at: home)
            try fm.createSymbolicLink(at: home, withDestinationURL: otherHome)
        }
        #expect(!index.hasCurrentPreferenceDirectory)
        app.selectAnalysisVolume(volume)
        #expect(app.treeVolume?.id == volume.id)
        #expect(app.tree?.descendant(atPath: b.path)?.total.freeable == 0)
        #expect(app.tree?.total.allocated == index.root.total.allocated)
        #expect(index.root.descendant(atPath: b.path)?.total.freeable == priorGain)
    }

    @Test("Le bouton Restes et la réouverture d'Applications revérifient le veto", arguments: [true, false])
    func reopenOrphans(viaButton: Bool) throws {
        let fixture = try Fixture()
        let app = AppModel(home: fixture.root, defaults: MemoryDefaults())
        let sources = OrphanSources(appRoots: [], pluginRoots: [], helperRoots: [], labelRoots: [],
                                    registeredApps: { _ in [] }, signature: { _ in SigningFacts(teamID: nil, groups: []) },
                                    runningExecutables: { [] }, canReadContainers: true)
        var group = try #require(OrphanFinder.orphans(home: fixture.root, installed: [], sources: sources).first)
        group.leftovers[0].sizes = Sizes(private: Fixture.bytes)
        app.applications.updateOrphans([group])
        #expect(app.applications.orphanBytes == Fixture.bytes)
        #expect(!app.applications.showsOrphans)

        try fixture.redirect()
        if viaButton {
            app.applications.showOrphans()
            #expect(app.applications.showsOrphans)
        } else {
            app.applications.pruneMissing()
        }

        #expect(app.applications.orphanBytes == 0)
        #expect(app.applications.proposedOrphans.isEmpty)
        let protectedGroup = try #require(app.applications.protectedOrphans.first)
        let item = try #require(app.applications.items(of: protectedGroup).first)
        #expect(item.sizes.allocated == Fixture.bytes && !item.isSelectable)
        #expect(!PathGuard(home: fixture.root).allows(fixture.leftover))
    }

    enum NotificationChanges: CaseIterable {
        case onlyProtected, keepsControl, removesControl, replacesControl, removesAll
    }

    @Test("La notification vérifie la présence, l’inode et le veto après l'autorisation",
          arguments: NotificationChanges.allCases)
    func notificationAfterPermission(changes: NotificationChanges) async throws {
        let fixture = try Fixture()
        let model = TrashedAppsModel(defaults: MemoryDefaults())
        let app = InstalledApp(url: fixture.root.appendingPathComponent("Fictif.app"), name: "Fictif", bundleID: "org.fixture.app")
        let cache = fixture.root.appendingPathComponent("Library/Caches/org.fixture.app")
        let hasControl = changes == .keepsControl || changes == .removesControl || changes == .replacesControl
        if hasControl {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data("témoin".utf8).write(to: cache.appendingPathComponent("Fictif.txt"))
        }
        let leftovers = LeftoverFinder.leftovers(of: app, among: [], home: fixture.root).map { leftover in
            var leftover = leftover
            leftover.sizes = Sizes(private: Fixture.bytes)
            return leftover
        }
        #expect(leftovers.count == (hasControl ? 2 : 1))
        let measuredInode = leftovers.first { $0.url.path == cache.path }?.fileID
        let moved = fixture.root.appendingPathComponent("AncienCache")
        let previous = TrashedApp(app: app, trashedAt: Date(), originalName: "Fictif.app", leftovers: leftovers)
        model.publish(previous)
        #expect(previous.isWorthOffering)
        var sent: [Int64] = []
        await model.notify(previous, ensurePermission: {
            await Task.yield()
            do {
                if changes == .removesAll {
                    try FileManager.default.removeItem(at: fixture.leftover)
                } else {
                    try fixture.redirect()
                    if changes == .removesControl { try FileManager.default.removeItem(at: cache) }
                    if changes == .replacesControl {
                        try FileManager.default.moveItem(at: cache, to: moved)
                        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
                    }
                }
            } catch { Issue.record("Modification du dossier fictif impossible : \(error)") }
            return .allowed
        }, post: { sent.append($0.freeable) })
        if changes == .replacesControl {
            let original = try #require(measuredInode)
            let replacement = try #require(FileFacts.of(cache.path))
            #expect(original != 0 && FileFacts.of(moved.path)?.inode == original)
            #expect(replacement.inode != original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        }
        #expect(sent == (changes == .keepsControl ? [Fixture.bytes] : []))
        if changes == .removesAll {
            #expect(model.report(previous.id) == nil)
            #expect(model.chosen[previous.id] == nil)
            return
        }
        let updated = try #require(model.report(previous.id))
        #expect(updated.leftovers.count == (changes == .keepsControl ? 2 : 1))
        let protected = try #require(updated.items.first { $0.paths.first?.path == fixture.leftover.path })
        #expect(!protected.isSelectable && protected.sizes.freeable == 0)
    }

    private final class Fixture {
        static let bytes: Int64 = 4_000_000
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-pref-presentation-\(UUID())")
        var preferences: URL { PreferenceDirectory.url(in: root) }
        var leftover: URL { root.appendingPathComponent("Library/Application Support/org.fixture.app") }
        var target: URL { leftover.appendingPathComponent("Reglages") }

        init() throws {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("plist fictif".utf8).write(to: target.appendingPathComponent("Fictif.plist"))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func redirect() throws {
            try FileManager.default.createSymbolicLink(at: preferences, withDestinationURL: target)
        }
    }
}
