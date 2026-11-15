import Darwin
import Foundation
import SQLite3
import Testing
@testable import OustClean
import OustCore
import OustSafety

/// Un dossier temporaire à soi, avec sa propre « corbeille » et son propre
/// historique (RULES.md, règle 8).
final class Bench {
    let root: URL
    var trash: URL { root.appendingPathComponent("_corbeille") }
    var historyFolder: URL { root.appendingPathComponent("_historique") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-clean-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 10_000, byte: UInt8 = 1) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: byte, count: bytes).write(to: url)
        return url
    }

    func engine(processes: [ActiveProcess] = []) -> CleanupEngine {
        let snapshot = ProcessSnapshot(processes: processes)
        return CleanupEngine(
            trasher: FolderTrasher(folder: trash),
            history: HistoryStore(directory: historyFolder),
            pathGuard: PathGuard(home: root.appendingPathComponent("maison")),
            processes: { snapshot },
            capacity: { _ in nil },
            deleteSnapshots: { _ in false },
            allowsPathBasedRemoval: true
        )
    }

    func item(_ url: URL, method: CleanupMethod = .removeNow, safety: SafetyClass = .rebuilds,
              scope: URL? = nil) -> CleanupItem {
        var info = stat()
        lstat(url.path, &info)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return CleanupItem(title: url.lastPathComponent, paths: [url], category: .projectArtifacts, owner: "test",
                           ruleID: "artifact.node_modules", safety: safety, method: method,
                           sizes: Sizes(private: 10_000), rebuild: .automatic,
                           fingerprint: Fingerprint(modificationDate: modified, fileID: UInt64(info.st_ino)),
                           activityScope: scope)
    }

    func run(_ items: [CleanupItem], processes: [ActiveProcess] = []) async -> (events: [CleanupEvent], report: CleanupReport?) {
        var events: [CleanupEvent] = []
        var report: CleanupReport?
        for await event in engine(processes: processes).run(items) {
            events.append(event)
            if case .finished(let final) = event { report = final }
        }
        return (events, report)
    }
}

@Suite("Le nettoyage fait ce qu'il dit, et rien d'autre")
struct CleanupTests {
    private actor RefusedTrasher: Trasher {
        nonisolated let isAvailable = false
        private(set) var calls = 0

        func trash(_ urls: [URL]) async -> [Result<URL, TrashError>] {
            calls += 1
            return urls.map { _ in .failure(TrashError("Corbeille fictive appelée")) }
        }
    }

    @Test("Le veto Safari interdit le paquet et son contenu, même via les actions génériques")
    func incompleteSafariDownloadVeto() async throws {
        let bench = try Bench()
        let payload = try bench.file("Downloads/Installateur.dmg.DOWNLOAD/début.dmg")
        let bundle = payload.deletingLastPathComponent()
        let lookalike = try bench.file("Downloads/Installateur.download.dmg")
        let alias = bench.root.appendingPathComponent("Lien")
        let aliasToPayload = bench.root.appendingPathComponent("LienDirect")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bundle)
        try FileManager.default.createSymbolicLink(at: aliasToPayload, withDestinationURL: payload)
        let differentlyCased = bench.root.appendingPathComponent("dOWNLOADS")
        var paths = [bundle, payload, alias, aliasToPayload, alias.appendingPathComponent(payload.lastPathComponent), differentlyCased]
        let apfsSpelling = bench.root.appendingPathComponent("Downloadſ")
        if let equivalent = FileFacts.of(apfsSpelling.path),
           equivalent.inode == FileFacts.of(differentlyCased.path)?.inode {
            paths.append(apfsSpelling)
        }
        let pathGuard = PathGuard(home: bench.root)
        #expect(paths.allSatisfy { pathGuard.check($0) == .refused("safari-incomplete-download") })
        #expect(pathGuard.allows(lookalike))

