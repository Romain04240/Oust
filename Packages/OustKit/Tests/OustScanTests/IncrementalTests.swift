import Darwin
import Foundation
import OustCore
import Testing
@testable import OustScan

/// La réanalyse incrémentale doit rendre exactement ce qu'un parcours complet
/// rendrait : sinon, mieux vaut tout relire.
@Suite("La réanalyse incrémentale")
struct IncrementalTests {
    let options = ScanOptions(threads: 4, leafThreshold: 100_000)

    @Test("Une archive de compte ne compte que comme espace occupé dans l’Explorateur et Spotlight")
    func accountArchivesAreNotFreeable() async throws {
        let fixture = try Fixture()
        let archives = try fixture.directory("Users/Deleted Users")
        let protected = try fixture.file("Users/Deleted Users/Compte.DMG", bytes: 180_000)
        _ = try fixture.file("Users/Deleted Users/Petit.dmg", bytes: 100)
        let ordinary = try fixture.file("Ordinaire.dmg", bytes: 180_000)
        let options = ScanOptions(threads: 2, leafThreshold: 100_000, accountArchivesDirectory: archives.path)
        let (index, _) = await ScanIndex.refresh(nil, root: fixture.root, options: options)
        let node = try #require(index.root.descendant(atPath: archives.path))
        #expect(node.files.first?.sizes.freeable == 0)
        #expect(node.smallFiles.allocated > 0 && node.smallFiles.freeable == 0)
        #expect(node.total.freeable == 0 && node.total.allocated > 0)
        #expect(index.root.total.freeable == index.root.files.first?.sizes.allocated)
        let store = TreeStore(directory: fixture.root.appendingPathComponent("CacheFictif"))
        try store.save(index)
        #expect(store.load(rootPath: index.rootPath)?.root.descendant(atPath: archives.path)?.total == node.total)

        let alias = fixture.root.appendingPathComponent("AliasUsers")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: archives.deletingLastPathComponent())
        let redirected = alias.appendingPathComponent("Deleted Users")
        let (selected, _) = await ScanIndex.refresh(nil, root: redirected, options: options)
        #expect(selected.root.total == node.total)
        let paths = [redirected.appendingPathComponent(protected.lastPathComponent).path, ordinary.path]
        let spotlight = Spotlight.parse(Data(paths.joined(separator: "\0").utf8), minimumBytes: 1,
                                         accountArchivesDirectory: archives.path)
        #expect(spotlight.first { $0.name == protected.lastPathComponent }?.sizes.freeable == 0)
        #expect((spotlight.first { $0.name == ordinary.lastPathComponent }?.sizes.freeable ?? 0) > 0)
    }

    @Test("Le parcours protège le dossier Preferences remplacé avant l'ouverture")
    func replacedPreferenceDirectory() async throws {
        let fixture = try Fixture()
        let preferences = try fixture.directory("Library/Preferences")
        let options = ScanOptions(threads: 2, leafThreshold: 100_000, readOnlyPreferencesDirectory: preferences.path)
        let walk = Walk(options: options, progress: ScanProgress(), ownership: Ownership(),
                        deviceBackupDirectory: DeviceBackupPath.Snapshot.capture(options.deviceBackupsDirectory))
        try FileManager.default.moveItem(at: preferences, to: fixture.root.appendingPathComponent("AnciennesPreferences"))
        let plist = try fixture.file("Library/Preferences/Fictif.plist", bytes: 180_000)
        _ = try fixture.file("Library/Preferences/Petit.plist", bytes: 200)
        let roots = await walk.run(roots: [preferences.path])
        let tree = try #require(roots.first)
        #expect(!walk.hasCurrentProtectionRoots)
        #expect(tree.total.allocated >= Fixture.allocated(plist))
        #expect(tree.total.freeable == 0)
        #expect(tree.files.first?.sizes.freeable == 0)
        #expect(tree.smallFiles.allocated > 0 && tree.smallFiles.freeable == 0)
    }

    @Test("Changer la cible de Preferences invalide l'index incrémental et son cache")
    func redirectedPreferenceDirectoryInvalidatesIndex() async throws {
        let fixture = try Fixture()
        let library = try fixture.directory("Library")
        let preferences = library.appendingPathComponent("Preferences")
        let a = try fixture.directory("A")
        let b = try fixture.directory("B")
        _ = try fixture.file("A/Fictif.plist", bytes: 180_000)
        _ = try fixture.file("B/Fictif.plist", bytes: 180_000)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: preferences, withDestinationURL: a)
        let options = ScanOptions(threads: 2, readOnlyPreferencesDirectory: preferences.path)
        let (old, _) = await ScanIndex.refresh(nil, root: fixture.root, options: options)
        #expect(old.root.descendant(atPath: a.path)?.total.freeable == 0)
        #expect((old.root.descendant(atPath: b.path)?.total.freeable ?? 0) > 0)
        let store = TreeStore(directory: fixture.root.appendingPathComponent("CacheFictif"))
        try store.save(old)
        #expect(store.load(rootPath: old.rootPath)?.hasCurrentProtectionRoots == true)

        try fm.removeItem(at: preferences)
        try fm.createSymbolicLink(at: preferences, withDestinationURL: b)
        var events = FileSystemChanges()
        events.directories = [library.path]
        let projected = await old.applying(events, eventID: old.eventID, database: old.eventDatabase ?? "",
                                           progress: ScanProgress(), now: Date())
        #expect(projected == nil)
        #expect(store.load(rootPath: old.rootPath) == nil)
        let safe = old.checkedForDisplay()
        #expect(safe.root.total.allocated == old.root.total.allocated && safe.root.total.freeable == 0)
        let (fresh, how) = await ScanIndex.refresh(old, root: fixture.root, options: options)
        #expect(how == .full(.optionsChanged))
        #expect((fresh.root.descendant(atPath: a.path)?.total.freeable ?? 0) > 0)
        #expect(fresh.root.descendant(atPath: b.path)?.total.freeable == 0)
    }

    @Test("Le cache est invalidé quand la même cible de Preferences change de chemin")
    func movedPreferenceDirectoryWithSameIdentityInvalidatesCache() async throws {
        let fixture = try Fixture()
        let library = try fixture.directory("Library")
        let preferences = library.appendingPathComponent("Preferences")
        let a = try fixture.directory("A")
        let b = try fixture.directory("B")
        let intermediate = fixture.root.appendingPathComponent("Intermediaire")
        _ = try fixture.file("A/Fictif.plist", bytes: 180_000)
        _ = try fixture.file("B/Fictif.plist", bytes: 180_000)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: preferences, withDestinationURL: a)
        let options = ScanOptions(threads: 2, readOnlyPreferencesDirectory: preferences.path)
        let (old, _) = await ScanIndex.refresh(nil, root: fixture.root, options: options)
        let store = TreeStore(directory: fixture.root.appendingPathComponent("CacheFictif"))
        try store.save(old)
        #expect(store.load(rootPath: old.rootPath)?.root.descendant(atPath: a.path)?.total.freeable == 0)
        #expect((old.root.descendant(atPath: b.path)?.total.freeable ?? 0) > 0)

        try fm.moveItem(at: a, to: intermediate)
        try fm.moveItem(at: b, to: a)
        try fm.moveItem(at: intermediate, to: b)
        try fm.removeItem(at: preferences)
        try fm.createSymbolicLink(at: preferences, withDestinationURL: b)

        let original = try #require(old.preferenceDirectory)
        let moved = PreferenceDirectory.capturingLocation(at: preferences.path)
        #expect(original.identity != nil && original.identity == moved.identity)
        #expect(original.resolvedPath != moved.resolvedPath)
        #expect(!old.canReuse(for: options) && store.load(rootPath: old.rootPath) == nil)
        let (fresh, how) = await ScanIndex.refresh(old, root: fixture.root, options: options)
        #expect(how == .full(.optionsChanged))
        #expect((fresh.root.descendant(atPath: a.path)?.total.freeable ?? 0) > 0)
        #expect(fresh.root.descendant(atPath: b.path)?.total.freeable == 0)
    }

    /// Ce qu'on compare d'un arbre à l'autre : chaque dossier, ses totaux et ses
    /// feuilles, à son chemin relatif.
    static func outline(_ root: TreeNode) -> [String] {
        var lines: [String] = []
        var stack: [(TreeNode, String)] = [(root, "")]
        while let (node, path) = stack.popLast() {
            let leaves = node.files.map { "\($0.name):\($0.sizes.allocated):\($0.logicalSize)" }.sorted()
            lines.append("\(path)/ \(node.total.allocated) \(node.total.freeable) \(node.fileCount) "
                         + "own=\(node.ownFileCount) small=\(node.smallFileCount) [\(leaves.joined(separator: ","))]")
            for child in node.children { stack.append((child, path + "/" + child.name)) }
        }
        return lines.sorted()
    }

    /// FSEvents enregistre les événements en différé : on réessaie jusqu'à ce
    /// que l'index rafraîchi rejoigne un parcours complet, ou qu'on abandonne.
    ///
    /// `byFolder` : comparer dossier par dossier. Pas pour les liens physiques,
    /// qu'un parcours complet attribue au premier dossier rencontré, dans un
    /// ordre qui dépend des threads : on compare alors les totaux de la racine.
    func refreshUntilSettled(_ previous: ScanIndex, root: URL, byFolder: Bool = true,
                             expect: (ScanIndex) -> Bool = { _ in true }) async throws -> (ScanIndex, IndexRefresh) {
        let reference = await Scanner.scan([root], options: options).roots[0]
        let summary = { (node: TreeNode) in
            byFolder ? Self.outline(node) : ["\(node.total.allocated) \(node.total.freeable) \(node.fileCount)"]
        }
        let expected = summary(reference)
        var last: (ScanIndex, IndexRefresh)?
        for _ in 0..<40 {
            let refreshed = await ScanIndex.refresh(previous, root: root, options: options)
            last = refreshed
            if summary(refreshed.index.root) == expected, expect(refreshed.index) { return refreshed }
            try await Task.sleep(for: .milliseconds(250))
        }
        let (index, how) = try #require(last)
        #expect(summary(index.root) == expected, "rafraîchi par \(how)")
        return (index, how)
    }

    @Test("Un fichier ajouté entre deux analyses est vu sans tout relire")
    func addedFile() async throws {
        let fixture = try Fixture()
        try fixture.file("a/un.bin", bytes: 400_000)
        try fixture.file("b/deux.txt", bytes: 2_000)
        let first = await ScanIndex.refresh(nil, root: fixture.root, options: options)
        #expect(first.how == .full(.noIndex))

        try fixture.file("a/trois.bin", bytes: 300_000)

        let (index, how) = try await refreshUntilSettled(first.index, root: fixture.root)
        guard case .incremental = how else {
            Issue.record("attendu une relecture partielle, obtenu \(how)")
            return
        }
        #expect(index.root.descendant(atPath: fixture.root.appendingPathComponent("a").path)?
            .files.contains { $0.name == "trois.bin" } == true)
        // L'index d'origine n'a pas bougé : l'Explorateur le lit peut-être encore.
        #expect(first.index.root.descendant(atPath: fixture.root.appendingPathComponent("a").path)?
            .files.contains { $0.name == "trois.bin" } == false)
    }

    @Test("Un fichier supprimé entre deux analyses disparaît des totaux")
    func removedFile() async throws {
        let fixture = try Fixture()
        let doomed = try fixture.file("a/b/c/gros.bin", bytes: 900_000)
        try fixture.file("a/b/petit.txt", bytes: 500)
        let first = await ScanIndex.refresh(nil, root: fixture.root, options: options)
        let before = first.index.root.total.allocated

        try FileManager.default.removeItem(at: doomed)

        let (index, how) = try await refreshUntilSettled(first.index, root: fixture.root)
        #expect(how != .full(.historyLost))
        #expect(index.root.total.allocated == before - Fixture.allocated(doomed) || Fixture.allocated(doomed) == 0)
    }

    @Test("Un fichier renommé ou déplacé entre deux analyses est retrouvé sous son nouveau nom")
    func renamedFile() async throws {
        let fixture = try Fixture()
        let original = try fixture.file("source/rapport.bin", bytes: 600_000)
        try fixture.directory("destination")
        let first = await ScanIndex.refresh(nil, root: fixture.root, options: options)

        let renamed = fixture.root.appendingPathComponent("source/rapport-final.bin")
        try FileManager.default.moveItem(at: original, to: renamed)
        let moved = fixture.root.appendingPathComponent("destination/rapport-final.bin")
        try FileManager.default.moveItem(at: renamed, to: moved)
        // Et un dossier entier renommé.
        try fixture.file("ancien/dedans.bin", bytes: 200_000)
        let (second, _) = try await refreshUntilSettled(first.index, root: fixture.root)
        try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("ancien"),
                                         to: fixture.root.appendingPathComponent("nouveau"))

        let (index, how) = try await refreshUntilSettled(second, root: fixture.root)
        guard case .incremental = how else {
            Issue.record("attendu une relecture partielle, obtenu \(how)")
            return
        }
        #expect(index.root.descendant(atPath: moved.deletingLastPathComponent().path)?
            .files.map(\.name) == ["rapport-final.bin"])
        #expect(index.root.descendant(atPath: fixture.root.appendingPathComponent("source").path)?.files.isEmpty == true)
        #expect(index.root.descendant(atPath: fixture.root.appendingPathComponent("nouveau").path) != nil)
        #expect(index.root.descendant(atPath: fixture.root.appendingPathComponent("ancien").path) == nil)
    }

    @Test("Un lien physique reste compté une fois quand on ne relit que son dossier")
    func hardLinkSurvivesPartialRescan() async throws {
        let fixture = try Fixture()
        let original = try fixture.file("a/original.bin", bytes: 700_000)
        try fixture.directory("b")
        #expect(Darwin.link(original.path, fixture.root.appendingPathComponent("b/lien.bin").path) == 0)
        let first = await ScanIndex.refresh(nil, root: fixture.root, options: options)
        let total = first.index.root.total.allocated
        #expect(total == Fixture.allocated(original))

        // Un changement dans chacun des deux dossiers : les deux sont relus.
        try fixture.file("a/voisin.txt", bytes: 10)
        try fixture.file("b/voisin.txt", bytes: 10)

        let (index, _) = try await refreshUntilSettled(first.index, root: fixture.root, byFolder: false) { index in
            index.root.fileCount == 4
        }
        let added = Fixture.allocated(fixture.root.appendingPathComponent("a/voisin.txt"))
            + Fixture.allocated(fixture.root.appendingPathComponent("b/voisin.txt"))
        #expect(index.root.total.allocated == total + added)
    }

    @Test("Sans historique d'événements, on repart d'un parcours complet")
    func lostHistoryFallsBackToFullScan() async throws {
        let fixture = try Fixture()
        try fixture.file("a/un.bin", bytes: 200_000)
        let first = await ScanIndex.refresh(nil, root: fixture.root, options: options)
        let previous = first.index
        let forged = ScanIndex(root: previous.root, options: previous.options, ownership: previous.ownership,
                               eventID: previous.eventID, eventDatabase: "base-effacée",
                               scannedAt: previous.scannedAt, fullScanAt: previous.fullScanAt,
                               skippedVolumes: [], scannedRootLocation: previous.scannedRootLocation,
                               preferenceDirectory: previous.preferenceDirectory,
                               accountArchiveDirectory: previous.accountArchiveDirectory,
                               deviceBackupDirectory: previous.deviceBackupDirectory)
        let refreshed = await ScanIndex.refresh(forged, root: fixture.root, options: options)
        #expect(refreshed.how == .full(.historyLost))

        let old = ScanIndex(root: previous.root, options: previous.options, ownership: previous.ownership,
                            eventID: previous.eventID, eventDatabase: previous.eventDatabase,
                            scannedAt: previous.scannedAt, fullScanAt: Date(timeIntervalSinceNow: -30 * 86_400),
                            skippedVolumes: [], scannedRootLocation: previous.scannedRootLocation,
                               preferenceDirectory: previous.preferenceDirectory,
                               accountArchiveDirectory: previous.accountArchiveDirectory,
                               deviceBackupDirectory: previous.deviceBackupDirectory)
        #expect(await ScanIndex.refresh(old, root: fixture.root, options: options).how == .full(.tooOld))
    }

    @Test("La réutilisation d'un sous-arbre déplacé sous MobileSync conserve l'occupation et annule le gain")
    func incrementalWithholdsReusedSubtreeGain() async throws {
        let fixture = try Fixture()
        let scan = try fixture.directory("Scan")
        let source = try fixture.directory("Scan/Ordinaire")
        let branch = try fixture.directory("Scan/Ordinaire/A")
        let protected = try fixture.directory("Stockage/Device")
        let backupRoot = try fixture.directory("MobileSync/Backup")
        try fixture.file("Scan/Ordinaire/A/Sous/fictif.bin", bytes: 400_000)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: backupRoot.appendingPathComponent("Appareil"), withDestinationURL: protected)
        let options = ScanOptions(leafThreshold: 1, deviceBackupsDirectory: backupRoot.path)
        let old = await ScanIndex.refresh(nil, root: scan, options: options).index
        #expect((old.root.descendant(atPath: branch.path)?.total.freeable ?? 0) > 0)
        let destination = protected.appendingPathComponent("Ordinaire")
        try fm.moveItem(at: source, to: destination)
        try fm.createSymbolicLink(at: source, withDestinationURL: destination)
        var changes = FileSystemChanges()
        changes.directories = [branch.path]
        let fresh = await old.applying(changes, eventID: old.eventID + 1, database: old.eventDatabase ?? "",
                                       progress: ScanProgress(), now: Date())
        let checked = try #require(fresh?.index.root.descendant(atPath: branch.path))
        #expect(checked.total.allocated > 0 && checked.total.freeable == 0)
    }

    @Test("La relecture simultanée d’un dossier protégé et de son descendant garde les bons totaux")
    func overlappingProtectedJobsWithholdGains() async throws {
        let fixture = try Fixture()
        let scan = try fixture.directory("Scan")
        let source = try fixture.directory("Scan/Ordinaire")
        let branch = try fixture.directory("Scan/Ordinaire/A")
        let child = try fixture.directory("Scan/Ordinaire/A/Sous")
        let backup = try fixture.directory("Stockage/Device")
        let backupRoot = try fixture.directory("MobileSync/Backup")
        try fixture.file("Scan/Ordinaire/A/Sous/avant.bin", bytes: 400_000)
        try fixture.file("Scan/Ordinaire/A/Sous/Profondeur/conserver.bin", bytes: 220_000)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: backupRoot.appendingPathComponent("Appareil"), withDestinationURL: backup)
        let options = ScanOptions(threads: 4, leafThreshold: 1, deviceBackupsDirectory: backupRoot.path)
        let old = await ScanIndex.refresh(nil, root: scan, options: options).index
        let before = try #require(old.root.descendant(atPath: child.path))
        #expect(before.total.freeable > 0)
        let moved = backup.appendingPathComponent("Ordinaire")
        try fm.moveItem(at: source, to: moved)
        try fm.createSymbolicLink(at: source, withDestinationURL: moved)
        try fm.removeItem(at: moved.appendingPathComponent("A/Sous/avant.bin"))
        try fixture.file("Stockage/Device/Ordinaire/A/Sous/apres.bin", bytes: 610_000)

        var changes = FileSystemChanges()
        changes.directories = [branch.path, child.path]
        let result = try #require(await old.applying(changes, eventID: old.eventID + 1, database: old.eventDatabase ?? "",
                                                        progress: ScanProgress(), now: Date()))
        #expect(result.how == .incremental(directories: 2))
        let updated = try #require(result.index.root.descendant(atPath: child.path))
        let independent = try #require(await Scanner.scan([child], options: options).root)
        #expect(updated.total == independent.total)
        #expect(updated.total.allocated > 0 && updated.total.freeable == 0)
        #expect(updated.files.map(\.name) == ["apres.bin"] && updated.files.allSatisfy { $0.sizes.freeable == 0 })
        let deep = try #require(updated.child(named: "Profondeur"))
        #expect(deep.files.map(\.name) == ["conserver.bin"] && deep.files.allSatisfy { $0.sizes.freeable == 0 })
        #expect(result.index.root.total.freeable == 0 && before.total.freeable > 0)
    }

    @Test("Un dossier remplacé déclenche un nouveau parcours plutôt qu'un index incomplet")
    func incrementalRejectsReplacedDirectory() async throws {
        let fixture = try Fixture()
        let scan = try fixture.directory("Scan")
        let child = try fixture.directory("Scan/Dossier")
        let replacement = try fixture.directory("Remplacement")
        let backups = try fixture.directory("MobileSync/Backup")
        try fixture.file("Scan/Dossier/original.bin", bytes: 200_000)
        try fixture.file("Remplacement/nouveau.bin", bytes: 410_000)
        let options = ScanOptions(leafThreshold: 1, deviceBackupsDirectory: backups.path)
        let first = await ScanIndex.refresh(nil, root: scan, options: options).index
        let fm = FileManager.default
        try fm.moveItem(at: child, to: fixture.root.appendingPathComponent("Ancien"))
        try fm.moveItem(at: replacement, to: child)
        var changes = FileSystemChanges()
        changes.directories = [child.path]
        let update = await first.applying(changes, eventID: first.eventID + 1, database: first.eventDatabase ?? "",
                                          progress: ScanProgress(), now: Date())
        #expect(update == nil)
        let fresh = await ScanIndex.refresh(nil, root: scan, options: options).index
        let measured = try #require(fresh.root.descendant(atPath: child.path))
        #expect(measured.status == .ok && measured.total.allocated > 0)
        #expect(measured.files.map(\.name) == ["nouveau.bin"])
    }

    @Test("Le cache et l'analyse rejettent un alias de racine redirigé après mesure")
    func redirectedScanRootInvalidatesCache() async throws {
        let fixture = try Fixture()
        try fixture.file("Ordinaire/Device/fichier.bin", bytes: 200_000)
        try fixture.file("Stockage/Device/sauvegarde.bin", bytes: 400_000)
        let fm = FileManager.default
        let backup = try fixture.directory("MobileSync/Backup")
        try fm.createSymbolicLink(atPath: backup.appendingPathComponent("Appareil").path,
                                  withDestinationPath: "../../Stockage/Device")
        let alias = fixture.root.appendingPathComponent("Alias")
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "Ordinaire")
        let root = alias.appendingPathComponent("Device")
        let options = ScanOptions(leafThreshold: 1, deviceBackupsDirectory: backup.path)
        let index = await ScanIndex.refresh(nil, root: root, options: options).index
        #expect(index.root.total.freeable > 0)
        let store = TreeStore(directory: try fixture.directory("Index"))
        try store.save(index)
        #expect(store.load(rootPath: index.rootPath) != nil)

        try fm.removeItem(at: alias)
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "Stockage")
        #expect(store.load(rootPath: index.rootPath) == nil)
        let checked = await index.revalidatedForDisplay()
        #expect(checked.root.total.freeable == 0)
        let rebuilt = await ScanIndex.refresh(index, root: root, options: options)
        #expect(rebuilt.how == .full(.optionsChanged))
        #expect(rebuilt.index.root.total.allocated > 0 && rebuilt.index.root.total.freeable == 0)
    }

    @Test("Rien n'a bougé : l'arbre est rendu tel quel")
    func unchangedTree() async throws {
        let fixture = try Fixture()
        try fixture.file("a/un.bin", bytes: 200_000)
        let first = await ScanIndex.refresh(nil, root: fixture.root, options: options)
        // Les événements de la création, antérieurs à l'analyse, peuvent encore
        // arriver une fois ; ensuite plus rien.
        var how = IndexRefresh.full(.noIndex)
        var index = first.index
        for _ in 0..<20 {
            (index, how) = await ScanIndex.refresh(index, root: fixture.root, options: options)
            if how == .unchanged { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(how == .unchanged)
    }

    @Test("L'index se relit à l'identique, et un index abîmé est ignoré")
    func storeRoundTrip() async throws {
        let fixture = try Fixture()
        try fixture.file("a/un.bin", bytes: 400_000)
        try fixture.file("a/b/deux.bin", bytes: 150_000)
        try fixture.file("c/petit.txt", bytes: 100)
        try fixture.file("c/package.json", bytes: 50)
        let original = try fixture.file("d/original.bin", bytes: 300_000)
        #expect(Darwin.link(original.path, fixture.root.appendingPathComponent("a/lien.bin").path) == 0)
        let data = try Fixture()
        let store = TreeStore(directory: data.root.appendingPathComponent("Index"))
        var options = options
        options.notableNames = ["package.json"]
        let index = await ScanIndex.fullScan(fixture.root.path, options: options, progress: ScanProgress(), now: Date())

        try store.save(index)
        let loaded = try #require(store.load(rootPath: fixture.root.path))

        #expect(Self.outline(loaded.root) == Self.outline(index.root))
        #expect(loaded.eventID == index.eventID)
        #expect(loaded.eventDatabase == index.eventDatabase)
        #expect(loaded.options.describesSameTree(as: index.options))
        #expect(loaded.ownership.links.count == index.ownership.links.count)
        #expect(loaded.root.descendant(atPath: fixture.root.appendingPathComponent("c").path)?.notableFiles == ["package.json"])
        #expect(store.load(rootPath: "/ailleurs") == nil)

        // Tronqué : refusé plutôt que relu de travers.
        let url = store.url(for: fixture.root.path)
        let bytes = try Data(contentsOf: url)
        try bytes.prefix(bytes.count / 2).write(to: url)
        #expect(store.load(rootPath: fixture.root.path) == nil)
    }

    @Test("Une règle retrouve son dossier sous ses autres noms")
    func aliasesResolve() async throws {
        let root = TreeNode(name: "Data", parent: nil, fileID: 1, rootPath: "/System/Volumes/Data")
        let users = TreeNode(name: "Users", parent: root, fileID: 2)
        let private_ = TreeNode(name: "private", parent: root, fileID: 3)
        let variable = TreeNode(name: "var", parent: private_, fileID: 4)
        root.children = [users, private_]
        private_.children = [variable]
        #expect(root.descendant(atPath: "/Users") === users)
        #expect(root.descendant(atPath: "/System/Volumes/Data/Users") === users)
        #expect(root.descendant(atPath: "/var") === variable)
        #expect(root.descendant(atPath: "/private/var") === variable)
        #expect(root.descendant(atPath: "/Applications") == nil)
    }
}

@Suite("Spotlight, lu par lstat")
struct SpotlightParseTests {
    @Test("Les dossiers, les petits fichiers et les doublons de chemin sont écartés")
    func parse() throws {
        let fixture = try Fixture()
        let big = try fixture.file("gros.bin", bytes: 3_000_000)
        let small = try fixture.file("petit.bin", bytes: 10_000)
        let bundle = try fixture.directory("Outil.app")
        let output = [big.path, small.path, bundle.path, big.path, "/nulle/part"].joined(separator: "\0")

        let files = Spotlight.parse(Data(output.utf8), minimumBytes: 1_000_000)

        #expect(files.map(\.path) == [big.path])
        #expect(files.first?.sizes.allocated == Fixture.allocated(big))
    }

    @Test("L’aperçu Spotlight garde la taille des préférences et indique un gain nul")
    func preferenceSizes() throws {
        let fixture = try Fixture()
        let preferences = try fixture.directory("Library/Preferences")
        let protected = try fixture.file("Library/Preferences/org.fixture.large.plist", bytes: 3_000_000)
        let ordinary = try fixture.file("ordinaire.plist", bytes: 3_000_000)
        let alias = fixture.root.appendingPathComponent("AliasLibrary")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: preferences.deletingLastPathComponent())
        let redirected = alias.appendingPathComponent("Preferences/\(protected.lastPathComponent)")
        let output = [redirected.path, protected.path, ordinary.path].joined(separator: "\0")

        let files = Spotlight.parse(Data(output.utf8), minimumBytes: 1_000_000,
                                    readOnlyPreferencesDirectory: preferences.path)
        let sizes = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.sizes) })
        #expect(sizes[redirected.path]?.allocated == Fixture.allocated(protected))
        #expect(sizes[redirected.path]?.freeable == 0)
        #expect((sizes[ordinary.path]?.freeable ?? 0) > 0)
    }
}
