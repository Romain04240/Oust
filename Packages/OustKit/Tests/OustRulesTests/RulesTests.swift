import Foundation
import Testing
@testable import OustRules
import OustCore
import OustSafety

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
