import Darwin
import Foundation
import Testing
@testable import OustRules
import OustCore
import OustSafety
import OustScan

/// Un faux dossier personnel dans un dossier temporaire : les chercheurs n'y
/// voient que du feu (RULES.md, règle 8).
final class FakeHome {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-home-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ relative: String, bytes: Int = 50_000, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    func text(_ relative: String, _ content: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Rien de la machine ne passe : ni ses applications, ni ses outils, ni ce
    /// qui tourne. Tout ce qu'un chercheur voit est fabriqué par le test.
    func context(processes: [ActiveProcess] = [], now: Date = Date(), tools: ToolRunner = .none,
                 runningApps: Set<String> = []) -> RuleContext {
        RuleContext(home: root, projectRoots: [root.appendingPathComponent("Developpement")],
                    processes: ProcessSnapshot(processes: processes), now: now,
                    applications: root.appendingPathComponent("_Applications"),
                    systemLibrary: root.appendingPathComponent("_Library"),
                    sharedFolder: root.appendingPathComponent("_Shared"),
                    temporaryDirectory: root.appendingPathComponent("_tmp"),
                    tools: tools, runningApps: runningApps, applicationName: { _ in nil })
    }
}

@Suite("Les artefacts de projets")
struct ProjectArtifactsTests {

    @Test("node_modules et .build reconnus par leur marqueur, rien d'autre")
    func recognizesArtifacts() async throws {
        let home = try FakeHome()
        try home.text("Developpement/web/package.json", "{}")
        try home.text("Developpement/web/pnpm-lock.yaml", "")
        try home.file("Developpement/web/node_modules/react/index.js")
        try home.text("Developpement/kit/Package.swift", "// swift")
        try home.file("Developpement/kit/.build/debug/kit.o")
        // Un dossier node_modules sans package.json n'est pas un artefact reconnu.
        try home.file("Developpement/divers/node_modules/x.js")

        let items = await RuleEngine.collect(home.context(), finders: [.projectArtifacts])

        let node = try #require(items.first { $0.title == "node_modules" && $0.owner == "web" })
        #expect(node.ruleID == "artifact.node_modules")
        #expect(node.rebuild == .command("pnpm install", minutes: 2))
        #expect(node.method == .removeNow)
        #expect(node.sizes.allocated > 0)
        #expect(items.contains { $0.title == ".build" && $0.owner == "kit" })
        #expect(!items.contains { $0.owner == "divers" })
    }

    @Test("Un processus dans le projet protège ses artefacts")
    func activeProcessProtects() async throws {
        let home = try FakeHome()
        try home.text("Developpement/app/package.json", "{}")
        try home.file("Developpement/app/node_modules/a.js")
        let busy = ActiveProcess(pid: 42, name: "claude", workingDirectory: home.root.path + "/Developpement/app")

        let items = await RuleEngine.collect(home.context(processes: [busy]), finders: [.projectArtifacts])
        let item = try #require(items.first)

        #expect(item.safety == .protected)
        #expect(item.protections == [.activeProcess(name: "claude")])
        #expect(!item.isSelectable)
    }

    @Test("Les __pycache__ d'un projet sont regroupés en un seul élément")
    func pycacheGrouped() async throws {
        let home = try FakeHome()
        try home.text("Developpement/outil/pyproject.toml", "")
        try home.file("Developpement/outil/src/a/__pycache__/a.pyc")
        try home.file("Developpement/outil/src/b/__pycache__/b.pyc")

        let items = await RuleEngine.collect(home.context(), finders: [.projectArtifacts])
        let item = try #require(items.first { $0.ruleID == "artifact.pycache" })

        #expect(item.paths.count == 2)
        #expect(item.safety == .safe)
    }

