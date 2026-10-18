import Foundation
import Testing
@testable import OustRules
import OustCore
import OustSafety

/// Des outils aux réponses écrites d'avance : un test ne dépend ni de ce qui est
/// installé sur la machine, ni de ce que Docker y fait.
struct FakeTools {
    /// Les exécutables « installés ».
    var installed: Set<String> = []
    /// « exécutable argument argument » → sortie standard. Absent : l'outil échoue.
    var answers: [String: String] = [:]

    var runner: ToolRunner {
        let installed = installed
        let answers = answers
        return ToolRunner(
            locate: { candidates in candidates.first { installed.contains($0) } },
            run: { executable, arguments, _, _ in
                let key = ([executable] + arguments).joined(separator: " ")
                guard let output = answers[key] else {
                    return CommandResult(status: 1, stdout: Data(), stderr: Data("absent".utf8), timedOut: false)
                }
                return CommandResult(status: 0, stdout: Data(output.utf8), stderr: Data(), timedOut: false)
            }
        )
    }
}

extension FakeHome {
    /// Une application minimale : un paquet et son `Info.plist`.
    func app(_ relative: String, version: String) throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version],
                                                       format: .xml, options: 0)
        let url = root.appendingPathComponent(relative).appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: url)
        try file(relative + "/Contents/MacOS/binaire", bytes: 80_000)
    }
}

@Suite("Versions d'outils : la version active est toujours gardée")
struct ToolVersionsTests {

    @Test("Xcode : celui de xcode-select est gardé, l'autre est proposé")
    func xcodeVersions() async throws {
        let home = try FakeHome()
        try home.app("_Applications/Xcode.app", version: "26.1")
        try home.app("_Applications/Xcode-beta.app", version: "27.0")
        var tools = FakeTools()
        tools.answers["/usr/bin/xcode-select -p"] = home.root.path + "/_Applications/Xcode.app/Contents/Developer\n"

        let items = await RuleEngine.collect(home.context(tools: tools.runner), finders: [.toolVersions])

        let active = try #require(items.first { $0.title == "Xcode 26.1" })
        let beta = try #require(items.first { $0.title == "Xcode 27.0" })
        #expect(active.protections == [.activeVersion])
        #expect(!active.isSelectable)
        #expect(beta.isSelectable && beta.safety == .review && beta.method == .trash)
        #expect(!PreselectionPolicy().preselects(beta))
    }

