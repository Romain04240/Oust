import Foundation
import OustClean
import OustCore
import OustSafety
import OustScan
import Testing
@testable import OustRules

struct DeviceBackupsTests {
    private let base = "Library/Application Support/MobileSync/Backup"

    @Test("La vraie date protège la dernière sauvegarde de chaque appareil, même si leurs noms sont identiques")
    func latestForEachDevice() async throws {
        let home = try FakeHome()
        let older = Date(timeIntervalSince1970: 30_000)
        let newer = Date(timeIntervalSince1970: 40_000)
        let other = Date(timeIntervalSince1970: 20_000)
        try backup("iphone-old", in: home, id: "AABBCCDD-1234", date: older)
        try backup("iphone-new", in: home, id: "aabbccdd-1234", date: newer)
        try backup("ipad-only", in: home, id: "CCDD1122-1234", date: other)
        let oldFolder = home.root.appendingPathComponent(base + "/iphone-old")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: oldFolder.path)

        let items = await RuleEngine.collect(home.context(), finders: [.userContent]).filter(\.isDeviceBackup)
        #expect(items.count == 3)
        #expect(Set(items.filter { $0.protections.contains(.newestKept) }.compactMap { $0.paths.first?.lastPathComponent })
                == ["iphone-new", "ipad-only"])
        #expect(Set(items.compactMap(\.lastActivity)) == [older, newer, other])
        for item in items {
            #expect(item.safety == .protected && item.method == .manual)
            #expect(item.sizes.allocated > 0 && item.sizes.freeable == 0)
            #expect(!item.isSelectable && !PreselectionPolicy().preselects(item))
        }
    }

    @Test("Les dates inconnues et les liens restent protégés, sans deviner une dernière sauvegarde")
    func uncertainMetadata() async throws {
        let home = try FakeHome()
        let date = Date(timeIntervalSince1970: 30_000)
        try backup("avec-date", in: home, id: "AABBCCDD-1234", date: date)
        try backup("sans-date", in: home, id: "AABBCCDD-1234", date: nil)
        try backup("sans-identite", in: home, id: nil, date: date)
        try home.file(base + "/lien-info/payload")
        let fm = FileManager.default
        let root = home.root.appendingPathComponent(base)
        try fm.createSymbolicLink(at: root.appendingPathComponent("lien-info/Info.plist"),
                                  withDestinationURL: root.appendingPathComponent("avec-date/Info.plist"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("lien-dossier"),
                                  withDestinationURL: root.appendingPathComponent("avec-date"))

        let items = await RuleEngine.collect(home.context(), finders: [.userContent]).filter(\.isDeviceBackup)
        #expect(items.count == 4)
        let safe = items.allSatisfy { $0.protections.contains(.unknownState) && !$0.isSelectable }
        #expect(safe)
        #expect(items.first { $0.paths.first?.lastPathComponent == "lien-info" }?.lastActivity == nil)
        #expect(items.first { $0.paths.first?.lastPathComponent == "sans-date" }?.lastActivity == nil)
    }

    @Test("Le moteur refuse la Corbeille d’une sauvegarde, de son parent et d’une redirection")
    func trashVeto() async throws {
        let home = try FakeHome()
        try backup("local", in: home, id: "AABBCCDD-1234", date: nil)
        let root = home.root.appendingPathComponent(base)
        let fm = FileManager.default
        let target = home.root.appendingPathComponent("Stockage sauvegardes")
        try fm.moveItem(at: root, to: target)
        try fm.createSymbolicLink(at: root, withDestinationURL: target)
        let outside = home.root.appendingPathComponent("Autre")
        try fm.createSymbolicLink(at: outside, withDestinationURL: target)
        let paths = [root.appendingPathComponent("local/payload"), target.appendingPathComponent("local"),
                     root.deletingLastPathComponent(), outside.appendingPathComponent("local/payload")]
        let guardPaths = PathGuard(home: home.root)
        let trash = home.root.appendingPathComponent("CorbeilleFictive")
        let engine = CleanupEngine(trasher: FolderTrasher(folder: trash), history: nil, pathGuard: guardPaths,
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil })
        for path in paths {
            #expect(!guardPaths.allows(path))
            let generic = CleanupItem(title: "Test", paths: [path], category: .explorer, owner: "",
                                      ruleID: "fixture.trash", safety: .review, method: .trash, rebuild: .irreversible)
            var outcomes: [CleanupOutcome] = []
            for await event in engine.run([generic]) {
                if case .finished(let report) = event { outcomes = report.outcomes }
            }
            #expect(outcomes.map(\.result) == [.skipped(.refusedByGuard)])
            #expect(fm.fileExists(atPath: path.path))
        }
    }

    @Test("Une sauvegarde interrompue ne prend pas le badge à la dernière copie achevée")
    func interruptedBackup() async throws {
        let home = try FakeHome()
        try backup("ancienne", in: home, id: "AABBCCDD-1234", date: Date(timeIntervalSince1970: 10))
        try backup("interrompue", in: home, id: "AABBCCDD-1234", date: Date(timeIntervalSince1970: 20), state: "running")
        let items = await RuleEngine.collect(home.context(), finders: [.userContent]).filter(\.isDeviceBackup)
        #expect(items.count == 2)
        #expect(items.first { $0.protections.contains(.newestKept) }?.paths.first?.lastPathComponent == "ancienne")
        #expect(items.first { $0.paths.first?.lastPathComponent == "interrompue" }?.protections == [.unknownState])
    }

    @Test("Le changement des métadonnées d’une autre copie retire le badge pendant la mesure")
    func recheckRanking() async throws {
        let home = try FakeHome()
        try backup("a", in: home, id: "AABBCCDD-1234", date: Date(timeIntervalSince1970: 20))
        try backup("b", in: home, id: "AABBCCDD-1234", date: Date(timeIntervalSince1970: 10))
        let plist = home.root.appendingPathComponent(base + "/b/Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Target Identifier": "AABBCCDD-1234",
            "Last Backup Date": Date(timeIntervalSince1970: 30),
        ], format: .binary, options: 0)
        let items = await RuleEngine.collect(home.context(), finders: [.userContent], measurer: Measurer { urls in
            do { try data.write(to: plist) } catch { Issue.record("Impossible de modifier la fixture") }
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, Measurement.empty) })
        }).filter(\.isDeviceBackup)
        let a = try #require(items.first { $0.paths.first?.lastPathComponent == "a" })
        #expect(a.protections == [.unknownState])
    }

    @Test("Le veto s’applique à la cible et au parent d’un lien vers une seule sauvegarde")
    func oneRedirectedBackup() throws {
        let home = try FakeHome()
        try home.file("Stockage/Appareil/payload")
        try home.file(base + "/Autre/payload")
        let root = home.root.appendingPathComponent(base)
        let target = home.root.appendingPathComponent("Stockage/Appareil")
        let alias = root.appendingPathComponent("AAAA1111")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let guardPaths = PathGuard(home: home.root)
        for path in [alias, alias.appendingPathComponent("payload"), target, target.appendingPathComponent("payload"),
                     target.deletingLastPathComponent()] {
            #expect(!guardPaths.allows(path))
        }
    }

    @Test("Un statut terminé sans date ne prouve aucune dernière sauvegarde")
    func noCompletionDate() async throws {
        let home = try FakeHome()
        try backup("a", in: home, id: "AABBCCDD-1234", date: Date(timeIntervalSince1970: 10))
        try backup("b", in: home, id: "AABBCCDD-1234", date: Date(timeIntervalSince1970: 20))
        let status = try PropertyListSerialization.data(fromPropertyList: ["SnapshotState": "finished"], format: .binary, options: 0)
        try status.write(to: home.root.appendingPathComponent(base + "/b/Status.plist"))
        let items = await RuleEngine.collect(home.context(), finders: [.userContent]).filter(\.isDeviceBackup)
        #expect(items.count == 2)
        let newest = items.contains { $0.protections.contains(.newestKept) }
        #expect(!newest)
    }

    @Test("Un lien vers un volume absent conserve le veto localisé", arguments: [false, true])
    func danglingRedirect(relative: Bool) throws {
        let home = try FakeHome()
        try home.file(base + "/Autre/payload")
        try home.file("ordinaire")
        let missing = home.root.appendingPathComponent("Absent/Copie")
        let alias = home.root.appendingPathComponent(base + "/AAAABBBB")
        try FileManager.default.createSymbolicLink(atPath: alias.path,
            withDestinationPath: relative ? "../../../../Absent/Copie" : missing.path)
        let guardPaths = PathGuard(home: home.root)
        #expect(guardPaths.allows(home.root.appendingPathComponent("ordinaire")))
        #expect(!guardPaths.allows(alias))
        #expect(!guardPaths.allows(missing))
        try home.file("Absent/Copie/payload")
        #expect(!guardPaths.allows(missing.appendingPathComponent("payload")))
    }

    @Test("Un lien pendant relatif peut traverser un alias de dossier accessible")
    func danglingRedirectThroughAlias() throws {
        let home = try FakeHome()
        try home.file(base + "/Autre/payload")
        try home.file("Stockage/existant")
        try home.file("ordinaire")
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: home.root.appendingPathComponent("LienStockage").path,
                                  withDestinationPath: "Stockage")
        let link = home.root.appendingPathComponent(base + "/Appareil")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../../LienStockage/Absent/Copie")
        let guardPaths = PathGuard(home: home.root)
        #expect(!guardPaths.protectsDeviceBackups(home.root.appendingPathComponent("ordinaire"),
                                                  resolved: home.root.appendingPathComponent("ordinaire")))
        #expect(guardPaths.allows(home.root.appendingPathComponent("ordinaire")))
        try home.file("Stockage/Absent/Copie/payload")
        #expect(!guardPaths.allows(home.root.appendingPathComponent("Stockage/Absent/Copie/payload")))
    }

    @Test("Un contrôle MobileSync bloqué termine l'estimation des worktrees avec un veto")
    func worktreeProtectionTimeout() async throws {
        let home = try FakeHome()
        try home.file("Projet/worktree/fichier")
        let folder = home.root.appendingPathComponent("Projet/worktree")
        let guardPaths = PathGuard(home: home.root)
        #expect(await guardPaths.allowedWorktreesForAnalysis([folder]) == [folder])
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let clock = ContinuousClock()
        let start = clock.now
        let allowed = await guardPaths.allowedWorktreesForAnalysis([folder], capture: { _ in
            gate.wait()
            return DeviceBackupPath.Snapshot.capture(nil)
        })
        #expect(allowed.isEmpty && clock.now - start < .seconds(3))
    }

    @Test("Scanner une copie via un autre chemin canonique ne lui attribue aucun gain")
    func aliasedScanRoot() async throws {
        let home = try FakeHome()
        try home.file(base + "/Autre/payload")
        try home.file("Stockage/Device/Copie.bin", bytes: 180_000)
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: home.root.appendingPathComponent("Alias").path, withDestinationPath: "Stockage")
        let backupRoot = home.root.appendingPathComponent(base)
        try fm.createSymbolicLink(atPath: backupRoot.appendingPathComponent("Appareil").path,
                                  withDestinationPath: "../../../../Stockage/Device")
        let aliasRoot = home.root.appendingPathComponent("Alias/Device")
        let result = await Scanner.scan([aliasRoot], options: ScanOptions(leafThreshold: 1,
                                                                          deviceBackupsDirectory: backupRoot.path))
        let tree = try #require(result.root)
        #expect(tree.total.allocated > 0)
        #expect(tree.total.freeable == 0 && tree.files.first?.sizes.freeable == 0)
        #expect(!PathGuard(home: home.root).allows(aliasRoot.appendingPathComponent("Copie.bin")))
    }

    @Test("Un contrôle MobileSync bloqué termine l'inventaire des journaux")
    func userLogProtectionTimeout() async throws {
        let home = try FakeHome()
        try home.file("Library/Logs/Projet/fictif.log")
        let log = home.root.appendingPathComponent("Library/Logs/Projet/fictif.log")
        let guardPaths = PathGuard(home: home.root)
        #expect(await guardPaths.allowedUserLogsForAnalysis([log]) == [log])
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let clock = ContinuousClock()
        let start = clock.now
        let allowed = await guardPaths.allowedUserLogsForAnalysis([log], capture: { _ in
            gate.wait()
            return DeviceBackupPath.Snapshot.capture(nil)
        })
        #expect(allowed.isEmpty && clock.now - start < .seconds(3))
    }

    @Test("Un worktree redirigé après sélection reste en place lors du nettoyage")
    func worktreeExecutionVeto() async throws {
        let home = try FakeHome()
        try home.file(base + "/Autre/payload")
        try home.file("Worktree/payload")
        let folder = home.root.appendingPathComponent("Worktree")
        let root = home.root.appendingPathComponent(base)
        let guardPaths = PathGuard(home: home.root)
        #expect(await guardPaths.allowedWorktreesForAnalysis([folder]) == [folder])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Appareil"), withDestinationURL: folder)
        let item = CleanupItem(title: "Fictif", paths: [folder], category: .aiAgents, owner: "",
                               ruleID: "fixture.worktree", safety: .review,
                               method: .gitWorktreeRemove(repository: home.root.path), rebuild: .irreversible)
        let engine = CleanupEngine(history: nil, pathGuard: guardPaths,
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil })
        var outcomes: [CleanupOutcome] = []
        for await event in engine.run([item]) {
            if case .finished(let report) = event { outcomes = report.outcomes }
        }
        #expect(outcomes.map(\.result) == [.skipped(.refusedByGuard)])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("payload").path))
    }

    @Test("Un journal en lecture seule garde zéro gain quand MobileSync est redirigé pendant la mesure")
    func redirectedUserLogHasNoGain() async throws {
        let home = try FakeHome()
        try home.file(base + "/Autre/payload")
        try home.file("Library/Logs/Projet/fictif.log", bytes: 180_000)
        let log = home.root.appendingPathComponent("Library/Logs/Projet/fictif.log")
        let redirect = home.root.appendingPathComponent(base + "/Appareil")
        let candidate = Candidate(item: CleanupItem(title: "Journal", paths: [log], category: .userLogs,
            owner: "Projet", ruleID: "logs.user", safety: .protected, protections: [.unknownState],
            method: .trash, rebuild: .irreversible))
        let items = await RuleEngine.measure([candidate], using: Measurer { paths in
            let measured = await Scanner.measure(paths)
            #expect((measured[log]?.sizes.freeable ?? 0) > 0)
            do {
                try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: log.deletingLastPathComponent())
            } catch {
                Issue.record("La redirection du dossier fictif a échoué")
            }
            return measured
        }, pathGuard: PathGuard(home: home.root))
        let item = try #require(items.first)
        #expect(item.sizes.allocated > 0 && item.sizes.freeable == 0 && !item.isSelectable)
    }

    private func backup(_ name: String, in home: FakeHome, id: String?, date: Date?, state: String = "finished") throws {
        try home.file(base + "/\(name)/payload", bytes: 180_000)
        var info: [String: Any] = ["Device Name": "Appareil de test"]
        info["Target Identifier"] = id
        info["Last Backup Date"] = date
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        let root = home.root.appendingPathComponent(base + "/\(name)")
        try plist.write(to: root.appendingPathComponent("Info.plist"))
        var fields: [String: Any] = ["SnapshotState": state]
        fields["Date"] = date
        let status = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
        try status.write(to: root.appendingPathComponent("Status.plist"))
    }
}
