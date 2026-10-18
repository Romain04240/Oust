import Foundation
import Testing
@testable import OustSafety
import OustCore

/// Un dossier temporaire à soi (voir RULES.md, règle 8).
final class Scratch {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-safety-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ relative: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ arguments: String..., in directory: URL? = nil) async -> CommandResult {
        await Command.run("/usr/bin/git", ["-C", (directory ?? root).path] + arguments,
                          environment: ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                                        "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null"])
    }
}

@Suite("La garde de chemins refuse l'irréparable")
struct PathGuardTests {
    let home = URL(fileURLWithPath: "/Home/test")

    @Test("Racines et zones protégées", arguments: [
        "/", "/System", "/System/Library/CoreServices", "/Library/Preferences", "/Applications",
        "/Home/test", "/Home/test/Library", "/Home/test/Library/Caches", "/Home/test/Downloads",
        "/Home/test/Library/Keychains/login.keychain-db", "/Home/test/Library/Mobile Documents/x",
        "/Home/test/Pictures/Photos Library.photoslibrary/originals", "/Home/test/.ssh/id_rsa",
        "/Home/test/.claude.json", "/Home/test/.codex/auth.json", "/usr/bin/git",
        "/System/Volumes/Data/Home/test/Library",
    ])
    func refuses(path: String) {
        let guardian = PathGuard(home: home)
        #expect(guardian.allows(URL(fileURLWithPath: path)) == false)
    }

    @Test("Ce qu'Oust! nettoie réellement", arguments: [
        "/Home/test/Library/Caches/pip", "/Home/test/Developpement/app/node_modules",
        "/Home/test/Library/Developer/Xcode/DerivedData/App-abc", "/Home/test/.cache/huggingface/hub/models--x",
        "/Home/test/Downloads/film.mkv", "/Applications/Jeu.app", "/Home/test/.codex/sessions/2026/09",
    ])
    func allows(path: String) {
        let guardian = PathGuard(home: home)
        #expect(guardian.allows(URL(fileURLWithPath: path)))
    }

    @Test("Un chemin relatif ou avec .. est refusé")
    func refusesTraversal() {
        let guardian = PathGuard(home: home)
        #expect(guardian.check(URL(fileURLWithPath: "/Home/test/Developpement/../Library")) != .allowed)
    }
}

@Suite("Les processus actifs protègent leur dossier")
struct ProcessTests {
    @Test("Le test lui-même travaille quelque part")
    func currentProcessHasDirectory() {
        let snapshot = ProcessSnapshot.current()
        #expect(!snapshot.processes.isEmpty)
    }

    @Test("Un dossier est occupé si un processus y travaille, ou plus bas")
    func busyUnder() {
        let snapshot = ProcessSnapshot(processes: [
            ActiveProcess(pid: 1, name: "claude", workingDirectory: "/Home/test/Dev/app/sous-dossier"),
        ])
        #expect(snapshot.busy(under: "/Home/test/Dev/app")?.name == "claude")
        #expect(snapshot.busy(under: "/System/Volumes/Data/Home/test/Dev/app")?.name == "claude")
        #expect(snapshot.busy(under: "/Home/test/Dev/application") == nil)
        #expect(snapshot.busy(under: "/Home/test/Dev/autre") == nil)
    }
}

@Suite("Git dit ce qu'un worktree emporterait")
struct GitTests {

    @Test("Fichiers sensibles", arguments: [
        (".env", true), (".env.local", true), (".env.example", false), ("cles/serveur.pem", true),
        ("data/dev.sqlite", true), ("solana-keypair.json", true), ("node_modules/", false), ("README.md", false),
    ])
    func sensitive(path: String, expected: Bool) {
        #expect(GitInspector.isSensitive(path) == expected)
    }

    @Test("Lecture de git worktree list")
    func parseList() {
        let output = """
        worktree /r/main
        HEAD aaa
        branch refs/heads/main

        worktree /r/main/.claude/worktrees/a
        HEAD bbb
        branch refs/heads/worktree-a
        locked

        """
        let list = GitInspector.parseWorktreeList(output)
        #expect(list.count == 2)
        #expect(list[0].isMain && list[0].branch == "main")
        #expect(list[1].isLocked && list[1].branch == "worktree-a" && !list[1].isMain)
    }

    @Test("Un worktree propre et fusionné, puis modifié, puis avec un secret")
    func worktreeStates() async throws {
        let scratch = try Scratch()
        let repo = scratch.root.appendingPathComponent("depot")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        await scratch.git("init", "-q", "-b", "main", in: repo)
        try scratch.write("depot/README.md", "bonjour")
        try scratch.write("depot/.gitignore", ".env\nnode_modules/\n")
        await scratch.git("add", ".", in: repo)
        await scratch.git("commit", "-q", "-m", "init", in: repo)

        let worktree = repo.appendingPathComponent(".claude/worktrees/agent-1")
        await scratch.git("worktree", "add", "-q", "-b", "worktree-agent-1", worktree.path, in: repo)

        #expect(GitInspector.mainRepository(ofWorktree: worktree)?.resolvingSymlinksInPath().path
                == repo.resolvingSymlinksInPath().path)