    @Test("Xcode : sans réponse de xcode-select, le plus récent est gardé")
    func xcodeUnknown() async throws {
        let home = try FakeHome()
        try home.app("_Applications/Xcode.app", version: "26.1")
        try home.app("_Applications/Xcode-beta.app", version: "27.0")

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])

        #expect(items.first { $0.title == "Xcode 27.0" }?.protections == [.newestKept])
        #expect(items.first { $0.title == "Xcode 26.1" }?.isSelectable == true)
    }

    @Test("Xcode ouvert : protégé même s'il n'est pas l'actif")
    func xcodeRunning() async throws {
        let home = try FakeHome()
        try home.app("_Applications/Xcode.app", version: "26.1")
        try home.app("_Applications/Xcode-beta.app", version: "27.0")
        var tools = FakeTools()
        tools.answers["/usr/bin/xcode-select -p"] = home.root.path + "/_Applications/Xcode.app/Contents/Developer"
        let process = ActiveProcess(pid: 9, name: "Xcode", workingDirectory: "",
                                    executablePath: home.root.path + "/_Applications/Xcode-beta.app/Contents/MacOS/Xcode")

        let items = await RuleEngine.collect(home.context(processes: [process], tools: tools.runner), finders: [.toolVersions])

        #expect(items.first { $0.title == "Xcode 27.0" }?.protections == [.appRunning(name: "Xcode")])
    }

    @Test("Les installeurs de macOS sont à examiner, rangés dans Système")
    func macOSInstallers() async throws {
        let home = try FakeHome()
        try home.app("_Applications/Install macOS Sequoia.app", version: "15.6")

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])
        let installer = try #require(items.first { $0.ruleID == "version.macos_installer" })

        #expect(installer.category == .systemDownloads && installer.category.section == .system)
        #expect(installer.safety == .review && installer.method == .trash)
    }

    @Test("nvm : l'alias par défaut est gardé, même écrit « 22 »")
    func nvmDefault() async throws {
        let home = try FakeHome()
        try home.file(".nvm/versions/node/v20.11.0/bin/node")
        try home.file(".nvm/versions/node/v22.3.0/bin/node")
        try home.file(".nvm/versions/node/v22.12.0/bin/node")
        try home.text(".nvm/alias/default", "22\n")

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])

        #expect(items.first { $0.title == "Node v22.12.0" }?.protections == [.activeVersion])
        #expect(items.first { $0.title == "Node v22.3.0" }?.isSelectable == true)
        let old = try #require(items.first { $0.title == "Node v20.11.0" })
        #expect(old.method == .removeNow && old.safety == .rebuilds)
        #expect(old.rebuild == .command("nvm install v20.11.0", minutes: 1))
    }

    @Test("nvm : « lts/* » se lit dans ses fichiers d'alias")
    func nvmLTSAlias() throws {
        let home = try FakeHome()
        try home.text(".nvm/alias/lts/*", "lts/jod")
        try home.text(".nvm/alias/lts/jod", "v22.12.0")
        let aliases = home.root.appendingPathComponent(".nvm/alias")

        let resolved = ToolVersionsFinder.resolveNvmAlias("lts/*", installed: ["v20.1.0", "v22.12.0"], aliases: aliases)

        #expect(resolved == "v22.12.0")
        #expect(ToolVersionsFinder.resolveNvmAlias("node", installed: ["v9.0.0", "v10.1.0"], aliases: aliases) == "v10.1.0")
        #expect(ToolVersionsFinder.resolveNvmAlias("../../secret", installed: ["v1.0.0"], aliases: aliases) == nil)
    }

    @Test("nvm : alias par défaut illisible, tout est gardé")
    func nvmUnknownDefault() async throws {
        let home = try FakeHome()
        try home.file(".nvm/versions/node/v20.11.0/bin/node")
        try home.text(".nvm/alias/default", "mon-alias-perdu")

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])

        #expect(items.allSatisfy { $0.protections.contains(.unknownState) })
    }

    @Test("nvm : une version demandée par un .nvmrc n'est pas cochée d'office")
    func nvmPinnedByProject() async throws {
        let home = try FakeHome()
        try home.file(".nvm/versions/node/v18.20.0/bin/node")
        try home.file(".nvm/versions/node/v22.12.0/bin/node")
        try home.text(".nvm/alias/default", "v22.12.0")
        try home.text("Developpement/ancien/.nvmrc", "18\n")

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])
        let pinned = try #require(items.first { $0.title == "Node v18.20.0" })

        #expect(pinned.notes.contains(.usedByProject(name: "ancien")))
        #expect(pinned.safety == .review)
        #expect(!PreselectionPolicy().preselects(pinned))
    }

    @Test("pyenv : la globale est gardée, la commande de l'outil est employée")
    func pyenvGlobal() async throws {
        let home = try FakeHome()
        try home.file(".pyenv/versions/3.11.9/bin/python")
        try home.file(".pyenv/versions/3.12.4/bin/python")
        try home.file(".pyenv/versions/3.10.1/envs/outil/bin/python")
        try home.text(".pyenv/version", "3.12.4\n")
        var tools = FakeTools()
        let pyenv = home.root.path + "/.pyenv/bin/pyenv"
        tools.installed = [pyenv]

        let items = await RuleEngine.collect(home.context(tools: tools.runner), finders: [.toolVersions])

        #expect(items.first { $0.title == "Python 3.12.4" }?.protections == [.activeVersion])
        let old = try #require(items.first { $0.title == "Python 3.11.9" })
        #expect(old.method == .uninstallVersion(tool: .pyenv, executable: pyenv, root: home.root.path + "/.pyenv",
                                                version: "3.11.9"))
        let withEnvironments = try #require(items.first { $0.title == "Python 3.10.1" })
        #expect(withEnvironments.notes.contains(.hasEnvironments(count: 1)))
        #expect(withEnvironments.safety == .review)
    }

    @Test("pyenv : « 3.12 » désigne la 3.12.x la plus récente, un environnement sa version de base")
    func pyenvResolution() async throws {
        let home = try FakeHome()
        try home.file(".pyenv/versions/3.12.1/bin/python")
        try home.file(".pyenv/versions/3.12.4/bin/python")
        try home.file(".pyenv/versions/3.11.9/envs/outils/bin/python")
        try FileManager.default.createSymbolicLink(
            at: home.root.appendingPathComponent(".pyenv/versions/outils"),
            withDestinationURL: home.root.appendingPathComponent(".pyenv/versions/3.11.9/envs/outils"))
        try home.text(".pyenv/version", "3.12\noutils\n")

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])

        #expect(items.first { $0.title == "Python 3.12.4" }?.protections == [.activeVersion])
        #expect(items.first { $0.title == "Python 3.11.9" }?.protections == [.activeVersion])
        #expect(items.first { $0.title == "Python 3.12.1" }?.isSelectable == true)
        #expect(!items.contains { $0.title == "Python outils" })
    }

    @Test("pyenv : une globale introuvable, et tout est gardé")
    func pyenvUnknownGlobal() async throws {
        let home = try FakeHome()
        try home.file(".pyenv/versions/3.12.4/bin/python")
        try home.text(".pyenv/version", "pypy3.10\n")

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])

        #expect(items.first?.protections == [.unknownState])
    }

    @Test("NDK : un ndk-bundle seul est gardé")
    func loneNDKBundle() async throws {
        let home = try FakeHome()
        try home.file("Library/Android/sdk/ndk-bundle/source.properties")

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])

        #expect(items.first?.protections == [.newestKept])
    }

    @Test("JDK : celui de java_home est gardé ; ceux du système ne se retirent qu'à la main")
    func javaVersions() async throws {
        let home = try FakeHome()
        try home.file(".gradle/jdks/eclipse_adoptium-17-aarch64-os_x.2/bin/java")
        try home.file(".gradle/jdks/OpenJDK17U-jdk_aarch64_mac_hotspot_17.tar.gz")
        try home.file(".gradle/jdks/eclipse_adoptium-17-aarch64-os_x.2.reserved.lock", bytes: 0)
        try home.file("_Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home/bin/java")
        try home.file("_Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home/bin/java")
        var tools = FakeTools()
        tools.answers["/usr/libexec/java_home"] = home.root.path + "/_Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home\n"

        let items = await RuleEngine.collect(home.context(tools: tools.runner), finders: [.toolVersions])

        let gradle = try #require(items.first { $0.title == "eclipse_adoptium-17-aarch64-os_x.2" })
        #expect(gradle.isSelectable && gradle.method == .removeNow)
        #expect(items.first { $0.title.hasSuffix(".tar.gz") }?.safety == .safe)
        #expect(!items.contains { $0.title.hasSuffix(".lock") })
        #expect(items.first { $0.title == "zulu-21" }?.protections == [.activeVersion])
        let system = try #require(items.first { $0.title == "temurin-17" })
        #expect(system.method == .manual && !system.isSelectable)
    }

    @Test("NDK : le plus récent est gardé, même en ordre de version et non alphabétique")
    func androidNDK() async throws {
        let home = try FakeHome()
        try home.file("Library/Android/sdk/ndk/9.2.1/source.properties")
        try home.file("Library/Android/sdk/ndk/27.1.12297006/source.properties")
        try home.file("Library/Android/sdk/ndk/29.0.13113456/source.properties")

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])

        #expect(items.first { $0.title == "NDK 29.0.13113456" }?.protections == [.newestKept])
        #expect(items.first { $0.title == "NDK 27.1.12297006" }?.isSelectable == true)
        #expect(items.first { $0.title == "NDK 9.2.1" }?.isSelectable == true)
    }

    @Test("rustup : la toolchain par défaut et les surcharges sont respectées")
    func rustToolchains() async throws {
        let home = try FakeHome()
        try home.file(".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc")
        try home.file(".rustup/toolchains/nightly-2025-01-01-aarch64-apple-darwin/bin/rustc")
        try home.file(".rustup/toolchains/1.75.0-aarch64-apple-darwin/bin/rustc")
        try home.text(".rustup/settings.toml", """
        default_toolchain = "stable"
        profile = "default"
        version = "12"

        [overrides]
        "/projets/vieux-crate" = "1.75.0-aarch64-apple-darwin"
        """)

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])

        #expect(items.first { $0.title == "stable-aarch64-apple-darwin" }?.protections == [.activeVersion])
        let pinned = try #require(items.first { $0.title == "1.75.0-aarch64-apple-darwin" })
        #expect(pinned.notes.contains(.usedByProject(name: "vieux-crate")))
        let nightly = try #require(items.first { $0.title.hasPrefix("nightly") })
        #expect(nightly.isSelectable && nightly.method == .removeNow)
    }

    @Test("rustup sans toolchain par défaut : tout est gardé")
    func rustUnknownDefault() async throws {
        let home = try FakeHome()
        try home.file(".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc")

        let items = await RuleEngine.collect(home.context(), finders: [.toolVersions])

        #expect(items.first?.protections == [.unknownState])
    }

    @Test("Ordre des versions")
    func versionOrder() {
        #expect(ToolVersionsFinder.compare("9.2", "10.1"))
        #expect(ToolVersionsFinder.compare("27.1.12297006", "29.0.13113456"))
        #expect(!ToolVersionsFinder.compare("26.1", "26.0.1"))
        #expect(ToolVersionsFinder.appBundle(containing: "/Applications/Xcode-beta.app/Contents/Developer\n")
            == "/Applications/Xcode-beta.app")
        #expect(ToolVersionsFinder.appBundle(containing: "/Library/Developer/CommandLineTools") == nil)
    }
}