        // La fausse Corbeille est volontairement disponible : le test doit
        // exercer le veto du chemin, en plus de l'interdiction de la fiche.
        let engine = CleanupEngine(trasher: FolderTrasher(folder: bench.trash), history: nil, pathGuard: pathGuard,
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil })
        #expect(engine.supports(.trash))
        let generic = paths.map { bench.item($0, method: .trash, safety: .review) }
        var forged = bench.item(lookalike, method: .trash, safety: .review)
        forged.ruleID = CleanupItem.incompleteSafariDownloadRuleID
        #expect(!forged.isSelectable)

        var report: CleanupReport?
        for await event in engine.run(generic + [forged]) {
            if case .finished(let final) = event { report = final }
        }
        #expect(report?.outcomes.count == generic.count)
        #expect(report?.outcomes.allSatisfy { $0.result == .skipped(.refusedByGuard) && $0.trashedTo.isEmpty } == true)
        #expect(report?.pendingInTrash == 0 && report?.expectedNow == 0)
        #expect(try Data(contentsOf: payload) == Data(repeating: 1, count: 10_000))
        #expect(try Data(contentsOf: lookalike) == Data(repeating: 1, count: 10_000))
    }

    @Test("Une redirection vers un paquet Safari après le premier contrôle bloque encore la Corbeille")
    func incompleteSafariDownloadVetoAfterRedirect() async throws {
        let bench = try Bench()
        let ordinary = try bench.file("Ordinaire/fichier", byte: 1)
        let partial = try bench.file("Downloads/Installateur.download/fichier", byte: 2)
        let link = bench.root.appendingPathComponent("Lien")
        let replacement = bench.root.appendingPathComponent("NouveauLien")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: link, withDestinationURL: ordinary.deletingLastPathComponent())
        try fm.createSymbolicLink(at: replacement, withDestinationURL: partial.deletingLastPathComponent())
        let selected = link.appendingPathComponent("fichier")
        let pathGuard = PathGuard(home: bench.root)
        #expect(pathGuard.allows(selected))
        let engine = CleanupEngine(trasher: FolderTrasher(folder: bench.trash), history: nil, pathGuard: pathGuard,
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil },
                                   runningApps: {
            _ = rename(replacement.path, link.path)
            return []
        })

        var report: CleanupReport?
        for await event in engine.run([bench.item(selected, method: .trash, safety: .review)]) {
            if case .finished(let final) = event { report = final }
        }
        #expect(pathGuard.check(selected) == .refused("safari-incomplete-download"))
        #expect(report?.outcomes.map(\.result) == [.skipped(.refusedByGuard)])
        #expect(report?.pendingInTrash == 0)
        #expect(try Data(contentsOf: partial) == Data(repeating: 2, count: 10_000))
        #expect(try Data(contentsOf: ordinary) == Data(repeating: 1, count: 10_000))
    }

    @Test("Les actions génériques refusent la Corbeille avant d'appeler le système")
    func genericTrashUnavailable() async throws {
        let bench = try Bench()
        let source = try bench.file("dossier/fichier.txt")
        let trasher = RefusedTrasher()
        #expect(!FinderTrasher().isAvailable)
        #expect(!FileManagerTrasher().isAvailable)
        let engine = CleanupEngine(trasher: trasher, history: nil, pathGuard: PathGuard(home: bench.root),
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil })
        let methods: [CleanupMethod] = [.trash, .archive(copy: bench.root.appendingPathComponent("copie").path),
                                        .trashFromCloud, .cloneOf(original: source.path), .compressInPlace]
        for method in methods {
            let item = CleanupItem(title: source.lastPathComponent, paths: [source], category: .explorer,
                                   owner: "", ruleID: "explorer.item", safety: .review, method: method,
                                   rebuild: .irreversible)
            var report: CleanupReport?
            for await event in engine.run([item]) {
                if case .finished(let result) = event { report = result }
            }
            #expect(report?.outcomes.map(\.result) == [.skipped(.refusedByGuard)])
            #expect(report?.outcomes.first?.trashedTo.isEmpty == true)
        }
        #expect(await trasher.calls == 0)
        #expect(try Data(contentsOf: source) == Data(repeating: 1, count: 10_000))
    }

    @Test("La suppression directe et le transit sont refusés, même pour un journal déjà dans la Corbeille",
          arguments: [false, true])
    func permanentRemovalUnavailable(withTransit: Bool) async throws {
        let bench = try Bench()
        let home = bench.root.appendingPathComponent("maison")
        let journal = try bench.file("maison/.Trash/recovered.log", byte: 7)
        let ordinary = try bench.file("maison/Caches/fichier.txt", byte: 9)
        let transitFolder = bench.root.appendingPathComponent("_transit")
        let engine = CleanupEngine(trasher: FolderTrasher(folder: bench.trash), history: nil,
                                   pathGuard: PathGuard(home: home), processes: { ProcessSnapshot(processes: []) },
                                   capacity: { _ in nil }, transit: withTransit ? Transit(directory: transitFolder) : nil)
        let trashItem = CleanupItem(title: "Corbeille", paths: [journal], category: .trash,
                                    owner: "", ruleID: "trash.contents", safety: .review,
                                    method: .removeNow, rebuild: .irreversible)
        var outcomes: [CleanupOutcome] = []
        for await event in engine.run([trashItem, bench.item(ordinary)]) {
            if case .itemFinished(let outcome) = event { outcomes.append(outcome) }
        }
        #expect(outcomes.map(\.result) == [.skipped(.refusedByGuard), .skipped(.refusedByGuard)])
        #expect(try Data(contentsOf: journal) == Data(repeating: 7, count: 10_000))
        #expect(try Data(contentsOf: ordinary) == Data(repeating: 9, count: 10_000))
        #expect(!FileManager.default.fileExists(atPath: transitFolder.path))
    }

    @Test("Le régénérable est supprimé, et l'historique le retient")
    func removeNow() async throws {
        let bench = try Bench()
        let folder = bench.root.appendingPathComponent("app/node_modules")
        try bench.file("app/node_modules/react/index.js")
        try bench.file("app/src/main.js")

        let (events, report) = await bench.run([bench.item(folder)])

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: bench.root.appendingPathComponent("app/src/main.js").path))
        #expect(report?.outcomes.map(\.result) == [.removed])
        #expect(report?.expectedNow == 10_000)
        let history = await HistoryStore(directory: bench.historyFolder).load()
        #expect(history.count == 1 && history[0].result == .removed)
        // Le récit au fil de l'eau : début, élément commencé, élément fini, bilan.
        guard case .began(let total, _) = events.first else { Issue.record("pas de début"); return }
        #expect(total == 1)
        #expect(events.filter { if case .itemFinished = $0 { true } else { false } }.count == 1)
    }

    @Test("Une ancienne entrée de Corbeille ordinaire reste consultable sans être restaurable")
    func genericRestoreUnavailable() async throws {
        let bench = try Bench()
        let film = try bench.file("Telechargements/film.mkv", bytes: 50_000)

        let (_, report) = await bench.run([bench.item(film, method: .trash, safety: .review)])
        let outcome = try #require(report?.outcomes.first)

        #expect(outcome.result == .trashed)
        #expect(!FileManager.default.fileExists(atPath: film.path))
        #expect(report?.pendingInTrash == 10_000)
        #expect(report?.expectedNow == 0)

        let store = HistoryStore(directory: bench.historyFolder)
        let trashed = URL(fileURLWithPath: try #require(outcome.trashedTo.first))
        try FileManager.default.removeItem(at: film.deletingLastPathComponent())
        await #expect(throws: HistoryStore.RestoreError.notRestorable) {
            try await store.restore(outcome)
        }
        #expect(!FileManager.default.fileExists(atPath: film.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: trashed) == Data(repeating: 1, count: 50_000))
        #expect(await store.load().map(\.id) == [outcome.id])
        #expect(await store.restoredIDs().isEmpty)
    }

    @Test("La restauration n'écrase jamais un fichier revenu à sa place")
    func restoreNeverOverwrites() async throws {
        let bench = try Bench()
        let file = try bench.file("doc.txt")
        let (_, report) = await bench.run([bench.item(file, method: .trash, safety: .review)])
        let outcome = try #require(report?.outcomes.first)
        try bench.file("doc.txt", byte: 9)

        await #expect(throws: HistoryStore.RestoreError.notRestorable) {
            try await HistoryStore(directory: bench.historyFolder).restore(outcome)
        }
        #expect(try Data(contentsOf: file) == Data(repeating: 9, count: 10_000))
    }

    @Test("Disparu, remplacé ou modifié depuis l'analyse : laissé en place")
    func revalidation() async throws {
        let bench = try Bench()
        let gone = try bench.file("disparu/a.bin")
        let goneItem = bench.item(gone)
        try FileManager.default.removeItem(at: gone)

        let replaced = try bench.file("remplace/a.bin")
        let replacedItem = bench.item(replaced)
        try FileManager.default.removeItem(at: replaced)
        try bench.file("remplace/a.bin", byte: 7)

        let edited = try bench.file("perso/lettre.txt")
        var editedItem = bench.item(edited, method: .trash, safety: .review)
        editedItem.fingerprint?.modificationDate = Date(timeIntervalSince1970: 1_000)

        let (_, report) = await bench.run([goneItem, replacedItem, editedItem])

        #expect(report?.outcomes.map(\.result) == [
            .skipped(.vanished), .skipped(.changedSinceScan), .skipped(.changedSinceScan),
        ])
        #expect(FileManager.default.fileExists(atPath: replaced.path))
        #expect(FileManager.default.fileExists(atPath: edited.path))
    }

    @Test("Un processus apparu depuis l'analyse protège le projet entier")
    func newlyBusy() async throws {
        let bench = try Bench()
        let project = bench.root.appendingPathComponent("projet")
        let folder = project.appendingPathComponent("apps/web/node_modules")
        try bench.file("projet/apps/web/node_modules/x.js")
        let agent = ActiveProcess(pid: 9, name: "codex", workingDirectory: project.path)

        let (_, report) = await bench.run([bench.item(folder, scope: project)], processes: [agent])

        #expect(report?.outcomes.first?.result == .skipped(.nowProtected(.activeProcess(name: "codex"))))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("La garde de chemins a le dernier mot")
    func guardRefuses() async throws {
        let bench = try Bench()
        let home = bench.root.appendingPathComponent("maison")
        try bench.file("maison/Library/fichier")
        let item = bench.item(home.appendingPathComponent("Library"))

        let (_, report) = await bench.run([item])

        #expect(report?.outcomes.first?.result == .skipped(.refusedByGuard))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library").path))
    }

    @Test("Un élément protégé n'est même pas tenté")
    func protectedNeverAttempted() async throws {
        let bench = try Bench()
        let file = try bench.file("garde.bin")
        var item = bench.item(file)
        item.protect(.inUse)

        let (_, report) = await bench.run([item])

        #expect(report?.outcomes.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Un worktree propre part par git, sa branche reste")
    func worktreeRemoval() async throws {
        let bench = try Bench()
        let repo = bench.root.appendingPathComponent("depot")
        try bench.file("depot/README.md")
        let env = ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null"]
        func git(_ args: String...) async -> CommandResult {
            await Command.run("/usr/bin/git", ["-C", repo.path] + args, environment: env)
        }
        _ = await git("init", "-q", "-b", "main")
        _ = await git("add", ".")
        _ = await git("commit", "-q", "-m", "init")
        let worktree = repo.appendingPathComponent(".claude/worktrees/agent-x")
        _ = await git("worktree", "add", "-q", "-b", "worktree-agent-x", worktree.path)

        let item = bench.item(worktree, method: .gitWorktreeRemove(repository: repo.path), safety: .safe)
        let (_, report) = await bench.run([item])

        #expect(report?.outcomes.first?.result == .delegated)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        let branches = await git("branch", "--list", "worktree-agent-x")
        #expect(branches.output.contains("worktree-agent-x"))
    }

    @Test("Le retrait par Git refuse un worktree qui contient Téléchargements redirigé")
    func worktreeKeepsRedirectedDownloads() async throws {
        let bench = try Bench()
        let repo = bench.root.appendingPathComponent("depot")
        try bench.file("depot/README.md")
        try Data("/Entrants/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        let env = ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null"]
        func git(_ args: String...) async -> CommandResult {
            await Command.run("/usr/bin/git", ["-C", repo.path] + args, environment: env)
        }
        try #require(await git("init", "-q", "-b", "main").succeeded)
        try #require(await git("add", ".").succeeded)
        try #require(await git("commit", "-q", "-m", "init").succeeded)
        let worktree = bench.root.appendingPathComponent("Worktree", isDirectory: true)
        try #require(await git("worktree", "add", "-q", "-b", "fixture-agent", worktree.path).succeeded)
        let payload = try bench.file("Worktree/Entrants/Archive.download/partiel")
        let home = bench.root.appendingPathComponent("maison", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: downloads, withDestinationURL: worktree.appendingPathComponent("Entrants"))
        let guardPaths = PathGuard(home: home)
        #expect(guardPaths.check(worktree) == .refused("safari-incomplete-download"))
        let alternate = bench.root.appendingPathComponent("wORKTREE")
        if FileFacts.of(alternate.path) != nil {
            #expect(guardPaths.check(alternate) == .refused("safari-incomplete-download"))
        }
        let state = try #require(await GitInspector.state(ofWorktree: worktree))
        #expect(state.uncommitted == 0 && state.uniqueSensitiveFiles.isEmpty)
        let item = bench.item(worktree, method: .gitWorktreeRemove(repository: repo.path), safety: .review)
        let (_, report) = await bench.run([item])
        #expect(report?.outcomes.map(\.result) == [.skipped(.refusedByGuard)])
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("Archive.download/partiel").path))
    }

    @Test("Une copie remplacée par un clone garde son contenu")
    func cloneReplacement() async throws {
        let bench = try Bench()
        let original = try bench.file("photos/original.jpg", bytes: 2_000_000, byte: 3)
        let copy = try bench.file("telechargements/copie.jpg", bytes: 2_000_000, byte: 3)

        let item = bench.item(copy, method: .cloneOf(original: original.path), safety: .review)
        let (_, report) = await bench.run([item])

        #expect(report?.outcomes.first?.result == .cloned)
        #expect(FileManager.default.contentsEqual(atPath: original.path, andPath: copy.path))
    }

    @Test("L'historique Firefox part, les favoris restent")
    func firefoxHistory() throws {
        let bench = try Bench()
        let path = bench.root.appendingPathComponent("places.sqlite").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        for statement in [
            "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER, last_visit_date INTEGER)",
            "CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER)",
            "CREATE TABLE moz_inputhistory (place_id INTEGER, input TEXT)",
            "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, fk INTEGER)",
            "INSERT INTO moz_places VALUES (1, 'https://favori.fr', 3, 1), (2, 'https://visite.fr', 5, 2)",
            "INSERT INTO moz_historyvisits VALUES (1, 1), (2, 2)",
            "INSERT INTO moz_bookmarks VALUES (1, 1)",
        ] { sqlite3_exec(db, statement, nil, nil, nil) }
        sqlite3_close(db)

        #expect(ToolActions.clearFirefoxHistory(database: path) == nil)

        sqlite3_open(path, &db)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT url FROM moz_places", -1, &statement, nil)
        var urls: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { urls.append(String(cString: sqlite3_column_text(statement, 0))) }
        sqlite3_finalize(statement)
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM moz_historyvisits", -1, &statement, nil)
        sqlite3_step(statement)
        let visits = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)
        sqlite3_close(db)

        #expect(urls == ["https://favori.fr"])
        #expect(visits == 0)
    }
}

