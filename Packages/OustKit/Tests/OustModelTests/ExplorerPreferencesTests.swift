import Foundation
import OustClean
import OustCore
import OustRules
import OustSafety
import OustScan
import OustVolume
import Testing
@testable import OustModel

@MainActor
struct ExplorerPreferencesTests {
    @Test("Le remplacement d’un CSV préserve le mode du fichier", arguments: [0o600, 0o640])
    func csvReplacementPreservesPermissions(mode: Int) async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-csv-permissions-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let destination = home.appendingPathComponent("Fictif.csv")
        try "ancien".write(to: destination, atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)

        let (index, _) = await ScanIndex.refresh(nil, root: home, options: ScanOptions())
        let volume = VolumeDescriptor(name: "Fictif", mountURL: home, scanRoot: home, isBoot: false,
                                      isInternal: true, isRemovable: false,
                                      capacity: Capacity(total: 1_000_000, available: 500_000,
                                                         availableForImportantUsage: 500_000))
        let app = AppModel(home: home, defaults: MemoryDefaults())
        app.showExplorerIndex(index, volume: volume)
        #expect(try app.exportExplorerCSV(to: destination, for: index.root, render: { "nouveau" }))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "nouveau")
        let actual = try fm.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        #expect(actual?.intValue == mode)
    }

    enum CSVACLFixture: String, Sendable {
        case explicit, inherited, absent
    }

    @Test("Le CSV publié conserve l’ACL complète, y compris les entrées héritées",
          arguments: [CSVACLFixture.explicit, .inherited, .absent])
    func csvReplacementPreservesCompleteACL(fixture: CSVACLFixture) async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-csv-acl-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        if fixture == .inherited {
            try addACL("everyone deny execute,file_inherit,only_inherit", at: home)
        }
        let destination = home.appendingPathComponent("Fictif.csv")
        try "ancien".write(to: destination, atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        if fixture != .absent {
            try addACL("everyone deny writeextattr", at: destination)
        }
        let originalACL = try #require(FileFacts.accessControlList(destination.path))
        if fixture == .absent {
            #expect(originalACL.isEmpty)
        } else {
            #expect(originalACL.contains("writeextattr"))
            if fixture == .inherited { #expect(originalACL.contains("inherited:execute")) }
        }

        let (index, _) = await ScanIndex.refresh(nil, root: home, options: ScanOptions())
        let volume = VolumeDescriptor(name: "Fictif", mountURL: home, scanRoot: home, isBoot: false,
                                      isInternal: true, isRemovable: false,
                                      capacity: Capacity(total: 1_000_000, available: 500_000,
                                                         availableForImportantUsage: 500_000))
        let app = AppModel(home: home, defaults: MemoryDefaults())
        app.showExplorerIndex(index, volume: volume)
        let published = try app.exportExplorerCSV(to: destination, for: index.root, render: { "nouveau" }, stage: { text, temporary in
            try text.write(to: temporary, atomically: false, encoding: .utf8)
            if fixture == .absent {
                try addACL("everyone deny execute", at: temporary)
                #expect(FileFacts.accessControlList(temporary.path)?.contains("execute") == true)
            }
        })
        #expect(published)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "nouveau")
        #expect(FileFacts.accessControlList(destination.path) == originalACL)
        let mode = try fm.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    private func addACL(_ entry: String, at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", entry, url.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    @Test("Une redirection avant la publication du CSV préserve le fichier existant",
          arguments: [false, true])
    func csvRejectsGainAfterRedirection(afterStaging: Bool) async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-archive-csv-\(UUID())")
        let root = home.appendingPathComponent("Fichiers")
        let target = root.appendingPathComponent("Ordinaire")
        let archives = home.appendingPathComponent("Users/Deleted Users")
        try fm.createDirectory(at: archives.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Self.invalidPlist.write(to: target.appendingPathComponent("Compte.dmg"))
        let (index, _) = await ScanIndex.refresh(nil, root: root, options: ScanOptions(
            leafThreshold: 1, accountArchivesDirectory: archives.path))
        let volume = VolumeDescriptor(name: "Fictif", mountURL: root, scanRoot: root, isBoot: false,
                                      isInternal: true, isRemovable: false,
                                      capacity: Capacity(total: 1_000_000, available: 500_000,
                                                         availableForImportantUsage: 500_000))
        let app = AppModel(home: home, defaults: MemoryDefaults())
        app.showExplorerIndex(index, volume: volume)
        let destination = home.appendingPathComponent("Fictif.csv")
        let csv = TreeAnalytics.compute(index.root).csv(for: index.root)
        #expect(index.root.total.freeable > 0)
        #expect(try app.exportExplorerCSV(to: destination, for: index.root, render: { csv }))
        #expect(try String(contentsOf: destination, encoding: .utf8) == csv)

        let old = "Vérification d’un CSV préexistant"
        try old.write(to: destination, atomically: false, encoding: .utf8)
        var staged: URL?
        let changed = try app.exportExplorerCSV(to: destination, for: index.root, render: {
            if !afterStaging {
                do { try fm.createSymbolicLink(at: archives, withDestinationURL: target) }
                catch { Issue.record("Redirection fictive impossible : \(error)") }
            }
            return csv
        }, stage: { contents, url in
            try contents.write(to: url, atomically: false, encoding: .utf8)
            staged = url
            #expect(try String(contentsOf: url, encoding: .utf8) == csv)
            #expect(try String(contentsOf: destination, encoding: .utf8) == old)
            if afterStaging { try fm.createSymbolicLink(at: archives, withDestinationURL: target) }
        })
        #expect(!changed)
        #expect(try String(contentsOf: destination, encoding: .utf8) == old)
        let temporary = try #require(staged)
        #expect(!fm.fileExists(atPath: temporary.deletingLastPathComponent().path))

        let safe = try #require(app.tree)
        #expect(safe.total.allocated == index.root.total.allocated && safe.total.freeable == 0)
        let safeCSV = TreeAnalytics.compute(safe).csv(for: safe)
        #expect(safeCSV != csv)
        #expect(try app.exportExplorerCSV(to: destination, for: safe, render: { safeCSV }))
        #expect(try String(contentsOf: destination, encoding: .utf8) == safeCSV)
    }

    @Test("Le panneau cloud ignore les gains déjà publiés après redirection des archives")
    func cloudPanelRejectsPreviousEstimate() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-archive-panel-\(UUID())")
        let provider = home.appendingPathComponent("Library/CloudStorage/Fictif")
        let target = provider.appendingPathComponent("Archives")
        let archives = home.appendingPathComponent("Users/Deleted Users")
        try fm.createDirectory(at: archives.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("Compte.dmg")
        try Self.invalidPlist.write(to: file)

        let app = AppModel(home: home, defaults: MemoryDefaults())
        let old = CleanupItem(title: "Fictif", paths: [file], category: .cloudFiles, owner: "Fictif",
                              ruleID: "cloud.file_provider", safety: .safe, method: .evictLocalCopy,
                              sizes: Sizes(private: 200_000), rebuild: .download)
        app.items[old.id] = old
        try fm.createSymbolicLink(at: archives, withDestinationURL: target)
        let footprint = try #require(app.cloudFootprints.first)
        #expect(footprint.provider.name == "Fictif" && footprint.evictable == 0)
        #expect(!app.canSelectForCleanup(old))
    }

    @Test("Un Explorateur déjà ouvert retire le gain si le dossier des archives est redirigé",
          arguments: [true, false])
    func displayedExplorerAfterAccountArchivesRedirect(isBoot: Bool) async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-archive-explorer-\(UUID())")
        let root = home.appendingPathComponent("Fichiers")
        let target = root.appendingPathComponent("Ordinaire")
        let archives = home.appendingPathComponent("Users/Deleted Users")
        try fm.createDirectory(at: archives, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Self.invalidPlist.write(to: target.appendingPathComponent("Compte.dmg"))
        let (index, _) = await ScanIndex.refresh(nil, root: root, options: ScanOptions(
            leafThreshold: 1, accountArchivesDirectory: archives.path))
        let original = try #require(index.root.descendant(atPath: target.path))
        #expect(original.total.freeable > 0)

        let app = AppModel(home: home, defaults: MemoryDefaults())
        let volume = VolumeDescriptor(name: "Fictif", mountURL: root, scanRoot: root, isBoot: isBoot,
                                      isInternal: isBoot, isRemovable: !isBoot,
                                      capacity: Capacity(total: 1_000_000, available: 500_000,
                                                         availableForImportantUsage: 500_000))
        app.showExplorerIndex(index, volume: volume)
        #expect(app.revalidateExplorerGains() && app.tree === index.root)
        try fm.removeItem(at: archives)
        try fm.createSymbolicLink(at: archives, withDestinationURL: target)

        #expect(!app.revalidateExplorerGains())
        let displayed = try #require(app.tree?.descendant(atPath: target.path))
        #expect(displayed.total.allocated == original.total.allocated)
        #expect(displayed.total.freeable == 0 && displayed.files.first?.sizes.freeable == 0)
        #expect(app.tree?.total.freeable == 0)
        #expect(original.total.freeable > 0)
        #expect(app.revalidateExplorerGains() && app.treeVolume?.id == volume.id)
    }

    @Test("Sélectionner un volume ne republie pas le gain de l'ancienne cible", arguments: [true, false])
    func selectingVolumeAfterPreferencesRedirect(wasSelected: Bool) async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-pref-volume-\(UUID())")
        let indexed = home.appendingPathComponent("VolumeFictif")
        let first = indexed.appendingPathComponent("A")
        let second = indexed.appendingPathComponent("B")
        let preferences = PreferenceDirectory.url(in: home)
        for folder in [first, second, preferences.deletingLastPathComponent()] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: home) }
        for folder in [first, second] {
            try Self.invalidPlist.write(to: folder.appendingPathComponent("Fictif.plist"))
        }
        try fm.createSymbolicLink(at: preferences, withDestinationURL: first)
        let volume = VolumeDescriptor(name: "Fictif", mountURL: indexed, scanRoot: indexed, isBoot: false, isInternal: false,
                                      isRemovable: true, capacity: Capacity(total: 1_000_000, available: 500_000,
                                                                            availableForImportantUsage: 500_000))
        let options = AppModel.volumeScanOptions(for: volume, home: home)
        let (old, _) = await ScanIndex.refresh(nil, root: indexed, options: options)
        #expect(old.root.descendant(atPath: first.path)?.total.freeable == 0)
        let priorGain = try #require(old.root.descendant(atPath: second.path)?.total.freeable)
        #expect(priorGain > 0)
        let app = AppModel(home: home, defaults: MemoryDefaults())
        app.volumeIndexes[volume.id] = old
        if wasSelected {
            app.selectAnalysisVolume(volume)
            #expect(app.tree?.descendant(atPath: second.path)?.total.freeable == priorGain)
        }

        try fm.removeItem(at: preferences)
        try fm.createSymbolicLink(at: preferences, withDestinationURL: second)
        #expect(!old.hasCurrentProtectionRoots)
        app.selectAnalysisVolume(volume)
        #expect(app.treeVolume?.id == volume.id)
        #expect(app.tree?.descendant(atPath: second.path)?.total.freeable == 0)
        #expect(app.tree?.total.allocated == old.root.total.allocated)
        #expect(old.root.descendant(atPath: second.path)?.total.freeable == priorGain)
    }

    @Test("L'index Explorateur compte les plist personnels en espace occupé, à toute taille")
    func preferencesDoNotAdvertiseGain() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-explorer-prefs-\(UUID())")
        let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let large = preferences.appendingPathComponent("org.fixture.large.plist")
        let small = preferences.appendingPathComponent("org.fixture.small.plist")
        let ordinary = home.appendingPathComponent("Ordinaire.plist")
        try Self.invalidPlist.write(to: large)
        try Data("plist fictif".utf8).write(to: small)
        try Data(repeating: 0x43, count: 180_000).write(to: ordinary)
        let options = DiskIndexModel.options(for: home)
        let (index, _) = await ScanIndex.refresh(nil, root: home, options: options)
        let folder = try #require(index.root.descendant(atPath: preferences.path))
        #expect(folder.files.first?.name == large.lastPathComponent)
        #expect(folder.files.first?.sizes.freeable == 0)
        #expect(folder.smallFiles.allocated > 0 && folder.smallFiles.freeable == 0)
        #expect(folder.total.allocated > 0 && folder.total.freeable == 0)
        #expect(index.root.total.freeable == index.root.files.first?.sizes.allocated)

        let app = AppModel(home: home, defaults: MemoryDefaults())
        let leaf = try #require(folder.files.first)
        let batch = try await preferenceBatch(home: home)
        let diagnostic = try #require(batch.items.first)
        app.recordAnalyzedBatch(batch, preselect: true, policy: PreselectionPolicy())
        #expect(app.item(for: leaf, in: folder) == diagnostic)
        #expect(app.cart.isEmpty && !app.canSelectForCleanup(diagnostic))

        let store = TreeStore(directory: home.appendingPathComponent("IndexFictif"))
        try store.save(index)
        let reopened = try #require(store.load(rootPath: index.rootPath))
        #expect(reopened.options == options)
        #expect(reopened.root.descendant(atPath: preferences.path)?.total == folder.total)

        app.explore(folder: preferences)
        await app.scanTask?.value
        #expect(app.tree?.total == folder.total)

        let alias = home.appendingPathComponent("AliasLibrary")
        try fm.createSymbolicLink(at: alias, withDestinationURL: preferences.deletingLastPathComponent())
        app.explore(folder: alias.appendingPathComponent("Preferences"))
        await app.scanTask?.value
        #expect(app.tree?.total == folder.total)

        var unprotected = options
        unprotected.readOnlyPreferencesDirectory = nil
        let (old, _) = await ScanIndex.refresh(nil, root: home, options: unprotected)
        #expect((old.root.descendant(atPath: preferences.path)?.total.freeable ?? 0) > 0)
        let (fresh, how) = await ScanIndex.refresh(old, root: home, options: options)
        #expect(how == .full(.optionsChanged))
        #expect(fresh.root.descendant(atPath: preferences.path)?.total == folder.total)
    }

    @Test("La fiche périmée est écartée à la réception et à l’affichage", arguments: [true, false])
    func replacedPlist(atomic: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-pref-replace-\(UUID())")
        let preferences = PreferenceDirectory.url(in: home)
        let fm = FileManager.default
        try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let file = preferences.appendingPathComponent("org.fixture.large.plist")
        try Self.invalidPlist.write(to: file)
        let batch = try await preferenceBatch(home: home)
        let diagnostic = try #require(batch.items.first)
        let app = AppModel(home: home, defaults: MemoryDefaults())
        if !atomic {
            app.recordAnalyzedBatch(batch, preselect: false, policy: PreselectionPolicy())
            #expect(app.items[diagnostic.id] != nil)
        }

        let valid = try PropertyListSerialization.data(
            fromPropertyList: ["flag": String(repeating: "x", count: 180_000)], format: .xml, options: 0)
        try valid.write(to: file, options: atomic ? .atomic : [])
        #expect(batch.items.isEmpty)
        if atomic {
            app.recordAnalyzedBatch(batch, preselect: false, policy: PreselectionPolicy())
            #expect(app.items[diagnostic.id] == nil)
        }
        #expect(app.items(in: [.preferenceDiagnostics]).isEmpty)
        app.explore(folder: preferences)
        await app.scanTask?.value
        let node = try #require(app.tree)
        let leaf = try #require(node.files.first)
        if !atomic { #expect(leaf.fileID == diagnostic.fingerprint?.fileID) }
        #expect(!app.item(for: leaf, in: node).isInvalidPreference)
    }

    @Test("Une fiche générique ne déplace pas un plist protégé, même via un parent symbolique")
    func genericTrashUsesPathVeto() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-pref-trash-\(UUID())")
        let fm = FileManager.default
        let preferences = PreferenceDirectory.url(in: home)
        try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let alias = home.appendingPathComponent("AliasLibrary")
        try fm.createSymbolicLink(at: alias, withDestinationURL: preferences.deletingLastPathComponent())
        let file = preferences.appendingPathComponent("org.fixture.large.plist")
        let redirected = alias.appendingPathComponent("Preferences/\(file.lastPathComponent)")
        let ordinary = home.appendingPathComponent("Ordinaire.plist")
        try Self.invalidPlist.write(to: file)
        try Self.invalidPlist.write(to: ordinary)
        let trash = home.appendingPathComponent("CorbeilleFictive")
        let guardPaths = PathGuard(home: home)
        let engine = CleanupEngine(trasher: FolderTrasher(folder: trash), history: nil, pathGuard: guardPaths,
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil })
        #expect(!guardPaths.allows(file) && !guardPaths.allows(redirected) && guardPaths.allows(ordinary))
        let items = [file, redirected, ordinary].map { url in
            CleanupItem(title: url.lastPathComponent, paths: [url], category: .explorer, owner: "",
                        ruleID: "explorer.item", safety: .review, method: .trash, rebuild: .irreversible)
        }
        for await _ in engine.run(items) {}
        #expect(try Data(contentsOf: file) == Self.invalidPlist)
        #expect(!fm.fileExists(atPath: ordinary.path))
        #expect(try fm.contentsOfDirectory(atPath: trash.path).count == 1)
    }

    private static let invalidPlist = Data(("""
        <?xml version="1.0"?><plist version="1.0"><dict><key>value</key>
        """ + String(repeating: " ", count: 180_000)).utf8)

    private func preferenceBatch(home: URL) async throws -> RuleBatch {
        let bundle = home.appendingPathComponent("_Applications/org.fixture.large.app", isDirectory: true)
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metadata = ["CFBundleIdentifier": "org.fixture.large", "CFBundlePackageType": "APPL", "CFBundleName": "Fictif"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: info)
        var context = RuleContext(home: home, runningApps: [])
        context.applicationURL = { _ in bundle }
        var iterator = RuleEngine.run(context, finders: [.preferenceDiagnostics]).makeAsyncIterator()
        return try #require(await iterator.next())
    }
}