@Suite("Homebrew, Docker et OrbStack : à blanc d'abord")
struct ToolCleanupsTests {

    @Test("brew cleanup à blanc : les chemins sont repris, le cache n'est pas compté deux fois")
    func brewDryRun() async throws {
        let home = try FakeHome()
        try home.file("_brew/Cellar/node/22.1.0/bin/node", bytes: 120_000)
        try home.file("Library/Caches/Homebrew/downloads/abc--node.tar.gz", bytes: 50_000)
        try home.text("Library/Caches/Homebrew/api/formula.jws.json", "{}")
        let cellar = home.root.path + "/_brew/Cellar/node/22.1.0"
        let cached = home.root.path + "/Library/Caches/Homebrew/downloads/abc--node.tar.gz"
        var tools = FakeTools()
        tools.installed = ["/opt/homebrew/bin/brew"]
        tools.answers["/opt/homebrew/bin/brew cleanup --dry-run"] = """
        Would remove: \(cellar) (2 files, 117.2KB)
        Would remove: \(cached) (48.8KB)
        ==> This operation would free approximately 166KB of disk space.
        """

        let items = await RuleEngine.collect(home.context(tools: tools.runner), finders: [.toolCleanups])
        let brew = try #require(items.first)

        #expect(brew.paths.map(\.path) == [cellar])
        #expect(brew.method == .brewCleanup(executable: "/opt/homebrew/bin/brew"))
        #expect(brew.safety == .safe)
        // Mesuré par Oust!, pas repris de la sortie de Homebrew.
        #expect(brew.sizes.allocated > 0)
    }