        var state = try #require(await GitInspector.state(ofWorktree: worktree))
        #expect(state.uncommitted == 0)
        #expect(state.isMerged == true)
        #expect(state.uniqueSensitiveFiles.isEmpty)

        // Un fichier non suivi : git worktree remove refuserait, on protège.
        try scratch.write("depot/.claude/worktrees/agent-1/nouveau.swift", "let x = 1")
        state = try #require(await GitInspector.state(ofWorktree: worktree))
        #expect(state.uncommitted == 1)

        // Un .env ignoré qui n'existe pas dans le dépôt principal : unique.
        try scratch.write("depot/.claude/worktrees/agent-1/.env", "CLE=secrete")
        state = try #require(await GitInspector.state(ofWorktree: worktree))
        #expect(state.uniqueSensitiveFiles == [".env"])

        // Le même .env dans le dépôt principal : plus unique.
        try scratch.write("depot/.env", "CLE=secrete")
        state = try #require(await GitInspector.state(ofWorktree: worktree))
        #expect(state.uniqueSensitiveFiles.isEmpty)

        // Un commit propre au worktree : plus fusionné.
        await scratch.git("add", "nouveau.swift", in: worktree)
        await scratch.git("commit", "-q", "-m", "travail", in: worktree)
        state = try #require(await GitInspector.state(ofWorktree: worktree))
        #expect(state.isMerged == false)
        #expect(state.branch == "worktree-agent-1")
    }

    @Test("Un dossier versionné n'est pas un artefact")
    func trackedFiles() async throws {
        let scratch = try Scratch()
        await scratch.git("init", "-q", "-b", "main")
        try scratch.write("dist/index.html", "<p>publié</p>")
        try scratch.write("build/sortie.o", "binaire")
        try scratch.write(".gitignore", "build/\n")
        await scratch.git("add", ".")
        await scratch.git("commit", "-q", "-m", "init")

        let dist = await GitInspector.containsTrackedFiles(scratch.root.appendingPathComponent("dist"), repository: scratch.root)
        let build = await GitInspector.containsTrackedFiles(scratch.root.appendingPathComponent("build"), repository: scratch.root)
        #expect(dist == true)
        #expect(build == false)
    }
}

@Suite("Mail et Messages : seules les pièces jointes")
struct AttachmentGuardTests {
    let guardian = PathGuard(home: URL(fileURLWithPath: "/Home/test"))

    @Test("Une pièce jointe passe", arguments: [
        "/Home/test/Library/Messages/Attachments/ab/01/GUID-1",
        "/Home/test/Library/Mail/V10/ACCOUNT/INBOX.mbox/UUID/Data/1/2/Attachments/1234",
    ])
    func allowsAttachments(path: String) {
        #expect(guardian.allows(URL(fileURLWithPath: path)))
    }

    @Test("Le reste de Mail et de Messages reste refusé", arguments: [
        "/Home/test/Library/Messages/Attachments", "/Home/test/Library/Messages/chat.db",
        "/Home/test/Library/Mail/V10/MailData/Envelope Index",
        "/Home/test/Library/Mail/V10/ACCOUNT/INBOX.mbox/UUID/Data/1/2/Messages/1234.emlx",
        "/Home/test/Library/Mail/V10/ACCOUNT/INBOX.mbox/UUID/Data/1/2/Attachments",
        "/Home/test/Library/Mail/Attachments/x", "/Home/test/Library/Mail/Vrac/a/b/Attachments/x",
    ])
    func refusesTheRest(path: String) {
        #expect(!guardian.allows(URL(fileURLWithPath: path)))
    }
}

@Suite("Ce qu'on sait d'un fichier avant de le réécrire")
struct FileFactsTests {
    @Test("Taille, liens, clones")
    func facts() throws {
        let scratch = try Scratch()
        try scratch.write("a.txt", String(repeating: "x", count: 20_000))
        let path = scratch.root.appendingPathComponent("a.txt").path
        let facts = try #require(FileFacts.of(path))
        #expect(facts.isRegularFile && facts.size == 20_000 && facts.linkCount == 1)
        #expect(!facts.isCompressed && !facts.isLocked)
        #expect(!FileFacts.mayShareBlocks(path))
        let clone = scratch.root.appendingPathComponent("b.txt").path
        #expect(clonefile(path, clone, 0) == 0)
        #expect(FileFacts.mayShareBlocks(clone))
        #expect(FileFacts.of(scratch.root.appendingPathComponent("absent").path) == nil)
    }
}