/// Un faux disque externe : la corbeille du disque se vide, ce qui reste
/// protégé ne part pas (RULES.md, règle 8 : tout dans le dossier du test).
@Suite("Nettoyer un autre disque")
struct VolumeCleanupTests {

    private func engine(_ bench: Bench, volume: URL) -> CleanupEngine {
        CleanupEngine(trasher: FolderTrasher(folder: bench.trash), history: HistoryStore(directory: bench.historyFolder),
                      pathGuard: PathGuard(home: bench.root.appendingPathComponent("maison"), otherVolumeRoots: [volume]),
                      processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil }, deleteSnapshots: { _ in false },
                      allowsPathBasedRemoval: true)
    }

    @Test("Vider la corbeille du disque efface son contenu, jamais le dossier .Trashes/<uid>")
    func emptiesVolumeTrash() async throws {
        let bench = try Bench()
        let volume = bench.root.appendingPathComponent("Disque")
        let trash = volume.appendingPathComponent(".Trashes/\(getuid())")
        let film = try bench.file("Disque/.Trashes/\(getuid())/vieux film.mov")
        try bench.file("Disque/.Trashes/\(getuid())/dossier/a.txt")
        let item = CleanupItem(id: "trash|\(trash.path)", title: "Disque", paths: [film, trash.appendingPathComponent("dossier")],
                               category: .trash, owner: "Finder", ruleID: "trash.volume", safety: .review,
                               method: .removeNow, rebuild: .irreversible)

        var outcomes: [CleanupOutcome] = []
        for await event in engine(bench, volume: volume).run([item]) {
            if case .itemFinished(let outcome) = event { outcomes.append(outcome) }
        }

        #expect(outcomes.first?.result == .removed)
        #expect(FileManager.default.fileExists(atPath: trash.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: trash.path))?.isEmpty == true)
    }

    @Test("La garde arrête ce qui viserait une sauvegarde, une photothèque ou une machine virtuelle")
    func guardStopsProtected() async throws {
        let bench = try Bench()
        let volume = bench.root.appendingPathComponent("Disque")
        let targets = [
            try bench.file("Disque/Backups.backupdb/Mac/2026-10-01-101500/x.dmg"),
            try bench.file("Disque/Famille.photoslibrary/originals/IMG.heic"),
            try bench.file("Disque/VM/Windows.utm/Data/disk.qcow2"),
        ]
        let items = targets.map { bench.item($0) }

        var outcomes: [CleanupOutcome] = []
        for await event in engine(bench, volume: volume).run(items) {
            if case .itemFinished(let outcome) = event { outcomes.append(outcome) }
        }

        #expect(outcomes.count == 3)
        #expect(outcomes.allSatisfy { $0.result == .skipped(.refusedByGuard) })
        #expect(targets.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("Le disque de démarrage n'est compté qu'une fois, sous ses deux noms")
    func volumesCountedOnce() throws {
        let bench = try Bench()
        let file = try bench.file("cache/a.bin")
        let cache = bench.item(file)
        let snapshot = CleanupItem(title: "snapshot", paths: [], category: .snapshots, owner: "Time Machine",
                                   ruleID: "snapshot.time_machine", safety: .review,
                                   method: .localSnapshot(date: "2026-10-18-101500"), rebuild: .irreversible)
        let volumes = CleanupEngine.volumes(of: [cache, snapshot])
        #expect(volumes.count == 1)
        #expect(CleanupEngine.available(on: volumes + volumes, capacity: { _ in
            Capacity(total: 100, available: 10, availableForImportantUsage: 10) }) == 20)
    }
}