    static let docker = "/opt/homebrew/bin/docker"

    /// Un OrbStack local qui tourne, avec deux images inutilisées (dont une
    /// étiquetée deux fois), une en service, un conteneur arrêté, un qui tourne.
    static func orbstack() -> FakeTools {
        var tools = FakeTools()
        tools.installed = [docker]
        tools.answers["\(docker) context inspect --format {{.Endpoints.docker.Host}}"] = "unix:///var/run/docker.sock\n"
        tools.answers["\(docker) context show"] = "orbstack\n"
        tools.answers["\(docker) system df --format {{json .}}"] = """
        {"Active":"2","Reclaimable":"1.234GB (50%)","Size":"2.4GB","TotalCount":"5","Type":"Images"}
        {"Active":"1","Reclaimable":"8GB (90%)","Size":"9GB","TotalCount":"4","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"512MB","Size":"512MB","TotalCount":"40","Type":"Build Cache"}
        """
        tools.answers["\(docker) system df -v --format {{json .}}"] = """
        {"Images":[{"Containers":"0","ID":"sha256:aaa111","Repository":"alpine","Tag":"3.20","UniqueSize":"8MB"},\
        {"Containers":"0","ID":"sha256:aaa111","Repository":"alpine","Tag":"latest","UniqueSize":"8MB"},\
        {"Containers":"0","ID":"sha256:bbb222","Repository":"<none>","Tag":"<none>","UniqueSize":"1.5GB"},\
        {"Containers":"1","ID":"sha256:ccc333","Repository":"postgres","Tag":"16","UniqueSize":"400MB"}],\
        "Containers":[{"ID":"d1e2f3","State":"exited","Size":"12.5MB"},{"ID":"a9b8c7","State":"running","Size":"3MB"}],\
        "Volumes":[],"BuildCache":[]}
        """
        return tools
    }

