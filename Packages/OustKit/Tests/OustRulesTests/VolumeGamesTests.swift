import Foundation
import Testing
@testable import OustRules
import OustCore
import OustSafety
import OustScan

private let heavy = 1_200_000

/// Un faux disque de jeux dans le dossier temporaire du test : sa racine joue
/// `/Volumes/<disque>` (RULES.md, règle 8).
private extension FakeHome {
    var gameVolume: URL { root.appendingPathComponent("_Jeux", isDirectory: true) }

    func onGameVolume(_ relative: String, bytes: Int = heavy) throws {
        try file("_Jeux/" + relative, bytes: bytes)
    }

    func gamesContext(readOnly: Bool = false, tree: TreeNode? = nil, runningApps: Set<String> = []) -> RuleContext {
        var context = self.context(runningApps: runningApps)
        context.volume = VolumeScope(root: gameVolume, name: "Jeux", fileSystem: "exfat", isReadOnly: readOnly)
        context.projectRoots = [gameVolume]
        if let tree { context.tree = { tree } }
        return context
    }

    func steamManifest(_ library: String, app: String, name: String, folder: String) throws {
        try text("_Jeux/\(library)/appmanifest_\(app).acf", """
        "AppState"
        {
        \t"appid"\t\t"\(app)"
        \t"name"\t\t"\(name)"
        \t"installdir"\t\t"\(folder)"
        }
        """)
    }

