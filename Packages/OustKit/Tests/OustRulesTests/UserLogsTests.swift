import Darwin
import Foundation
import Testing
@testable import OustClean
import OustCore
import OustRules
import OustSafety

struct UserLogsTests {
    @Test("Seuls les anciens journaux ordinaires sont affichés et restent protégés")
    func findsOldLogs() async throws {
        let home = try FakeHome()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let old = now.addingTimeInterval(-31 * 86_400)
        let paths = ["history.log", "history.log.2.gz"]
        for name in paths + ["data.txt", "held.log", ".hidden.log"] {
            try home.file("Library/Logs/Example/\(name)", modified: old)
        }
        try home.file("Library/Logs/Example/fresh.log", modified: now)
        try home.file("Library/Logs/Roblox/game.log", modified: old)
        try home.file("Outside/secret.log", modified: old)
        let logs = home.root.appendingPathComponent("Library/Logs")
        let outside = home.root.appendingPathComponent("Outside")
        let held = try FileHandle(forWritingTo: logs.appendingPathComponent("Example/held.log"))
        defer { try? held.close() }
        let fm = FileManager.default
        try fm.createSymbolicLink(at: logs.appendingPathComponent("linked"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: logs.appendingPathComponent("linked.log"),
                                  withDestinationURL: outside.appendingPathComponent("secret.log"))
        try fm.linkItem(at: outside.appendingPathComponent("secret.log"), to: logs.appendingPathComponent("hard.log"))

        let items = await RuleEngine.collect(home.context(now: now), finders: [.userLogs])
        #expect(Set(items.map(\.title)) == Set(paths))
        for item in items {
            #expect(item.category == .userLogs && item.safety == .protected)
            #expect(item.protections.contains(.unknownState))
            #expect(!item.isSelectable)
            #expect(item.lastActivity == old && item.sizes.allocated > 0)
            #expect(!PreselectionPolicy().preselects(item, now: now))
        }
    }

    enum CleanupScenario: CaseIterable, Sendable {
        case closed, unknown, openedDuringProbe, rotatedDuringProbe, runningOwner
    }

    @Test("Une sélection ancienne ne peut déplacer aucun journal utilisateur",
          arguments: CleanupScenario.allCases)
    func refusesLegacySelection(_ scenario: CleanupScenario) async throws {
        let home = try FakeHome()
        let now = Date()
        let bundle = "fr.oust.fixture"
        try home.file("Library/Logs/\(bundle)/daily.log", modified: now.addingTimeInterval(-31 * 86_400))
        var item = try #require(await RuleEngine.collect(home.context(now: now), finders: [.userLogs]).first)
        let source = try #require(item.paths.first)
        let original = Data(repeating: 0x42, count: 50_000)
        let rotated = home.root.appendingPathComponent("rotation.log")
        let replacement = Data("journal fictif de remplacement".utf8)
        // Reproduire la sélection enregistrée avant que l'inventaire devienne protégé.
        item.safety = .review
        item.protections = []
        let trash = home.root.appendingPathComponent("_corbeille")
        let fm = FileManager.default
        try fm.createDirectory(at: trash, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let engine = CleanupEngine(trasher: FolderTrasher(folder: trash),
                                   history: HistoryStore(directory: home.root.appendingPathComponent("_historique")),
                                   pathGuard: PathGuard(home: home.root), processes: { ProcessSnapshot(processes: []) },
                                   capacity: { _ in nil }, runningApps: {
            scenario == .runningOwner ? [bundle] : []
        }, userLogOpenStatus: { path in
            switch scenario {
            case .openedDuringProbe:
                guard let handle = try? FileHandle(forReadingFrom: source) else { return .unknown }
                defer { try? handle.close() }
                return OpenFiles.status(at: path)
            case .rotatedDuringProbe:
                do {
                    try FileManager.default.moveItem(at: source, to: rotated)
                    try replacement.write(to: source)
                    return .closed
                } catch { return .unknown }
            case .unknown: return .unknown
            case .closed, .runningOwner: return .closed
            }
        }, userLogTrashDirectory: trash)
        var report: CleanupReport?
        for await event in engine.run([item]) {
            if case .finished(let result) = event { report = result }
        }
        let reason: ProtectionReason = switch scenario {
        case .openedDuringProbe: .fileOpen
        case .runningOwner: .appRunning(name: bundle)
        default: .unknownState
        }
        #expect(report?.outcomes.first?.result == .skipped(.nowProtected(reason)))
        #expect(report?.outcomes.first?.trashedTo.isEmpty == true)
        #expect(try fm.contentsOfDirectory(atPath: trash.path).isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: home.root.path).allSatisfy { !$0.hasPrefix(UserLogRecovery.prefix) })
        if scenario == .rotatedDuringProbe {
            #expect(try Data(contentsOf: source) == replacement)
            #expect(try Data(contentsOf: rotated) == original)
        } else {
            #expect(try Data(contentsOf: source) == original)
        }
    }

    @Test("Le chemin du journal bloque l'Explorateur, un dossier, un alias et les autres catégories")
    func refusesMovesAndRestoresByPath() async throws {
        let home = try FakeHome()
        let fm = FileManager.default
        try home.file("Library/Logs/fr.oust.fixture/daily.log")
        let source = home.root.appendingPathComponent("Library/Logs/fr.oust.fixture/daily.log")
        let folder = source.deletingLastPathComponent()
        let alias = home.root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: folder)
        let aliasedSource = alias.appendingPathComponent(source.lastPathComponent)
        let trash = home.root.appendingPathComponent("_corbeille")
        try fm.createDirectory(at: trash, withIntermediateDirectories: false)
        let history = HistoryStore(directory: home.root.appendingPathComponent("_historique"))
        let guardPaths = PathGuard(home: home.root)
        let engine = CleanupEngine(trasher: FolderTrasher(folder: trash), history: history, pathGuard: guardPaths,
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil })
        let choices: [(URL, ItemCategory, String, CleanupMethod)] = [
            (source, .explorer, "explorer.item", .trash),
            (folder, .explorer, "explorer.item", .trash),
            (aliasedSource, .appLeftovers, "orphan.logs", .trash),
            (source, .archives, "archive.transfer", .archive(copy: trash.appendingPathComponent("copy").path))
        ]
        let items = choices.enumerated().map { index, choice in
            CleanupItem(id: "fixture-\(index)", title: choice.0.lastPathComponent, paths: [choice.0],
                        category: choice.1, owner: "", ruleID: choice.2, safety: .review,
                        method: choice.3, rebuild: .irreversible)
        }
        for choice in choices { #expect(!guardPaths.allows(choice.0)) }
        #expect(guardPaths.allows(home.root.appendingPathComponent("Library/Logs/Roblox/game.log")))
        #expect(guardPaths.allows(home.root.appendingPathComponent("Library/LogsBackup/ordinary.log")))

        var report: CleanupReport?
        for await event in engine.run(items) {
            if case .finished(let result) = event { report = result }
        }
        #expect(report?.outcomes.count == items.count)
        #expect(report?.outcomes.allSatisfy { $0.result == .skipped(.refusedByGuard) } == true)
        #expect(try fm.contentsOfDirectory(atPath: trash.path).isEmpty)
        #expect(try Data(contentsOf: source) == Data(repeating: 0x42, count: 50_000))

        let trashed = trash.appendingPathComponent("history.log")
        let payload = Data("journal fictif de l'historique".utf8)
        try payload.write(to: trashed)
        let destination = aliasedSource.deletingLastPathComponent().appendingPathComponent("other.log")
        let explorer = CleanupItem(title: "other.log", paths: [destination], category: .explorer,
                                   owner: "", ruleID: "explorer.item", safety: .review, method: .trash, rebuild: .irreversible)
        let outcome = CleanupOutcome(sessionID: UUID(), date: Date(), item: explorer, result: .trashed,
                                     bytes: 0, trashedTo: [trashed.path])
        await #expect(throws: HistoryStore.RestoreError.notRestorable) {
            try await history.restore(outcome, pathGuard: guardPaths)
        }
        #expect(try Data(contentsOf: trashed) == payload)
        #expect(!fm.fileExists(atPath: destination.path))
        #expect(!(await history.restoredIDs()).contains(outcome.id))
    }