    @Test("Docker : cache, images et conteneurs relevés un à un, jamais les volumes")
    func dockerUsage() async throws {
        let home = try FakeHome()
        let orbstack = ActiveProcess(pid: 3, name: "OrbStack", workingDirectory: "")

        let items = await RuleEngine.collect(home.context(processes: [orbstack], tools: Self.orbstack().runner),
                                             finders: [.toolCleanups])

        #expect(Set(items.map(\.ruleID)) == ["container.build_cache", "container.images", "container.stopped"])
        let images = try #require(items.first { $0.ruleID == "container.images" })
        // Les octets propres de chaque image, une fois : 8 Mo + 1,5 Go.
        #expect(images.sizes.freeable == 1_508_000_000)
        #expect(images.method == .containerPrune(executable: Self.docker, scope: .unusedImages,
                                                 ids: ["alpine:3.20", "alpine:latest", "sha256:bbb222"]))
        #expect(images.safety == .review && !images.countsInHeadline)
        #expect(images.owner == "OrbStack")
        let stopped = try #require(items.first { $0.ruleID == "container.stopped" })
        #expect(stopped.method == .containerPrune(executable: Self.docker, scope: .stoppedContainers, ids: ["d1e2f3"]))
        #expect(stopped.safety == .review)
        #expect(items.first { $0.ruleID == "container.build_cache" }?.sizes.freeable == 512_000_000)
    }

    @Test("Un contexte Docker distant n'est ni interrogé ni nettoyé")
    func dockerRemoteContext() async throws {
        let home = try FakeHome()
        var tools = Self.orbstack()
        tools.answers["\(Self.docker) context inspect --format {{.Endpoints.docker.Host}}"] = "ssh://prod.exemple.fr\n"
        let orbstack = ActiveProcess(pid: 3, name: "OrbStack", workingDirectory: "")

        let items = await RuleEngine.collect(home.context(processes: [orbstack], tools: tools.runner), finders: [.toolCleanups])

        #expect(items.isEmpty)
    }

    @Test("Docker arrêté : rien n'est proposé, rien n'est démarré")
    func dockerStopped() async throws {
        let home = try FakeHome()
        let asked = Asked()
        let docker = "/usr/local/bin/docker"
        let tools = ToolRunner(locate: { $0.contains(docker) ? docker : nil },
                               run: { executable, arguments, _, _ in
                                   asked.append(([executable] + arguments).joined(separator: " "))
                                   return .notRun
                               })

        let items = await RuleEngine.collect(home.context(tools: tools), finders: [.toolCleanups])

        #expect(items.isEmpty)
        // Aucun moteur ne tourne : la CLI n'a même pas été appelée.
        #expect(asked.all.isEmpty)
    }

    @Test("Homebrew sans description locale des formules : on ne le lance pas (il irait en ligne)")
    func brewNeedsOfflineData() async throws {
        let home = try FakeHome()
        var tools = FakeTools()
        tools.installed = ["/opt/homebrew/bin/brew"]
        tools.answers["/opt/homebrew/bin/brew cleanup --dry-run"] = "Would remove: /x (1B)"

        let items = await RuleEngine.collect(home.context(tools: tools.runner), finders: [.toolCleanups])

        #expect(items.isEmpty)
    }

    @Test("Tailles de Docker")
    func dockerBytes() {
        #expect(ToolCleanupsFinder.dockerBytes("1.5GB (30%)") == 1_500_000_000)
        #expect(ToolCleanupsFinder.dockerBytes("12.5kB") == 12_500)
        #expect(ToolCleanupsFinder.dockerBytes("0B") == 0)
        #expect(ToolCleanupsFinder.dockerBytes("n/a") == nil)
    }
}

/// Les commandes qu'un faux outil a reçues.
final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    func append(_ command: String) { lock.withLock { commands.append(command) } }
    var all: [String] { lock.withLock { commands } }
}