    /// Les jeux que le lanceur d'Epic de ce Mac dit installés.
    func epicInstalled(_ locations: [String]) throws {
        let list = locations.map { #"{"InstallLocation": "\#($0)", "AppName": "x"}"# }.joined(separator: ", ")
        try text("Library/Application Support/Epic/UnrealEngineLauncher/LauncherInstalled.dat",
                 #"{"InstallationList": [\#(list)]}"#)
    }

    /// Un disque comme on en garde pour les jeux : une bibliothèque Steam ajoutée
    /// depuis Steam, une autre reconnue à ses manifestes, un dossier Epic Games.
    func populateGameVolume() throws {
        let steam = "SteamLibrary/steamapps"
        try text("_Jeux/SteamLibrary/libraryfolder.vdf", #""libraryfolder" { "contentid" "1" }"#)
        try steamManifest(steam, app: "620", name: "Portal 2", folder: "Portal 2")
        try steamManifest(steam, app: "1091500", name: "Cyberpunk 2077", folder: "Cyberpunk 2077")
        try onGameVolume("\(steam)/common/Portal 2/portal2.app/Contents/MacOS/portal2")
        try onGameVolume("\(steam)/common/Cyberpunk 2077/bin/a.bin")
        try onGameVolume("\(steam)/common/Vieux Jeu/mods/a.pak")
        try onGameVolume("\(steam)/shadercache/620/fozpipelinesv6/a")
        try onGameVolume("\(steam)/depotcache/620_621.manifest")
        try onGameVolume("\(steam)/downloading/1091500/archive/pc/content/a.archive")
        try onGameVolume("\(steam)/downloading/state_1091500_1091501.patch", bytes: 4_096)
        try onGameVolume("\(steam)/temp/1091500/a.tmp")
        try onGameVolume("\(steam)/workshop/content/620/a.vpk")
        // Rangée à la main, reconnue à son manifeste.
        try steamManifest("Archives/steamapps", app: "440", name: "Team Fortress 2", folder: "Team Fortress 2")
        try onGameVolume("Archives/steamapps/common/Team Fortress 2/a.vpk")
        try onGameVolume("Archives/steamapps/shadercache/440/a")
        // Un dossier qui n'a de Steam que le nom.
        try onGameVolume("Divers/steamapps/shadercache/a")

        // Epic : un jeu installé depuis ce Mac, son téléchargement inachevé, un reste.
        try onGameVolume("Epic Games/Fortnite/.egstore/Fortnite.manifest", bytes: 4_096)
        try onGameVolume("Epic Games/Fortnite/.egstore/bps/a.chunk")
        try onGameVolume("Epic Games/Fortnite/FortniteClient.app/a")
        try onGameVolume("Epic Games/AncienJeu/Saved/a.sav")
        // Installé depuis un autre ordinateur : le lanceur de ce Mac ne le connaît pas.
        try onGameVolume("Epic Games/Inconnu/.egstore/Inconnu.manifest", bytes: 4_096)
        try onGameVolume("Epic Games/Inconnu/a.pak")
    }
}

@Suite("Les jeux d'un autre disque : bibliothèques Steam et jeux d'Epic")
struct VolumeGamesTests {

    @Test("Steam : shaders, manifestes de dépôts, téléchargement inachevé et reste, comme au disque de démarrage")
    func steamLibrary() async throws {
        let home = try FakeHome()
        try home.populateGameVolume()

        let items = await RuleEngine.collect(home.gamesContext(), finders: FinderKind.volumeFinders)
        let games = items.filter { $0.category == .games }
        #expect(games.allSatisfy { $0.category.section == .system })

        let shaders = games.filter { $0.ruleID == "game.steam.shadercache" }
        #expect(Set(shaders.map { $0.paths[0].deletingLastPathComponent().deletingLastPathComponent().lastPathComponent })
                == ["SteamLibrary", "Archives"])
        #expect(shaders.allSatisfy { $0.safety == .rebuilds && $0.method == .removeNow })
        let depots = try #require(games.first { $0.ruleID == "game.steam.depotcache" })
        #expect(depots.safety == .safe && depots.rebuild == .download && depots.paths.count == 1)

        let download = try #require(games.first { $0.ruleID == "game.steam.download" })
        #expect(download.title == "Cyberpunk 2077")
        #expect(Set(download.paths.map(\.lastPathComponent))
                == ["1091500", "state_1091500_1091501.patch"])
        #expect(download.paths.filter { $0.lastPathComponent == "1091500" }.count == 2)
        #expect(download.safety == .review && download.method == .removeNow && download.rebuild == .download)
        #expect(!PreselectionPolicy().preselects(download))

        let leftovers = games.filter { $0.ruleID == "game.steam.leftover" }
        #expect(leftovers.map(\.title) == ["Vieux Jeu"])
        #expect(leftovers.allSatisfy { $0.safety == .review && $0.method == .trash && $0.protections.isEmpty })

        // Ni un jeu installé, ni le Workshop, ni un dossier qui n'a de Steam que le nom.
        let paths = games.flatMap(\.paths).map(\.path)
        #expect(!paths.contains { $0.contains("/common/Portal 2") || $0.contains("/common/Cyberpunk 2077") })
        #expect(!paths.contains { $0.contains("/workshop") || $0.contains("/Divers/") })
        // Tout ce qui est proposé passe la garde.
        let guardian = PathGuard(home: home.root.appendingPathComponent("Maison"), otherVolumeRoots: [home.gameVolume])
        #expect(games.flatMap(\.paths).allSatisfy(guardian.allows))
    }

    @Test("Epic : le téléchargement inachevé d'un jeu installé, le reste d'un jeu désinstallé")
    func epicLibrary() async throws {
        let home = try FakeHome()
        try home.populateGameVolume()
        // Le lanceur l'a noté quand le disque s'appelait autrement : même chemin depuis sa racine.
        try home.epicInstalled(["/Volumes/Jeux 1/Epic Games/Fortnite"])

        let items = await RuleEngine.collect(home.gamesContext(), finders: [.games])
        let epic = items.filter { $0.owner == "Epic Games Launcher" }

        let download = try #require(epic.first { $0.ruleID == "game.epic.download" })
        #expect(download.title == "Fortnite" && download.paths.map(\.lastPathComponent) == ["bps"])
        #expect(download.safety == .review && download.method == .removeNow && !PreselectionPolicy().preselects(download))
        let leftovers = epic.filter { $0.ruleID == "game.epic.leftover" }
        #expect(Set(leftovers.map(\.title)) == ["AncienJeu", "Inconnu"])
        let old = try #require(leftovers.first { $0.title == "AncienJeu" })
        #expect(old.safety == .review && old.method == .trash && old.protections.isEmpty)
        // Il garde son `.egstore` : installé ailleurs, pas désinstallé.
        let unknown = try #require(leftovers.first { $0.title == "Inconnu" })
        #expect(unknown.protections == [.unknownState] && !unknown.isSelectable)
        // Le jeu installé lui-même n'est jamais proposé.
        #expect(!epic.contains { $0.paths.contains { $0.lastPathComponent == "Fortnite" } })
    }

    @Test("Epic : une bibliothèque dont ce Mac n'a installé aucun jeu, ou sans liste du lanceur, est protégée")
    func epicFromAnotherComputer() async throws {
        let home = try FakeHome()
        try home.populateGameVolume()
        // Un jeu hors d'un dossier Epic Games, reconnu à son `.egstore`.
        try home.onGameVolume("Jeux PC/Rocket League/.egstore/a.manifest", bytes: 4_096)
        try home.onGameVolume("Jeux PC/Rocket League/.egstore/bps/a.chunk")
        try home.onGameVolume("Jeux PC/Rocket League/a.pak")

        // Pas de liste : rien n'est sûr.
        let unknown = await RuleEngine.collect(home.gamesContext(), finders: [.games])
            .filter { $0.owner == "Epic Games Launcher" }
        #expect(Set(unknown.map(\.title)) == ["Fortnite", "AncienJeu", "Inconnu", "Rocket League"])
        #expect(unknown.allSatisfy { $0.ruleID == "game.epic.leftover" && $0.protections == [.unknownState] })

        // Une liste, mais aucun de ces jeux : le disque vient d'ailleurs.
        try home.epicInstalled([home.root.appendingPathComponent("_Shared/Epic Games/Autre").path])
        let foreign = await RuleEngine.collect(home.gamesContext(), finders: [.games])
            .filter { $0.owner == "Epic Games Launcher" }
        #expect(foreign.count == 4 && foreign.allSatisfy { $0.protections == [.unknownState] })

        // Installé depuis ce Mac, hors d'un dossier Epic Games : son téléchargement seul.
        try home.epicInstalled([home.gameVolume.appendingPathComponent("Jeux PC/Rocket League").path])
        let loose = await RuleEngine.collect(home.gamesContext(), finders: [.games])
        #expect(loose.contains { $0.ruleID == "game.epic.download" && $0.title == "Rocket League" })
        #expect(!loose.contains { $0.ruleID == "game.epic.leftover" && $0.title == "Rocket League" })
    }

    @Test("Un jeu d'Epic installé à la racine du disque : jamais le disque entier")
    func neverTheVolumeRoot() async throws {
        let home = try FakeHome()
        try home.onGameVolume(".egstore/a.manifest", bytes: 4_096)
        try home.onGameVolume("Game/a.pak")

        let items = await RuleEngine.collect(home.gamesContext(), finders: [.games])

        #expect(items.isEmpty)
    }

    @Test("Lanceur ouvert, disque en lecture seule : tout est protégé")
    func protections() async throws {
        let home = try FakeHome()
        try home.populateGameVolume()
        try home.epicInstalled(["/Volumes/Jeux/Epic Games/Fortnite"])

        let steamOpen = await RuleEngine.collect(home.gamesContext(runningApps: ["com.valvesoftware.steam"]),
                                                 finders: [.games])
        let steam = steamOpen.filter { $0.owner == "Steam" }
        #expect(!steam.isEmpty && steam.allSatisfy { $0.protections.contains(.appRunning(name: "Steam")) })
        #expect(steamOpen.filter { $0.owner != "Steam" }.allSatisfy { !$0.protections.contains(.appRunning(name: "Steam")) })

        let epicOpen = await RuleEngine.collect(home.gamesContext(runningApps: ["com.epicgames.EpicGamesLauncher"]),
                                                finders: [.games])
        let epic = epicOpen.filter { $0.owner == "Epic Games Launcher" }
        #expect(!epic.isEmpty && epic.allSatisfy { $0.protections.contains(.appRunning(name: "Epic Games Launcher")) })

        let readOnly = await RuleEngine.collect(home.gamesContext(readOnly: true), finders: [.games])
        #expect(!readOnly.isEmpty && readOnly.allSatisfy { !$0.isSelectable && $0.protections.contains(.readOnlyVolume) })
    }

    @Test("Avec l'arbre de l'analyse : les mêmes éléments, .egstore compris")
    func fromTree() async throws {
        let home = try FakeHome()
        try home.populateGameVolume()
        try home.epicInstalled(["/Volumes/Jeux/Epic Games/Fortnite"])
        let options = ScanOptions(leafThreshold: 100_000, notableNames: RuleEngine.notableNames(fileSystem: "exfat"))
        let (index, _) = await ScanIndex.refresh(nil, root: home.gameVolume, options: options)
        // Le dossier caché d'Epic est dans l'arbre : c'est lui qu'on y cherche.
        let store = home.gameVolume.appendingPathComponent("Epic Games/Fortnite/.egstore").path
        #expect(index.root.descendant(atPath: store) != nil)

        let fromDisk = await RuleEngine.collect(home.gamesContext(), finders: [.games])
        let fromTree = await RuleEngine.collect(home.gamesContext(tree: index.root), finders: [.games],
                                                measurer: .tree { index.root })

        // `FileManager` rend parfois `/private/var/…` là où l'arbre dit `/var/…` : un même chemin.
        func ids(_ items: [CleanupItem]) -> Set<String> {
            Set(items.map { $0.id.replacingOccurrences(of: "/private/var/", with: "/var/") })
        }
        #expect(!fromDisk.isEmpty && ids(fromTree) == ids(fromDisk))
        #expect(fromTree.contains { $0.ruleID == "game.epic.download" })
    }

    @Test("Au disque de démarrage, ni les jeux d'un autre disque ni les caches des lanceurs sur ce disque")
    func scopes() async throws {
        let home = try FakeHome()
        try home.populateGameVolume()
        try home.file("Library/Application Support/Steam/appcache/a.jpg", bytes: heavy)

        let boot = await RuleEngine.collect(home.context(), finders: [.games])
        #expect(!boot.flatMap(\.paths).contains { $0.path.contains("/_Jeux/") })
        let volume = await RuleEngine.collect(home.gamesContext(), finders: [.games])
        #expect(!volume.contains { $0.ruleID == "game.steam.appcache" })
        #expect(volume.flatMap(\.paths).allSatisfy { $0.path.contains("/_Jeux/") })
    }

    @Test("Au disque de démarrage aussi : téléchargements inachevés de Steam et d'Epic")
    func bootDownloads() async throws {
        let home = try FakeHome()
        let steamapps = "Library/Application Support/Steam/steamapps"
        try home.file("\(steamapps)/downloading/730/a.vpk", bytes: heavy)
        try home.file("_Shared/Epic Games/Fortnite/.egstore/bps/a.chunk", bytes: heavy)
        try home.file("_Shared/Epic Games/Fortnite/a.pak", bytes: heavy)
        try home.epicInstalled([home.root.appendingPathComponent("_Shared/Epic Games/Fortnite").path])

        let items = await RuleEngine.collect(home.context(), finders: [.games])

        let steam = try #require(items.first { $0.ruleID == "game.steam.download" })
        #expect(steam.title == "Steam" && steam.paths.map(\.lastPathComponent) == ["730"])
        let epic = try #require(items.first { $0.ruleID == "game.epic.download" })
        #expect(epic.title == "Fortnite" && epic.safety == .review)
        #expect(items.count == 2)
    }

    @Test("Les règles nouvelles sont connues du catalogue")
    func catalogued() {
        #expect(Set(["game.steam.download", "game.epic.download"]).isSubset(of: Set(RuleCatalog.ruleIDs)))
        #expect(FinderKind.volumeFinders.contains(.games) && !FinderKind.volumeOnly.contains(.games))
    }
}