    @Test("Un dist versionné n'est pas proposé, un dist ignoré l'est")
    func ambiguousNames() async throws {
        let home = try FakeHome()
        let project = home.root.appendingPathComponent("Developpement/site")
        try home.text("Developpement/site/package.json", "{}")
        try home.text("Developpement/site/dist/index.html", "<p>publié</p>")
        try home.file("Developpement/site/build/bundle.js")
        try home.text("Developpement/site/.gitignore", "build/\n")
        let env = ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null"]
        _ = await Command.run("/usr/bin/git", ["-C", project.path, "init", "-q"], environment: env)
        _ = await Command.run("/usr/bin/git", ["-C", project.path, "add", "."], environment: env)
        _ = await Command.run("/usr/bin/git", ["-C", project.path, "commit", "-q", "-m", "x"], environment: env)

        let items = await RuleEngine.collect(home.context(), finders: [.projectArtifacts])

        #expect(items.contains { $0.title == "build" })
        #expect(!items.contains { $0.title == "dist" })
    }
}

@Suite("Les traces des agents")
struct AgentTests {

    @Test("Downloads redirigé protège le worktree avant la mesure ou pendant celle-ci", arguments: [false, true])
    func worktreeWithDownloadsHasNoGain(redirectDuringMeasurement: Bool) async throws {
        let home = try FakeHome()
        let repo = home.root.appendingPathComponent("Depot", isDirectory: true)
        try home.text("Depot/.gitignore", "/Entrants/\n")
        try home.text("Depot/README", "Fichier suivi")
        let env = ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null"]
        func git(_ args: String...) async -> CommandResult {
            await Command.run("/usr/bin/git", ["-C", repo.path] + args, environment: env)
        }
        try #require(await git("init", "-q", "-b", "main").succeeded)
        try #require(await git("add", ".").succeeded)
        try #require(await git("commit", "-q", "-m", "init").succeeded)
        let worktrees = home.root.appendingPathComponent(".codex/worktrees", isDirectory: true)
        let protected = worktrees.appendingPathComponent("Protege")
        let ordinary = worktrees.appendingPathComponent("Ordinaire")
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        try #require(await git("worktree", "add", "-q", "-b", "protege", protected.path).succeeded)
        try #require(await git("worktree", "add", "-q", "-b", "ordinaire", ordinary.path).succeeded)
        try home.file(".codex/worktrees/Protege/Entrants/Archive.download/partiel")
        let downloads = home.root.appendingPathComponent("Downloads")
        let replacement = home.root.appendingPathComponent("NouveauDownloads")
        let destination = protected.appendingPathComponent("Entrants")
        let fm = FileManager.default
        if redirectDuringMeasurement {
            let original = home.root.appendingPathComponent("DownloadsOriginal")
            try fm.createDirectory(at: original, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: downloads, withDestinationURL: original)
            try fm.createSymbolicLink(at: replacement, withDestinationURL: destination)
        } else {
            try fm.createSymbolicLink(at: downloads, withDestinationURL: destination)
        }
        let context = home.context(now: Date().addingTimeInterval(2 * 86_400))
        let items = await RuleEngine.collect(context, finders: [.agents], measurer: Measurer { urls in
            let worktree = urls.first { $0.lastPathComponent == "Protege" }
            if redirectDuringMeasurement {
                #expect(worktree != nil)
                #expect(rename(replacement.path, downloads.path) == 0)
            } else {
                #expect(worktree == nil)
            }
            let measured = await Scanner.measure(urls)
            if let worktree { #expect((measured[worktree]?.sizes.freeable ?? 0) > 0) }
            return measured
        })
        let locked = try #require(items.first { $0.title == "Protege" })
        let available = try #require(items.first { $0.title == "Ordinaire" })
        #expect(locked.protections == [.systemPath] && locked.sizes.freeable == 0)
        #expect(!locked.isSelectable && !PreselectionPolicy().preselects(locked, now: context.now))
        #expect(available.isSelectable && available.sizes.freeable > 0)
        #expect(PreselectionPolicy().preselects(available, now: context.now))
    }

    @Test("Les historiques Claude anciens sont proposés, les récents jamais")
    func claudeHistory() async throws {
        let home = try FakeHome()
        let old = Date().addingTimeInterval(-60 * 86_400)
        let project = home.root.appendingPathComponent("Developpement/vivant")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let line = "{\"cwd\":\"\(project.path)\",\"type\":\"user\"}\n"
        try home.text(".claude/projects/p/ancienne.jsonl", line)
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: home.root.appendingPathComponent(".claude/projects/p/ancienne.jsonl").path)
        try home.text(".claude/projects/p/en-cours.jsonl", line)

        let items = await RuleEngine.collect(home.context(), finders: [.agents])
        let item = try #require(items.first { $0.ruleID == "agent.claude_history" })

        #expect(item.title == "vivant")
        #expect(item.paths.map(\.lastPathComponent) == ["ancienne.jsonl"])
        #expect(item.method == .trash)
        #expect(item.safety == .review)
    }