    @Test("Un dossier qui contient la racine réelle des journaux est protégé")
    func protectsAncestorsOfRelocatedLogs() async throws {
        let home = try FakeHome()
        let fm = FileManager.default
        try home.file("Diagnostics/Logs/active.log")
        let ancestor = home.root.appendingPathComponent("Diagnostics")
        let physical = ancestor.appendingPathComponent("Logs")
        let logical = home.root.appendingPathComponent("Library/Logs")
        try fm.createDirectory(at: logical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: logical, withDestinationURL: physical)
        let trash = home.root.appendingPathComponent("_corbeille")
        let guardPaths = PathGuard(home: home.root)
        #expect(guardPaths.protectsUserLogs(ancestor))
        #expect(guardPaths.protectsUserLogs(home.root.appendingPathComponent("library")))
        #expect(!guardPaths.allows(ancestor))

        let item = CleanupItem(title: "Diagnostics", paths: [ancestor], category: .explorer,
                               owner: "", ruleID: "explorer.item", safety: .review, method: .trash, rebuild: .irreversible)
        let engine = CleanupEngine(trasher: FolderTrasher(folder: trash), history: nil, pathGuard: guardPaths,
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil })
        var report: CleanupReport?
        for await event in engine.run([item]) {
            if case .finished(let result) = event { report = result }
        }
        #expect(report?.outcomes.first?.result == .skipped(.refusedByGuard))
        #expect(fm.fileExists(atPath: logical.appendingPathComponent("active.log").path))
        #expect(!fm.fileExists(atPath: trash.path))
    }

    @Test("Un alias redirigé pendant la revalidation ne déplace aucun journal")
    func rejectsRetargetedAliasBeforeCleanup() async throws {
        let home = try FakeHome()
        let fm = FileManager.default
        try home.file("Ordinaire/active.log")
        try home.text("Library/Logs/Test/active.log", "journal protégé")
        let ordinary = home.root.appendingPathComponent("Ordinaire")
        let protected = home.root.appendingPathComponent("Library/Logs/Test")
        let alias = home.root.appendingPathComponent("alias")
        let replacement = home.root.appendingPathComponent("new-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: ordinary)
        try fm.createSymbolicLink(at: replacement, withDestinationURL: protected)
        let selected = alias.appendingPathComponent("active.log")
        let trash = home.root.appendingPathComponent("_corbeille")
        let guardPaths = PathGuard(home: home.root)
        #expect(guardPaths.allows(selected))

        let engine = CleanupEngine(trasher: FolderTrasher(folder: trash), history: nil, pathGuard: guardPaths,
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil },
                                   runningApps: {
            _ = rename(replacement.path, alias.path)
            return []
        })
        let item = CleanupItem(title: "active.log", paths: [selected], category: .explorer,
                               owner: "", ruleID: "explorer.item", safety: .review, method: .trash, rebuild: .irreversible)
        var report: CleanupReport?
        for await event in engine.run([item]) {
            if case .finished(let result) = event { report = result }
        }
        #expect(guardPaths.protectsUserLogs(selected))
        #expect(report?.outcomes.first?.result == .skipped(.refusedByGuard))
        #expect(fm.fileExists(atPath: ordinary.appendingPathComponent("active.log").path))
        #expect(try String(contentsOf: protected.appendingPathComponent("active.log"), encoding: .utf8) == "journal protégé")
        #expect(!fm.fileExists(atPath: trash.path))
    }

    @Test("Remettre reconnaît un alias même si le sous-dossier n'existe plus")
    func refusesRestoreThroughAliasWithMissingParents() async throws {
        let home = try FakeHome()
        let fm = FileManager.default
        try home.file("Library/Logs/sibling.log")
        try home.text("_corbeille/recovered.log", "journal fictif")
        let logs = home.root.appendingPathComponent("Library/Logs")
        let alias = home.root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: logs)
        let original = alias.appendingPathComponent("missing/nested/restored.log")
        let trashed = home.root.appendingPathComponent("_corbeille/recovered.log")
        let guardPaths = PathGuard(home: home.root)
        let item = CleanupItem(title: "restored.log", paths: [original], category: .explorer,
                               owner: "", ruleID: "explorer.item", safety: .review, method: .trash, rebuild: .irreversible)
        let outcome = CleanupOutcome(sessionID: UUID(), date: Date(), item: item, result: .trashed,
                                     bytes: 0, trashedTo: [trashed.path])
        let history = HistoryStore(directory: home.root.appendingPathComponent("_historique"))
        await #expect(throws: HistoryStore.RestoreError.notRestorable) {
            try await history.restore(outcome, pathGuard: guardPaths)
        }
        #expect(!fm.fileExists(atPath: logs.appendingPathComponent("missing").path))
        #expect(try String(contentsOf: trashed, encoding: .utf8) == "journal fictif")
    }

    @Test("Une rotation change l'identifiant même si le nouveau journal a le même âge")
    func selectionDoesNotFollowThePath() async throws {
        let home = try FakeHome()
        let now = Date()
        let old = now.addingTimeInterval(-31 * 86_400)
        try home.file("Library/Logs/rotated.log.1", modified: old)
        try home.file("Incoming/replacement.log", modified: old)
        let before = await RuleEngine.collect(home.context(now: now), finders: [.userLogs])
        let selected = try #require(before.first)
        let path = try #require(selected.paths.first)
        let fm = FileManager.default
        try fm.moveItem(at: path, to: home.root.appendingPathComponent("previous.log"))
        try fm.moveItem(at: home.root.appendingPathComponent("Incoming/replacement.log"), to: path)
        let after = await RuleEngine.collect(home.context(now: now), finders: [.userLogs])
        let replacement = try #require(after.first)
        #expect(replacement.paths == selected.paths)
        #expect(replacement.lastActivity == selected.lastActivity)
        #expect(replacement.id != selected.id)
    }

    @Test("La reprise réconcilie durablement un échec avec le journal retrouvé")
    func recoversInterruptedMoves() async throws {
        let home = try FakeHome()
        let now = Date()
        let fm = FileManager.default
        let trash = home.root.appendingPathComponent("_corbeille")
        try fm.createDirectory(at: trash, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let history = HistoryStore(directory: home.root.appendingPathComponent("_historique"))
        let engine = CleanupEngine(trasher: FolderTrasher(folder: trash), history: history,
                                   pathGuard: PathGuard(home: home.root), userLogTrashDirectory: trash)
        for completed in [false, true] {
            let name = completed ? "done.log" : "isolated.log"
            try home.file("Library/Logs/Test/\(name)", modified: now.addingTimeInterval(-31 * 86_400))
            let items = await RuleEngine.collect(home.context(now: now), finders: [.userLogs])
            let item = try #require(items.first { $0.title == name })
            let path = try #require(item.paths.first)
            let facts = try #require(FileFacts.of(path.path))
            let parent = try #require(FileFacts.of(path.deletingLastPathComponent().path))
            let destinationName = UUID().uuidString + ".log"
            let destination = trash.appendingPathComponent(destinationName)
            let recovery = home.root.appendingPathComponent(UserLogRecovery.prefix + UUID().uuidString)
            try fm.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var outcome = CleanupOutcome(sessionID: UUID(), date: now, item: item, result: .trashed,
                                         bytes: facts.size, trashedTo: [destination.path])
            outcome.userLogRestoreIdentity = .init(device: facts.device, inode: facts.inode, parentInode: parent.inode,
                                                   birthSeconds: facts.created.tv_sec, birthNanoseconds: facts.created.tv_nsec)
            let intent = UserLogRecovery(outcome: outcome, trashName: destinationName,
                                         device: facts.device, inode: facts.inode)
            let receipt = recovery.appendingPathComponent(UserLogRecovery.receiptName)
            let receiptData = try JSONEncoder().encode(intent)
            try receiptData.write(to: receipt)
            let actual = completed ? destination : recovery.appendingPathComponent(UserLogRecovery.stagedName)
            try fm.moveItem(at: path, to: actual)
            var earlier = outcome
            earlier.result = .failed(message: "logs.user.error.restore_conflict")
            earlier.bytes = 0
            earlier.trashedTo = []
            try await history.append(earlier)
            // Simuler un arrêt au milieu d'une écriture, sans saut de ligne final.
            let journal = history.directory.appendingPathComponent("history.jsonl")
            let handle = try FileHandle(forWritingTo: journal)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"sessionID\":".utf8))
            try handle.close()

            await engine.recoverUserLogs()
            let reconciledLines = try Data(contentsOf: journal)
            await engine.recoverUserLogs()
            #expect(try Data(contentsOf: journal) == reconciledLines)
            let entries = await HistoryStore(directory: history.directory).load()
            let reconciled = try #require(entries.first { $0.id == outcome.id })
            #expect(reconciled.paths == [path.path])
            #expect(entries.filter { $0.id == outcome.id }.count == 1)
            #expect(reconciled.trashedTo.map(PathNormalizer.normalize) == [PathNormalizer.normalize(actual.path)])
            #expect(reconciled.result == (completed ? .trashed : .failed(message: "logs.user.error.restore_conflict")))
            #expect(reconciled.userLogRestoreIdentity == outcome.userLogRestoreIdentity)
            #expect(try Data(contentsOf: receipt) == receiptData)

            // La reprise doit rendre le fichier visible sans tenter un nouveau renommage.
            await #expect(throws: HistoryStore.RestoreError.notRestorable) { try await history.restore(reconciled) }
            #expect(!fm.fileExists(atPath: path.path))
            #expect(FileFacts.of(actual.path)?.inode == facts.inode)
        }
    }

    @Test("Un reçu sans identité complète ou avec un autre inode reste disponible", arguments: [false, true])
    func keepsUnresolvedReceipt(identityMissing: Bool) async throws {
        let home = try FakeHome()
        let now = Date()
        try home.file("Library/Logs/test.log", modified: now.addingTimeInterval(-31 * 86_400))
        let fm = FileManager.default
        let item = try #require(await RuleEngine.collect(home.context(now: now), finders: [.userLogs]).first)
        let original = try #require(item.paths.first)
        let facts = try #require(FileFacts.of(original.path))
        let trash = home.root.appendingPathComponent("_corbeille")
        let recovery = home.root.appendingPathComponent(UserLogRecovery.prefix + UUID().uuidString)
        for directory in [trash, recovery] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let destination = trash.appendingPathComponent(UUID().uuidString + ".log")
        var outcome = CleanupOutcome(sessionID: UUID(), date: now, item: item, result: .trashed,
                                     bytes: facts.size, trashedTo: [destination.path])
        if !identityMissing {
            let parent = try #require(FileFacts.of(original.deletingLastPathComponent().path))
            outcome.userLogRestoreIdentity = .init(device: facts.device, inode: facts.inode, parentInode: parent.inode,
                                                   birthSeconds: facts.created.tv_sec, birthNanoseconds: facts.created.tv_nsec)
        }
        let receipt = recovery.appendingPathComponent(UserLogRecovery.receiptName)
        let receiptData = try JSONEncoder().encode(UserLogRecovery(outcome: outcome, trashName: destination.lastPathComponent,
                                                                   device: facts.device, inode: facts.inode))
        try receiptData.write(to: receipt)
        let expected: Data
        if identityMissing {
            expected = try Data(contentsOf: original)
            try fm.moveItem(at: original, to: destination)
        } else {
            try fm.moveItem(at: original, to: home.root.appendingPathComponent("original-isole.log"))
            expected = Data("substitut".utf8)
            try expected.write(to: destination)
        }
        let history = HistoryStore(directory: home.root.appendingPathComponent("_historique"))
        let engine = CleanupEngine(history: history, pathGuard: PathGuard(home: home.root), userLogTrashDirectory: trash)
        await engine.recoverUserLogs()
        #expect(await history.load().isEmpty)
        #expect(try Data(contentsOf: receipt) == receiptData)
        #expect(try Data(contentsOf: destination) == expected)
    }
}
