import Foundation
import OustClean
import OustCore
import OustRules
import OustSafety
@testable import OustScan
import OustVolume
import Testing
@testable import OustModel

@MainActor
struct ExplorerPreferencesTests {
    private func waitForLargeFiles(_ app: AppModel) async throws {
        for _ in 0..<100 {
            if !app.largeFiles.computing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Le calcul des gros fichiers ne s’est pas terminé")
    }

    @Test("Un accès bloqué expire sans faire attendre le fil principal")
    func storageCheckTimeout() async {
        let permit = DispatchSemaphore(value: 0)
        defer { permit.signal() }
        let clock = ContinuousClock()
        let started = clock.now
        let read = await checkStorageIO {
            #expect(!Thread.isMainThread)
            permit.wait()
            return true
        }
        #expect(read == nil)
        #expect(clock.now - started < .seconds(3))
    }

    @Test("Les gros fichiers abandonnent une ancienne mesure même si l’Explorateur a déjà changé l’arbre")
    func anotherViewInvalidatesDeviceBackupGains() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-device-adoption-\(UUID())")
        let target = home.appendingPathComponent("Stockage/Copie")
        let root = DeviceBackupPath.root(in: home)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 11_000_000).write(to: target.appendingPathComponent("fichier.bin"))
        let index = await ScanIndex.refresh(nil, root: home, options: ScanOptions(
            leafThreshold: 1, deviceBackupsDirectory: root.path)).index
        let capacity = Capacity(total: 10, available: 5, availableForImportantUsage: 5)
        let app = AppModel(home: home, defaults: MemoryDefaults())
        app.showExplorerIndex(index, volume: VolumeDescriptor(name: "Fictif", mountURL: home, scanRoot: home,
                              isBoot: false, isInternal: true, isRemovable: false, capacity: capacity))
        app.largeFiles.size = .tenMegabytes
        app.largeFiles.age = .any
        try await waitForLargeFiles(app)
        #expect((app.largeFiles.result?.matchBytes ?? 0) > 0)
        let phase = app.explorer
        try fm.createSymbolicLink(at: root.appendingPathComponent("Appareil"), withDestinationURL: target)
        let stable = await app.revalidateExplorerGains()
        #expect(!stable && app.explorer == phase)
        #expect(app.largeFiles.result == nil)
        await app.largeFiles.revalidateGains()
        #expect((app.largeFiles.result?.matchBytes ?? 0) == 0)
        try await waitForLargeFiles(app)
        #expect(app.largeFiles.result?.matchBytes == 0)
    }

    @Test("La réouverture ne republie pas les gains du disque de démarrage", arguments: [false, true])
    func bootCacheDoesNotRestoreOldGains(onExternalVolume: Bool) async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-boot-reopen-\(UUID())")
        let root = home.appendingPathComponent("Disque")
        let target = root.appendingPathComponent("Copie")
        let backups = DeviceBackupPath.root(in: home)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 11_000_000).write(to: target.appendingPathComponent("Fictif.bin"))
        let options = DiskIndexModel.options(for: home)
        let index = await ScanIndex.refresh(nil, root: root, options: options).index
        let store = TreeStore(directory: home.appendingPathComponent("Cache"))
        try store.save(index)
        let app = AppModel(home: home, defaults: MemoryDefaults(), disk: DiskIndexModel(store: store))
        let boot = VolumeDescriptor(name: "Fictif", mountURL: root, scanRoot: root, isBoot: true,
                                   isInternal: true, isRemovable: false,
                                   capacity: Capacity(total: 1_000_000, available: 500_000, availableForImportantUsage: 500_000))
        app.volumes = [boot]
        await app.disk.start()
        #expect((app.tree?.total.freeable ?? 0) > 0)
        if onExternalVolume {
            let otherRoot = home.appendingPathComponent("AutreVolume")
            try fm.createDirectory(at: otherRoot, withIntermediateDirectories: true)
            let otherIndex = await ScanIndex.refresh(nil, root: otherRoot, options: ScanOptions()).index
            let external = VolumeDescriptor(name: "Autre", mountURL: otherRoot, scanRoot: otherRoot, isBoot: false,
                                           isInternal: false, isRemovable: true, capacity: boot.capacity)
            _ = await app.disk.refresh().value
            app.showExplorerIndex(otherIndex, volume: external)
            app.volumes = [boot, external]
        }
        try fm.createSymbolicLink(at: backups.appendingPathComponent("Appareil"), withDestinationURL: target)
        if !onExternalVolume {
            _ = await app.revalidateExplorerGains()
            #expect(app.tree?.total.freeable == 0)
        }
        app.explore(boot)
        #expect((app.tree?.total.freeable ?? 0) == 0)
        _ = await app.disk.refresh().value
        #expect(app.tree?.total.freeable == 0)
    }

    @Test("Un chargement de cache planifié avant Annuler ne peut pas rouvrir l’Explorateur")
    func cancelledStartupCacheCannotPublish() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-cancel-startup-\(UUID())")
        let root = home.appendingPathComponent("DisqueFictif")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try Data(repeating: 44, count: 700_000).write(to: root.appendingPathComponent("fictif.bin"))
        let store = TreeStore(directory: home.appendingPathComponent("Index"))
        let initial = await ScanIndex.refresh(nil, root: root, options: DiskIndexModel.options(for: home)).index
        try store.save(initial)
        let app = AppModel(home: home, defaults: MemoryDefaults(), disk: DiskIndexModel(store: store))
        let capacity = Capacity(total: 100_000_000, available: 50_000_000, availableForImportantUsage: 50_000_000)
        let boot = VolumeDescriptor(name: "Fictif", mountURL: root, scanRoot: root, isBoot: true,
                                    isInternal: true, isRemovable: false, capacity: capacity)
        app.volumes = [boot]
        let launch = app.disk.scheduleStartupCache()
        app.explore(boot)
        let scan = app.disk.refresh()
        app.cancelExploration()
        _ = await scan.value
        await launch.value
        #expect(app.explorer == .idle && app.tree == nil && !app.disk.isRefreshing)
    }

    @Test("Relancer aussitôt après Annuler lance une nouvelle analyse du disque")
    func immediateRetryAfterCancellingBootScan() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-retry-boot-\(UUID())")
        let root = home.appendingPathComponent("DisqueFictif")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try Data(repeating: 44, count: 700_000).write(to: root.appendingPathComponent("fictif.bin"))
        let store = TreeStore(directory: home.appendingPathComponent("Index"))
        let app = AppModel(home: home, defaults: MemoryDefaults(), disk: DiskIndexModel(store: store))
        let capacity = Capacity(total: 100_000_000, available: 50_000_000, availableForImportantUsage: 50_000_000)
        let boot = VolumeDescriptor(name: "Fictif", mountURL: root, scanRoot: root, isBoot: true,
                                    isInternal: true, isRemovable: false, capacity: capacity)
        app.volumes = [boot]
        app.explore(boot)
        app.cancelExploration()
        #expect(app.explorer == .idle)
        app.explore(boot)
        let result = await app.disk.refresh().value
        #expect(result != nil && app.tree?.path == root.path)
        #expect(!app.explorer.isRunning && !app.disk.isRefreshing)
    }

    @Test("Annuler le retour au disque de démarrage interdit une publication tardive du cache")
    func cancelledBootCacheDoesNotPublish() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-cancel-cache-\(UUID())")
        let root = home.appendingPathComponent("Demarrage")
        let external = home.appendingPathComponent("Externe")
        for folder in [root, external] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: home) }
        try Data(repeating: 44, count: 700_000).write(to: root.appendingPathComponent("test.bin"))
        let initial = await ScanIndex.refresh(nil, root: root, options: DiskIndexModel.options(for: home)).index
        let other = await ScanIndex.refresh(nil, root: external, options: ScanOptions()).index
        let store = TreeStore(directory: home.appendingPathComponent("Index"))
        try store.save(initial)
        let app = AppModel(home: home, defaults: MemoryDefaults(), disk: DiskIndexModel(store: store))
        let capacity = Capacity(total: 100_000_000, available: 50_000_000, availableForImportantUsage: 50_000_000)
        let boot = VolumeDescriptor(name: "Fictif", mountURL: root, scanRoot: root, isBoot: true,
                                    isInternal: true, isRemovable: false, capacity: capacity)
        let removable = VolumeDescriptor(name: "Externe", mountURL: external, scanRoot: external, isBoot: false,
                                         isInternal: false, isRemovable: true, capacity: capacity)
        app.volumes = [boot]
        await app.disk.start()
        _ = await app.disk.refresh().value
        app.showExplorerIndex(other, volume: removable)
        app.volumes = [boot, removable]
        app.explore(boot)
        let refresh = app.disk.refresh()
        #expect(app.explorer.isRunning)
        app.cancelExploration()
        _ = await refresh.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(app.explorer == .idle && app.tree == nil)
    }

    @Test("Un CSV MobileSync conserve le dossier choisi et publie seulement les octets occupés")
    func csvWithholdsMobileSyncGains() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-backup-csv-\(UUID())")
        let target = home.appendingPathComponent("Copie")
        let backups = DeviceBackupPath.root(in: home)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data(repeating: 8, count: 180_000).write(to: target.appendingPathComponent("Fictif.bin"))
        let index = await ScanIndex.refresh(nil, root: home, options: ScanOptions(
            leafThreshold: 1, deviceBackupsDirectory: backups.path)).index
        let folder = try #require(index.root.descendant(atPath: target.path))
        #expect(folder.total.freeable > 0)
        let app = AppModel(home: home, defaults: MemoryDefaults())
        let boot = VolumeDescriptor(name: "Fictif", mountURL: home, scanRoot: home, isBoot: false,
                                   isInternal: true, isRemovable: false,
                                   capacity: Capacity(total: 1_000_000, available: 500_000, availableForImportantUsage: 500_000))
        app.showExplorerIndex(index, volume: boot)
        let destination = home.appendingPathComponent("Fictif.csv")
        let analytics = TreeAnalytics.compute(index.root)
        let render: (Bool) -> String = { analytics.csv(for: folder, includeGains: $0) }
        #expect(try await app.exportExplorerCSV(to: destination, for: index.root, render: render))
        let occupiedOnly = analytics.csv(for: folder, includeGains: false)
        #expect(occupiedOnly != analytics.csv(for: folder))
        #expect(try String(contentsOf: destination, encoding: .utf8) == occupiedOnly)
        let refreshed = try await app.exportExplorerCSV(to: destination, for: index.root, render: render,
                                                        beforeDestinationCheck: {
            do { try fm.createSymbolicLink(at: backups.appendingPathComponent("Appareil"), withDestinationURL: target) }
            catch { Issue.record("Impossible de rediriger la copie fictive") }
        })
        #expect(!refreshed)
        #expect(try String(contentsOf: destination, encoding: .utf8) == occupiedOnly)
        #expect(app.tree?.total.freeable == 0)
    }

    @Test("Le CSV préserve une destination remplacée pendant les derniers contrôles")
    func csvRejectsChangedDestination() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-csv-replaced-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let destination = home.appendingPathComponent("Fictif.csv")
        try "ancien".write(to: destination, atomically: false, encoding: .utf8)
        let index = await ScanIndex.refresh(nil, root: home, options: ScanOptions()).index
        let capacity = Capacity(total: 10, available: 5, availableForImportantUsage: 5)
        let app = AppModel(home: home, defaults: MemoryDefaults())
        app.showExplorerIndex(index, volume: VolumeDescriptor(name: "Fictif", mountURL: home, scanRoot: home,
                              isBoot: false, isInternal: true, isRemovable: false, capacity: capacity))
        let published = try await app.exportExplorerCSV(to: destination, for: index.root, render: { _ in "export" },
                                                        beforeDestinationCheck: {
            do { try "concurrent".write(to: destination, atomically: true, encoding: .utf8) }
            catch { Issue.record("Impossible de remplacer le fichier fictif") }
        })
        #expect(!published)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "concurrent")
    }

    @Test("La redirection d’une copie retire les gains de Spotlight, des gros fichiers et du CSV en attente")
    func deviceBackupGainRevalidation() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-device-gains-\(UUID())")
        let target = home.appendingPathComponent("Stockage/Copie")
        let root = DeviceBackupPath.root(in: home)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = target.appendingPathComponent("fichier.bin")
        try Data(repeating: 7, count: 11_000_000).write(to: payload)
        let app = AppModel(home: home, defaults: MemoryDefaults())
        let preview = Spotlight.parse(Data((payload.path + "\0").utf8), minimumBytes: 1, deviceBackupsDirectory: root.path)
        let snapshot = DeviceBackupPath.Snapshot.capture(root.path)
        app.largeFiles.size = .tenMegabytes
        app.largeFiles.age = .any
        await app.disk.publishSpotlightFiles(preview, backupRoots: snapshot)
        app.largeFiles.refresh()
        try await waitForLargeFiles(app)
        #expect((app.largeFiles.result?.matchBytes ?? 0) > 0)

        let index = await ScanIndex.refresh(nil, root: home, options: ScanOptions(
            leafThreshold: 1, deviceBackupsDirectory: root.path)).index
        let volume = VolumeDescriptor(name: "Fictif", mountURL: home, scanRoot: home, isBoot: false,
                                      isInternal: true, isRemovable: false,
                                      capacity: Capacity(total: 1_000_000, available: 500_000,
                                                         availableForImportantUsage: 500_000))
        app.showExplorerIndex(index, volume: volume)
        let destination = home.appendingPathComponent("Fictif.csv")
        try "ancienne version".write(to: destination, atomically: false, encoding: .utf8)
        let exported = try await app.exportExplorerCSV(to: destination, for: index.root, render: { _ in "gain périmé" }, stage: { text, staging in
            try text.write(to: staging, atomically: false, encoding: .utf8)
            try fm.createSymbolicLink(at: root.appendingPathComponent("Appareil"), withDestinationURL: target)
        })
        #expect(!exported)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "ancienne version")
        await app.largeFiles.revalidateGains()
        #expect(app.disk.spotlightFiles.isEmpty)
        #expect((app.largeFiles.result?.matchBytes ?? 0) == 0)
        #expect(app.tree?.total.freeable == 0)
    }

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
        #expect(try await app.exportExplorerCSV(to: destination, for: index.root, render: { _ in "nouveau" }))
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
        let published = try await app.exportExplorerCSV(to: destination, for: index.root, render: { _ in "nouveau" }, stage: { text, temporary in
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
        #expect(try await app.exportExplorerCSV(to: destination, for: index.root, render: { _ in csv }))
        #expect(try String(contentsOf: destination, encoding: .utf8) == csv)

        let old = "Vérification d’un CSV préexistant"
        try old.write(to: destination, atomically: false, encoding: .utf8)
        var staged: URL?
        let changed = try await app.exportExplorerCSV(to: destination, for: index.root, render: { _ in
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
        #expect(try await app.exportExplorerCSV(to: destination, for: safe, render: { _ in safeCSV }))
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
        #expect(await app.revalidateExplorerGains() && app.tree === index.root)
        try fm.removeItem(at: archives)
        try fm.createSymbolicLink(at: archives, withDestinationURL: target)

        let revalidated = await app.revalidateExplorerGains()
        #expect(!revalidated)
        let displayed = try #require(app.tree?.descendant(atPath: target.path))
        #expect(displayed.total.allocated == original.total.allocated)
        #expect(displayed.total.freeable == 0 && displayed.files.first?.sizes.freeable == 0)
        #expect(app.tree?.total.freeable == 0)
        #expect(original.total.freeable > 0)
        #expect(await app.revalidateExplorerGains() && app.treeVolume?.id == volume.id)
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
            await app.selectAnalysisVolume(volume)?.value
            #expect(app.tree?.descendant(atPath: second.path)?.total.freeable == priorGain)
        }

        try fm.removeItem(at: preferences)
        try fm.createSymbolicLink(at: preferences, withDestinationURL: second)
        #expect(!old.hasCurrentProtectionRoots)
        await app.selectAnalysisVolume(volume)?.value
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