    @Test("Le dossier de travail d'une session est lu dans le JSON")
    func workingDirectory() throws {
        let home = try FakeHome()
        try home.text("s.jsonl", "{\"type\":\"summary\"}\n{\"cwd\":\"/projets/app\",\"type\":\"user\"}\n")
        #expect(AgentFinder.workingDirectory(ofSession: home.root.appendingPathComponent("s.jsonl")) == "/projets/app")
    }

    @Test("Un dossier de travail Codex modifié aujourd'hui est protégé")
    func codexWorkspace() async throws {
        let home = try FakeHome()
        try home.file(".codex/qrissimo-staging/build.zip", bytes: 200_000)
        try home.text(".codex/auth.json", "{}")
        try home.file(".codex/sessions/2026/01/02/rollout.jsonl", bytes: 1_000,
                      modified: Date().addingTimeInterval(-90 * 86_400))

        let items = await RuleEngine.collect(home.context(), finders: [.agents])

        let staging = try #require(items.first { $0.ruleID == "agent.codex_workspace" })
        #expect(staging.protections.contains(.inUse))
        #expect(items.contains { $0.ruleID == "agent.codex_sessions" && $0.title == "2026-01" })
        #expect(!items.contains { $0.paths.contains { $0.lastPathComponent == "auth.json" } })
    }
}

@Suite("Caches, modèles et contenu")
struct ContentTests {

    @Test("Les caches de paquets présents sont trouvés")
    func packageCaches() async throws {
        let home = try FakeHome()
        try home.file(".npm/_cacache/content-v2/a")
        try home.file("Library/Caches/pip/http/b")

        let items = await RuleEngine.collect(home.context(), finders: [.packageCaches])

        #expect(Set(items.map(\.ruleID)) == ["cache.npm", "cache.pip"])
        #expect(items.allSatisfy { $0.safety == .safe && $0.method == .removeNow })
    }

    @Test("Les modèles sont toujours à examiner, jamais présélectionnés")
    func models() async throws {
        let home = try FakeHome()
        try home.file(".cache/huggingface/hub/models--mlx-community--Qwen3-4B/blobs/abc", bytes: 300_000)
        try home.file("Library/Application Support/com.exemple.dictee/models/whisper.bin", bytes: 300_000)

        let items = await RuleEngine.collect(home.context(), finders: [.models])

        let qwen = try #require(items.first { $0.ruleID == "model.huggingface" })
        #expect(qwen.title == "mlx-community/Qwen3-4B")
        #expect(items.contains { $0.ruleID == "model.app_models" && $0.title == "com.exemple.dictee" })
        #expect(items.allSatisfy { !PreselectionPolicy().preselects($0) })
    }

    @Test("Téléchargements : installeurs et gros fichiers anciens")
    func downloads() async throws {
        let home = try FakeHome()
        try home.file("Downloads/Outil.dmg", bytes: 11_000_000)
        try home.file("Downloads/film.mkv", bytes: 600_000, modified: Date().addingTimeInterval(-60 * 86_400))
        try home.file("Downloads/recent.mkv", bytes: 600_000)
        var context = home.context()
        context.largeDownloadBytes = 500_000

        let items = await RuleEngine.collect(context, finders: [.userContent])

        #expect(items.contains { $0.ruleID == "downloads.installer" && $0.title == "Outil.dmg" })
        #expect(items.contains { $0.ruleID == "downloads.large" && $0.title == "film.mkv" })
        #expect(!items.contains { $0.title == "recent.mkv" })
    }

    @Test("Les paquets Safari récents et anciens restent visibles sans gain ni sélection", arguments: [false, true])
    func incompleteSafariDownloads(safariRunning: Bool) async throws {
        let home = try FakeHome()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let old = now.addingTimeInterval(-60 * 86_400)
        let recent = now.addingTimeInterval(-60)
        let fm = FileManager.default
        let active = home.root.appendingPathComponent("Downloads/En cours.zip.download", isDirectory: true)
        let partial = active.appendingPathComponent("En cours.zip")
        try home.file("Downloads/En cours.zip.download/En cours.zip", bytes: 220_000, modified: recent)
        try home.file("Downloads/Interrompu.pdf.DOWNLOAD/Interrompu.pdf", bytes: 150_000, modified: old)
        try home.setModified("Downloads/En cours.zip.download", recent)
        try home.setModified("Downloads/Interrompu.pdf.DOWNLOAD", old)
        try fm.createDirectory(at: home.root.appendingPathComponent("Downloads/Vide.download"), withIntermediateDirectories: true)
        try home.file("Downloads/Rapport.download.pdf", bytes: 80_000, modified: old)
        try home.file("Downloads/Ordinaire.download", bytes: 80_000, modified: old)
        try home.file("Autre/Hors dossier.download/data", bytes: 80_000, modified: old)
        try fm.createSymbolicLink(at: home.root.appendingPathComponent("Downloads/Lien.download"),
                                  withDestinationURL: home.root.appendingPathComponent("Autre/Hors dossier.download"))
        let activeFile = try FileHandle(forUpdating: partial)
        defer { try? activeFile.close() }
        var context = home.context(now: now, runningApps: safariRunning ? ["com.apple.Safari"] : [])
        context.largeDownloadBytes = 10_000

        let items = await RuleEngine.collect(context, finders: [.userContent])
        let safari = items.filter(\.isIncompleteSafariDownload)
        #expect(Set(safari.map(\.title)) == ["En cours.zip.download", "Interrompu.pdf.DOWNLOAD", "Vide.download"])
        #expect(safari.allSatisfy { $0.category == .downloads && $0.safety == .protected && $0.method == .manual })
        #expect(safari.allSatisfy { $0.sizes.freeable == 0 && !$0.isSelectable && !PreselectionPolicy().preselects($0, now: now) })
        #expect(safari.allSatisfy { !$0.notes.contains(.partlyShared) })
        let activeItem = try #require(safari.first { $0.title == "En cours.zip.download" })
        let oldItem = try #require(safari.first { $0.title == "Interrompu.pdf.DOWNLOAD" })
        #expect(activeItem.paths.map { PathNormalizer.normalize($0.path) } == [PathNormalizer.normalize(active.path)])
        #expect(activeItem.lastActivity == recent && oldItem.lastActivity == old)
        #expect(activeItem.sizes.allocated >= 220_000 && oldItem.sizes.allocated >= 150_000)
        #expect(items.filter { !$0.isIncompleteSafariDownload }.map(\.title) == ["Rapport.download.pdf"])
        #expect(try Data(contentsOf: partial) == Data(repeating: 0x42, count: 220_000))
    }

    @Test("Un dossier Téléchargements redirigé ne produit aucun paquet Safari")
    func skipsRedirectedSafariDownloads() async throws {
        let home = try FakeHome()
        try home.file("Autre/Redirected.download/data")
        try FileManager.default.createSymbolicLink(at: home.root.appendingPathComponent("Downloads"),
                                                   withDestinationURL: home.root.appendingPathComponent("Autre"))

        let items = await RuleEngine.collect(home.context(), finders: [.userContent])
        #expect(items.allSatisfy { !$0.isIncompleteSafariDownload })
    }

    @Test("La mesure Safari ignore une redirection, même si le dossier d'origine revient", arguments: [false, true])
    func safariMeasureAfterRedirect(restoreOriginal: Bool) async throws {
        let home = try FakeHome()
        try home.file("Downloads/Archive.download/original", bytes: 220_000)
        try home.file("Autre/Archive.download/remplacement", bytes: 600_000)
        let downloads = home.root.appendingPathComponent("Downloads")
        let original = home.root.appendingPathComponent("Downloads-original")
        let other = home.root.appendingPathComponent("Autre")
        let items = await RuleEngine.collect(home.context(), finders: [.userContent], measurer: Measurer { urls in
            let fm = FileManager.default
            do {
                try fm.moveItem(at: downloads, to: original)
                try fm.createSymbolicLink(at: downloads, withDestinationURL: other)
                let measured = await Scanner.measure(urls)
                #expect(measured.values.first?.sizes.allocated ?? 0 >= 600_000)
                if restoreOriginal {
                    try fm.removeItem(at: downloads)
                    try fm.moveItem(at: original, to: downloads)
                }
                return measured
            } catch {
                Issue.record("Redirection du dossier fictif impossible : \(error)")
                return [:]
            }
        })
        let safari = items.filter(\.isIncompleteSafariDownload)
        if restoreOriginal {
            #expect(safari.count == 1 && safari.first?.sizes == .zero)
        } else {
            #expect(safari.isEmpty)
        }
    }

    @Test("La compression laisse les paquets Safari de côté, à la racine et dans un projet")
    func compressionSkipsSafariDownloads() async throws {
        let home = try FakeHome()
        let old = Date().addingTimeInterval(-400 * 86_400)
        try home.file("Downloads/Racine.DOWNLOAD/payload.txt", bytes: 14_000_000, modified: old)
        try home.file("Downloads/Projet/Alias.download/payload.txt", bytes: 14_000_000, modified: old)
        try home.setModified("Downloads/Projet/Alias.download", old)
        try home.file("Downloads/Ordinaire/payload.txt", bytes: 14_000_000, modified: old)
        var context = home.context()
        context.projectRoots = [home.root.appendingPathComponent("Downloads")]
        let items = await RuleEngine.collect(context, finders: [.compression])
        #expect(items.map(\.title) == ["Ordinaire"])
        #expect(items.first?.sizes.freeable ?? 0 > 10_000_000)
    }

    @Test("Les VM sont gérées à part, hors du total en titre")
    func virtualMachines() async throws {
        let home = try FakeHome()
        try home.file("Virtual Machines.localized/Windows.vmwarevm/disk.vmdk", bytes: 400_000)

        let items = await RuleEngine.collect(home.context(), finders: [.userContent])
        let vm = try #require(items.first { $0.ruleID == "vm.image" })

        #expect(!vm.countsInHeadline)
    }

    @Test("DeviceSupport : la version la plus récente est gardée")
    func deviceSupportVersions() {
        #expect(XcodeFinder.version(in: "iPhone18,2 27.0.1 (24A446)") == [27, 0, 1])
        #expect(XcodeFinder.version(in: "26.4 (23E120) arm64e") == [26, 4, 0])
    }
}

@Suite("Un projet occupé est protégé en entier")
struct BusyProjectTests {
    @Test("Un processus à la racine du projet protège un artefact profond")
    func deepArtifactProtected() async throws {
        let home = try FakeHome()
        try home.text("Developpement/appli/apps/mobile/android/app/build.gradle", "")
        try home.file("Developpement/appli/apps/mobile/android/app/.cxx/a.o")
        let busy = ActiveProcess(pid: 7, name: "adb", workingDirectory: home.root.path + "/Developpement/appli")

        let items = await RuleEngine.collect(home.context(processes: [busy]), finders: [.projectArtifacts])
        let item = try #require(items.first { $0.title == ".cxx" })

        #expect(item.protections == [.activeProcess(name: "adb")])
    }
}
