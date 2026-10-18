import Foundation
import Testing
@testable import OustRules
import OustCore
import OustSafety

/// Assez gros pour passer le seuil d'un mégaoctet des caches.
private let heavy = 1_200_000

@Suite("Logiciels de création : vidéo, musique et 3D")
struct CreativeAppsTests {

    @Test("Final Cut Pro et iMovie : rendus et médias transcodés, jamais la bibliothèque ni les originaux")
    func videoLibraries() async throws {
        let home = try FakeHome()
        try home.file("Movies/Mon film.fcpbundle/Tournage/Render Files/High Quality Media/r.mov", bytes: heavy)
        try home.file("Movies/Mon film.fcpbundle/Tournage/Transcoded Media/Proxy Media/p.mov", bytes: heavy)
        try home.file("Movies/Mon film.fcpbundle/Tournage/Original Media/o.mov", bytes: heavy)
        try home.text("Movies/Mon film.fcpbundle/Tournage/CurrentVersion.fcpevent", "")
        try home.file("Movies/Vacances/iMovie Library.imovielibrary/Plage/Render Files/r.mov", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        let render = try #require(items.first { $0.ruleID == "creative.library.render" && $0.owner == "Final Cut Pro" })
        #expect(render.title == "Mon film")
        #expect(render.safety == .rebuilds && render.method == .removeNow && render.rebuild == .automatic)
        #expect(render.category == .creative && render.category.section == .system)
        let transcoded = try #require(items.first { $0.ruleID == "creative.library.transcoded" })
        #expect(transcoded.safety == .review && transcoded.method == .trash)
        #expect(!PreselectionPolicy().preselects(transcoded))
        #expect(items.contains { $0.ruleID == "creative.library.render" && $0.owner == "iMovie" })
        // Ni le paquet de la bibliothèque, ni ce qu'elle a importé.
        let paths = items.flatMap(\.paths).map(\.path)
        #expect(!paths.contains { $0.hasSuffix(".fcpbundle") || $0.hasSuffix(".imovielibrary") })
        #expect(!paths.contains { $0.contains("Original Media") || $0.hasSuffix("CurrentVersion.fcpevent") })
        // La garde laisse passer ce qu'on propose dans un paquet.
        let guardian = PathGuard(home: home.root)
        #expect(items.flatMap(\.paths).allSatisfy(guardian.allows))
    }

    @Test("Des rendus vieux d'un mois sont cochés d'office ; des médias transcodés, jamais")
    func preselection() async throws {
        let home = try FakeHome()
        let old = Date().addingTimeInterval(-30 * 86_400)
        try home.file("Movies/Film.fcpbundle/E/Render Files/r.mov", bytes: heavy, modified: old)
        try home.file("Movies/Film.fcpbundle/E/Transcoded Media/t.mov", bytes: heavy, modified: old)
        // La mesure lit aussi la date des dossiers, que la création des fichiers vient de rajeunir.
        for folder in ["Render Files", "Transcoded Media"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath:
                home.root.appendingPathComponent("Movies/Film.fcpbundle/E/\(folder)").path)
        }

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        let render = try #require(items.first { $0.ruleID == "creative.library.render" })
        let transcoded = try #require(items.first { $0.ruleID == "creative.library.transcoded" })
        #expect(PreselectionPolicy().preselects(render))
        #expect(!PreselectionPolicy().preselects(transcoded))
    }

    @Test("Final Cut Pro ouvert : ses bibliothèques et celles d'iMovie sont protégées")
    func openEditorProtects() async throws {
        let home = try FakeHome()
        try home.file("Movies/Film.fcpbundle/E/Render Files/r.mov", bytes: heavy)
        try home.file("Movies/iMovie Library.imovielibrary/E/Render Files/r.mov", bytes: heavy)

        let items = await RuleEngine.collect(home.context(runningApps: ["com.apple.FinalCut"]), finders: [.creative])

        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.protections == [.appRunning(name: "Final Cut Pro")] && !$0.isSelectable })
    }

    @Test("DaVinci Resolve : cache de rendu, proxys et Galerie, chacun sa classe")
    func resolve() async throws {
        let home = try FakeHome()
        try home.file("Movies/DaVinci Resolve/CacheClip/audio/a.pfl", bytes: heavy)
        try home.file("Movies/DaVinci Resolve/ProxyMedia/clip.mov", bytes: heavy)
        try home.file("Movies/DaVinci Resolve/.gallery/b60f/still.dpx", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        let cache = try #require(items.first { $0.ruleID == "creative.resolve.cache" })
        #expect(cache.safety == .rebuilds && cache.method == .removeNow)
        let proxy = try #require(items.first { $0.ruleID == "creative.resolve.proxy" })
        #expect(proxy.safety == .review && proxy.method == .trash)
        let gallery = try #require(items.first { $0.ruleID == "creative.resolve.gallery" })
        #expect(gallery.safety == .review && gallery.method == .trash && gallery.rebuild == .irreversible)

        // La version de l'App Store (« …Lite ») ouverte protège tout.
        let open = await RuleEngine.collect(home.context(runningApps: ["com.blackmagic-design.DaVinciResolveLite"]),
                                            finders: [.creative])
        #expect(open.count == 3)
        #expect(open.allSatisfy { $0.protections == [.appRunning(name: "DaVinci Resolve")] })
    }

    @Test("Insta360 Studio : caches et proxys, jamais la file des exports dans le nuage")
    func insta360() async throws {
        let home = try FakeHome()
        let support = "Library/Application Support/Insta360/Insta360 Studio"
        try home.file("Library/Caches/Insta360/Insta360 Studio/qmlcache/a.qmlc", bytes: heavy)
        try home.file("\(support)/cache/cef_cache/b", bytes: heavy)
        try home.file("\(support)/cache/cloud_cache/cloudexportlist.db", bytes: heavy)
        try home.file("\(support)/proxy_file/clip.proxy", bytes: heavy)
        try home.file("\(support)/user_data/settings", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        let cache = try #require(items.first { $0.ruleID == "creative.insta360.cache" })
        #expect(cache.safety == .safe && cache.paths.count == 2)
        let proxy = try #require(items.first { $0.ruleID == "creative.insta360.proxy" })
        #expect(proxy.safety == .rebuilds)
        let paths = items.flatMap(\.paths).map(\.path)
        #expect(!paths.contains { $0.contains("cloud_cache") || $0.contains("user_data") })
    }

    @Test("Blender : son cache et ses dossiers de session, pas de quoi retrouver une séance perdue")
    func blender() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/Blender/asset-library-indices/x.json", bytes: heavy)
        try home.file("_tmp/blender_aaosBh/render.exr", bytes: heavy)
        try home.file("_tmp/quit.blend", bytes: heavy)
        try home.file("_tmp/projet_1234_autosave.blend", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        let cache = try #require(items.first { $0.ruleID == "creative.blender.cache" })
        #expect(cache.safety == .safe && cache.method == .removeNow)
        let temp = try #require(items.first { $0.ruleID == "creative.blender.temp" })
        #expect(temp.paths.map(\.lastPathComponent) == ["blender_aaosBh"])
        #expect(!items.flatMap(\.paths).contains { $0.pathExtension == "blend" })

        let open = await RuleEngine.collect(home.context(runningApps: ["org.blenderfoundation.blender"]),
                                            finders: [.creative])
        #expect(open.allSatisfy { $0.protections == [.appRunning(name: "Blender")] })
    }

    @Test("Les sons de GarageBand et de Logic sont montrés, jamais cochables : ils sont à root")
    func soundLibrary() async throws {
        let home = try FakeHome()
        try home.file("_Library/Application Support/GarageBand/Instrument Library/a.caf", bytes: heavy)
        try home.file("_Library/Application Support/Logic/Alchemy Samples/b.caf", bytes: heavy)
        try home.file("_Library/Audio/Apple Loops/Apple/c.caf", bytes: heavy)
        // Des boucles d'un autre éditeur, à côté : pas à Apple, pas à nous.
        try home.file("_Library/Audio/Apple Loops/Autre/d.caf", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        let sounds = try #require(items.first { $0.ruleID == "creative.sound_library" })
        #expect(sounds.paths.count == 3)
        #expect(!sounds.paths.contains { $0.lastPathComponent == "Autre" })
        #expect(sounds.safety == .review && sounds.method == .manual && sounds.rebuild == .download)
        #expect(!sounds.isSelectable && !PreselectionPolicy().preselects(sounds))
    }

    @Test("Un cache de quelques kilo-octets n'est pas montré")
    func tinyCachesHidden() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/Blender/x.json", bytes: 20_000)
        try home.file("Movies/DaVinci Resolve/CacheClip/a.pfl", bytes: 20_000)

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        #expect(items.isEmpty)
    }
}

@Suite("Lanceurs de jeux : Steam, Epic, GOG")
struct GamesTests {

    /// Une bibliothèque Steam de plus, déclarée dans `libraryfolders.vdf`.
    func declareLibraries(_ home: FakeHome, extraLibrary: URL) throws {
        let steam = "Library/Application Support/Steam"
        try home.text("\(steam)/steamapps/libraryfolders.vdf", """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"\(home.root.path)/\(steam)"
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"\(extraLibrary.path)"
        \t}
        \t"2"
        \t{
        \t\t"path"\t\t"\(home.root.path)/Disparue"
        \t}
        }
        """)
    }

    @Test("Steam : appcache sûr, shaders reconstruits, manifestes de dépôts retéléchargés")
    func steamCaches() async throws {
        let home = try FakeHome()
        let steam = "Library/Application Support/Steam"
        let extra = home.root.appendingPathComponent("SteamLibrary")
        try declareLibraries(home, extraLibrary: extra)
        try home.file("\(steam)/appcache/librarycache/a.jpg", bytes: heavy)
        try home.file("\(steam)/depotcache/1_2.manifest", bytes: heavy)
        try home.file("\(steam)/steamapps/shadercache/440/fozpipelinesv6/a", bytes: heavy)
        try home.file("SteamLibrary/steamapps/shadercache/570/a", bytes: heavy)
        try home.file("SteamLibrary/steamapps/depotcache/3_4.manifest", bytes: heavy)
        // Le client lui-même et les réglages ne sont pas des caches.
        try home.file("\(steam)/Steam.AppBundle/Steam/Contents/MacOS/steam", bytes: heavy)
        try home.file("\(steam)/config/config.vdf", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.games])

        let appcache = try #require(items.first { $0.ruleID == "game.steam.appcache" })
        #expect(appcache.safety == .safe && appcache.method == .removeNow && appcache.category == .games)
        #expect(appcache.category.section == .system)
        let shaders = items.filter { $0.ruleID == "game.steam.shadercache" }
        #expect(shaders.count == 2)
        #expect(shaders.allSatisfy { $0.safety == .rebuilds })
        let depots = try #require(items.first { $0.ruleID == "game.steam.depotcache" })
        #expect(depots.paths.count == 2 && depots.rebuild == .download)
        let paths = items.flatMap(\.paths).map(\.path)
        #expect(!paths.contains { $0.contains("Steam.AppBundle") || $0.contains("/config") })

        // Steam ouvert : rien n'est proposé.
        let open = await RuleEngine.collect(home.context(runningApps: ["com.valvesoftware.steam"]), finders: [.games])
        #expect(open.allSatisfy { $0.protections == [.appRunning(name: "Steam")] })
    }

    @Test("Steam : un dossier de jeu sans manifeste est un reste, à examiner")
    func steamLeftovers() async throws {
        let home = try FakeHome()
        let steamapps = "Library/Application Support/Steam/steamapps"
        try home.text("\(steamapps)/appmanifest_620.acf", """
        "AppState"
        {
        \t"appid"\t\t"620"
        \t"name"\t\t"Portal 2"
        \t"installdir"\t\t"Portal 2"
        }
        """)
        try home.file("\(steamapps)/common/Portal 2/portal2.app/a", bytes: heavy)
        try home.file("\(steamapps)/common/Vieux Jeu/mods/a.pak", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.games])

        let leftovers = items.filter { $0.ruleID == "game.steam.leftover" }
        #expect(leftovers.map(\.title) == ["Vieux Jeu"])
        let leftover = try #require(leftovers.first)
        #expect(leftover.safety == .review && leftover.method == .trash && leftover.protections.isEmpty)
        #expect(!PreselectionPolicy().preselects(leftover))
    }

    @Test("Steam : un manifeste illisible, et aucun reste n'est proposé")
    func unreadableManifestProtects() async throws {
        let home = try FakeHome()
        let steamapps = "Library/Application Support/Steam/steamapps"
        try home.text("\(steamapps)/appmanifest_620.acf", "\"AppState\" { tronqué")
        try home.file("\(steamapps)/common/Portal 2/a", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.games])

        let leftover = try #require(items.first { $0.ruleID == "game.steam.leftover" })
        #expect(leftover.protections == [.unknownState] && !leftover.isSelectable)
    }

    @Test("Les fichiers VDF de Steam : guillemets et échappements")
    func vdf() {
        let text = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"/Volumes/Jeux \\"SSD\\""
        \t}
        \t"PATH"  "C:\\\\Steam"
        \t"label"\t""
        }
        """
        #expect(GamesFinder.vdfValues("path", in: text) == ["/Volumes/Jeux \"SSD\"", "C:\\Steam"])
        #expect(GamesFinder.vdfValues("label", in: text) == [""])
        #expect(GamesFinder.vdfValues("installdir", in: text).isEmpty)
    }

    @Test("Epic : les assets du Vault à examiner, un élément par pack ; son ancien cache web n'est pas le nôtre")
    func epicVault() async throws {
        let home = try FakeHome()
        let saved = "Library/Application Support/Epic/EpicGamesLauncher/Saved"
        try home.file("\(saved)/webcache/Cache/a", bytes: heavy)
        try home.file("\(saved)/Config/Mac/GameUserSettings.ini", bytes: heavy)
        try home.file("_Shared/UnrealEngine/Launcher/VaultCache/CityPackV1/data/a.chunk", bytes: heavy)
        try home.file("_Shared/UnrealEngine/Launcher/VaultCache/ForestV2/data/b.chunk", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.games])

        // Le cache web d'Epic est dans ~/Library/Caches (aide d'Epic) : la règle des caches d'applications.
        #expect(!items.flatMap(\.paths).contains { $0.path.contains("/Saved/") })
        let vault = items.filter { $0.ruleID == "game.epic.vault" }
        #expect(vault.map(\.title) == ["CityPackV1", "ForestV2"])
        #expect(vault.allSatisfy { $0.safety == .review && !PreselectionPolicy().preselects($0) })
    }

    @Test("Epic : un jeu que le lanceur ne connaît plus est un reste ; sans sa liste, tout est protégé")
    func epicLeftovers() async throws {
        let home = try FakeHome()
        try home.file("_Shared/Epic Games/Fortnite/FortniteClient.app/a", bytes: heavy)
        try home.file("_Shared/Epic Games/AncienJeu/a.pak", bytes: heavy)

        let unknown = await RuleEngine.collect(home.context(), finders: [.games])
        #expect(unknown.count == 2)
        #expect(unknown.allSatisfy { $0.ruleID == "game.epic.leftover" && $0.protections == [.unknownState] })

        let installed = home.root.appendingPathComponent("_Shared/Epic Games/Fortnite/").path
        try home.text("Library/Application Support/Epic/UnrealEngineLauncher/LauncherInstalled.dat",
                      #"{"InstallationList": [{"InstallLocation": "\#(installed)", "AppName": "Fortnite"}]}"#)
        let items = await RuleEngine.collect(home.context(), finders: [.games])

        let leftover = try #require(items.first)
        #expect(items.count == 1 && leftover.title == "AncienJeu")
        #expect(leftover.safety == .review && leftover.method == .trash && leftover.protections.isEmpty)
    }

    @Test("GOG Galaxy : le cache web de /Users/Shared, protégé tant que Galaxy est ouvert")
    func gog() async throws {
        let home = try FakeHome()
        try home.file("_Shared/GOG.com/Galaxy/WebCache/common/a", bytes: heavy)
        try home.file("_Shared/GOG.com/Galaxy/Storage/galaxy-2.0.db", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.games])

        let web = try #require(items.first)
        #expect(items.count == 1 && web.ruleID == "game.gog.webcache" && web.safety == .safe)
        let open = await RuleEngine.collect(home.context(runningApps: ["com.gog.galaxy"]), finders: [.games])
        #expect(open.first?.protections == [.appRunning(name: "GOG Galaxy")])
    }
}

@Suite("Adobe, CapCut, Filmora et Plex")
struct MoreCreativeAppsTests {

    @Test("Adobe : le Media Cache et sa base, rien d'autre de Common")
    func adobe() async throws {
        let home = try FakeHome()
        let common = "Library/Application Support/Adobe/Common"
        try home.file("\(common)/Media Cache Files/clip.pek", bytes: heavy)
        try home.file("\(common)/Media Cache/db.sqlite", bytes: heavy)
        try home.file("\(common)/Motion Graphics Templates/titre.mogrt", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        let cache = try #require(items.first { $0.ruleID == "creative.adobe.media_cache" })
        #expect(cache.paths.map(\.lastPathComponent) == ["Media Cache Files", "Media Cache"])
        #expect(cache.safety == .rebuilds && cache.method == .removeNow && cache.category == .creative)
        #expect(!items.flatMap(\.paths).contains { $0.path.contains("Motion Graphics") })

        let open = await RuleEngine.collect(home.context(runningApps: ["com.adobe.PremierePro.25"]), finders: [.creative])
        #expect(open.first?.protections == [.appRunning(name: "Premiere Pro")])
    }

    @Test("Adobe : un fichier du cache ouvert (After Effects, Media Encoder…) le protège")
    func adobeOpenFile() async throws {
        let home = try FakeHome()
        try home.file("Library/Application Support/Adobe/Common/Media Cache/db.sqlite", bytes: heavy)
        let handle = try FileHandle(forReadingFrom:
            home.root.appendingPathComponent("Library/Application Support/Adobe/Common/Media Cache/db.sqlite"))
        defer { try? handle.close() }

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        #expect(items.first?.protections == [.appRunning(name: "Adobe")])
    }

    @Test("CapCut : son cache sans les brouillons synchronisés ni les projets")
    func capCut() async throws {
        let home = try FakeHome()
        let data = "Movies/CapCut/User Data"
        try home.file("\(data)/Cache/effect/e.bundle", bytes: heavy)
        try home.file("\(data)/Cache/VENetworkPlayer/v.cache", bytes: heavy)
        try home.file("\(data)/Cache/cloudDraft/d.json", bytes: heavy)
        try home.file("\(data)/Cache/Bytesync/s.db", bytes: heavy)
        try home.file("\(data)/Projects/com.lveditor.draft/projet/draft.json", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        let cache = try #require(items.first { $0.ruleID == "creative.capcut.cache" })
        #expect(cache.paths.map(\.lastPathComponent) == ["VENetworkPlayer", "effect"])
        #expect(cache.safety == .rebuilds && cache.rebuild == .download)
    }

    @Test("Filmora : ses fichiers temporaires, pas ses téléchargements")
    func filmora() async throws {
        let home = try FakeHome()
        let data = "Library/Application Support/Wondershare Filmora Mac/ProgramData"
        try home.file("\(data)/Temp/MediaInfo/a.json", bytes: heavy)
        try home.file("\(data)/Download/Category/b.zip", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        let temp = try #require(items.first { $0.ruleID == "creative.filmora.temp" })
        #expect(temp.paths.map(\.lastPathComponent) == ["Temp"] && temp.safety == .safe)
        #expect(items.count == 1)
    }

    @Test("Plex : les mises à jour déjà installées, pas celle qui attend")
    func plexUpdates() async throws {
        let home = try FakeHome()
        let updates = "Library/Application Support/Plex Media Server/Updates"
        try home.file("\(updates)/1.43.3.10896-cb3ebc72d/packages/a.zip", bytes: heavy)
        try home.file("\(updates)/1.43.4.10903-e5521bd8c/packages/b.zip", bytes: heavy)
        try home.file("\(updates)/1.44.0.11000-0123abcd/packages/c.zip", bytes: heavy)

        // Sans l'application, on ne sait pas ce qui est installé.
        let unknown = await RuleEngine.collect(home.context(), finders: [.creative])
        #expect(unknown.first?.protections == [.unknownState])

        try home.text("_Applications/Plex Media Server.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleVersion</key><string>1.43.4.10903</string></dict></plist>
        """)
        let items = await RuleEngine.collect(home.context(), finders: [.creative])

        let plex = try #require(items.first { $0.ruleID == "creative.plex.updates" })
        #expect(plex.paths.map(\.lastPathComponent) == ["1.43.3.10896-cb3ebc72d", "1.43.4.10903-e5521bd8c"])
        #expect(plex.safety == .safe && plex.protections.isEmpty)
        let open = await RuleEngine.collect(home.context(runningApps: ["com.plexapp.plexmediaserver"]),
                                            finders: [.creative])
        #expect(open.first?.protections == [.appRunning(name: "Plex Media Server")])
    }
}

@Suite("Caches rangés dans Application Support : Electron, Telegram")
struct AppDataCachesTests {

    @Test("Electron : les caches de Chromium d'un profil et de ses partitions, rien d'autre")
    func electron() async throws {
        let home = try FakeHome()
        let support = "Library/Application Support"
        try home.text("\(support)/Notion/Preferences", "{}")
        try home.file("\(support)/Notion/Cache/Cache_Data/data_1", bytes: heavy)
        try home.file("\(support)/Notion/Code Cache/js/a", bytes: heavy)
        try home.file("\(support)/Notion/GPUCache/data_0", bytes: heavy)
        try home.file("\(support)/Notion/Partitions/notion/Cache/Cache_Data/b", bytes: heavy)
        try home.file("\(support)/Notion/Service Worker/CacheStorage/c", bytes: heavy)
        try home.file("\(support)/Notion/IndexedDB/d", bytes: heavy)
        try home.file("\(support)/Notion/Local Storage/leveldb/e", bytes: heavy)
        // Un profil sous le dossier d'un éditeur.
        try home.text("\(support)/Microsoft/Skype for Desktop/Preferences", "{}")
        try home.file("\(support)/Microsoft/Skype for Desktop/Cache/Cache_Data/f", bytes: heavy)
        // Un profil « Default » prend le nom de son application.
        try home.text("\(support)/Codex/Default/Preferences", "{}")
        try home.file("\(support)/Codex/Default/GPUCache/data_0", bytes: heavy)
        // Écartés : navigateur, agent, mots de passe, identifiant, dossier sans réglages.
        try home.text("\(support)/Google/Chrome/Default/Preferences", "{}")
        try home.file("\(support)/Google/Chrome/Default/Cache/g", bytes: heavy)
        try home.text("\(support)/Cursor/Preferences", "{}")
        try home.file("\(support)/Cursor/Cache/h", bytes: heavy)
        try home.text("\(support)/1Password/Preferences", "{}")
        try home.file("\(support)/1Password/Partitions/1password/GPUCache/i", bytes: heavy)
        try home.text("\(support)/com.example.app/Preferences", "{}")
        try home.file("\(support)/com.example.app/Cache/j", bytes: heavy)
        try home.file("\(support)/PasElectron/Cache/k", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.appData])

        #expect(items.map(\.title).sorted() == ["Codex", "Notion", "Skype for Desktop"])
        let notion = try #require(items.first { $0.title == "Notion" })
        #expect(notion.ruleID == "cache.electron" && notion.category == .appCaches && notion.safety == .safe)
        #expect(Set(notion.paths.compactMap { $0.path.components(separatedBy: "/Notion/").last })
            == ["Cache", "Code Cache", "GPUCache", "Partitions/notion/Cache"])
        #expect(PreselectionPolicy().preselects(notion))
    }

    @Test("Electron : application ouverte, ses fichiers de cache le sont aussi, et tout est protégé")
    func electronOpen() async throws {
        let home = try FakeHome()
        let support = "Library/Application Support"
        try home.text("\(support)/Notion/Preferences", "{}")
        try home.file("\(support)/Notion/Cache/Cache_Data/data_1", bytes: heavy)
        try home.file("\(support)/Notion/GPUCache/data_0", bytes: heavy)
        let gpu = home.root.appendingPathComponent("\(support)/Notion/GPUCache")
        let handle = try FileHandle(forReadingFrom: gpu.appendingPathComponent("data_0"))
        defer { try? handle.close() }

        let items = await RuleEngine.collect(home.context(), finders: [.appData])

        #expect(items.first?.protections == [.appRunning(name: "Notion")])
        // Et juste avant d'agir : la même question, posée par la revalidation.
        #expect(AppOwnership.runningOwner(ruleID: "cache.electron", paths: [gpu], running: []) == "Notion")
        try handle.close()
        #expect(AppOwnership.runningOwner(ruleID: "cache.electron", paths: [gpu], running: []) == nil)
    }

    @Test("Telegram Desktop : fichiers et médias en cache de chaque compte, pas la session")
    func telegram() async throws {
        let home = try FakeHome()
        let tdata = "Library/Application Support/Telegram Desktop/tdata"
        try home.file("\(tdata)/user_data/cache/0/a", bytes: heavy)
        try home.file("\(tdata)/user_data#2/media_cache/b", bytes: heavy)
        try home.file("\(tdata)/D877F783D5D3EF8C/maps", bytes: heavy)
        try home.file("\(tdata)/emoji/set_1", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.appData])

        let cache = try #require(items.first { $0.ruleID == "cache.telegram" })
        #expect(cache.paths.map(\.lastPathComponent) == ["cache", "media_cache"])
        #expect(cache.safety == .safe && cache.rebuild == .download && items.count == 1)
    }
}

@Suite("Autres lanceurs : Battle.net, Prism, Heroic, Roblox")
struct OtherLaunchersTests {

    @Test("Chaque cache documenté, jamais les comptes, les instances ni les jeux")
    func launchers() async throws {
        let home = try FakeHome()
        try home.file("_Shared/Blizzard/Battle.net/Cache/a", bytes: heavy)
        try home.file("_Shared/Battle.net/Agent/agent.db", bytes: heavy)
        let prism = "Library/Application Support/PrismLauncher"
        try home.file("\(prism)/cache/b.jar", bytes: heavy)
        try home.file("\(prism)/meta/net.minecraft/index.json", bytes: heavy)
        try home.file("\(prism)/instances/Survie/minecraft/saves/monde/level.dat", bytes: heavy)
        try home.text("\(prism)/accounts.json", "{}")
        let heroic = "Library/Application Support/heroic"
        try home.file("\(heroic)/images-cache/c.jpg", bytes: heavy)
        try home.file("\(heroic)/store_cache/d.json", bytes: heavy)
        try home.file("\(heroic)/legendaryConfig/legendary/user.json", bytes: heavy)
        try home.file("Library/Logs/Roblox/0.650_log.txt", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.games])

        #expect(Set(items.map(\.ruleID)) == ["game.battlenet.cache", "game.prism.cache", "game.heroic.cache",
                                             "game.roblox.logs"])
        #expect(items.allSatisfy { $0.category == .games && $0.protections.isEmpty })
        let paths = items.flatMap(\.paths).map(\.path)
        for kept in ["Agent", "instances", "accounts.json", "legendaryConfig"] {
            #expect(!paths.contains { $0.contains(kept) }, "pris à tort : \(kept)")
        }

        let open = await RuleEngine.collect(home.context(runningApps: ["org.prismlauncher.PrismLauncher"]),
                                            finders: [.games])
        #expect(open.first { $0.ruleID == "game.prism.cache" }?.protections == [.appRunning(name: "Prism Launcher")])
    }
}

@Suite("Logiciels pro : photo, audio, vidéo, 3D, CAO")
struct ProAppsTests {

    @Test("Emplacements fixes : chaque cache documenté, rien de ce qui est à côté")
    func fixedCaches() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/Ableton/Cache/Decoding/a.asd", bytes: heavy)
        try home.file("_Shared/Pro Tools/WaveCache.wfm", bytes: heavy)
        try home.file("_Shared/Pro Tools/Workspace.wksp", bytes: heavy)
        try home.file("_Shared/AvidMediaComposer/AvidImageCache/i", bytes: heavy)
        try home.file("_Shared/AvidMediaComposer/Avid Attic/bin.avb", bytes: heavy)
        try home.file("Library/Preferences/Maxon/Maxon Cinema 4D 2025_ABCD/redshift/cache/s.rscache", bytes: heavy)
        try home.file("Library/Preferences/Maxon/Maxon Cinema 4D 2025_ABCD/userrepository/u", bytes: heavy)
        try home.file("redshift/cache/t.rstexbin", bytes: heavy)
        try home.file("Library/Application Support/Redshift/TextureCache/x.tx", bytes: heavy)
        try home.file("Library/Preferences/Maxon/_assetcache/a.asset", bytes: heavy)
        try home.file("Library/Caches/Unity/upm/db/p", bytes: heavy)
        try home.file("Library/Unity/Asset Store-5.x/Publisher/Pack.unitypackage", bytes: heavy)
        try home.file("Library/Application Support/Epic/UnrealEngine/Common/Zen/Data/cas/c", bytes: heavy)
        try home.file("Library/Caches/Godot/thumbnails/t.png", bytes: heavy)
        try home.file("Library/Application Support/Autodesk/local/AutoCAD 2025/R25.0/fr_FR/GraphicsCache/g", bytes: heavy)
        try home.file("Library/Caches/Graphisoft/lib", bytes: heavy)
        try home.file("Library/Caches/Adobe InDesign/Version 20.0/fr_FR/InDesign ClipboardScrap1.pdf", bytes: heavy)
        try home.file("Library/Caches/Adobe InDesign/Version 20.0/InDesign Recovery/doc.idlk", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.pro])
        let rules = Set(items.map(\.ruleID))

        #expect(rules == ["creative.ableton.cache", "creative.protools.wavecache", "creative.avid.cache",
                          "creative.redshift.cache", "creative.maxon.assetcache", "creative.unity.cache",
                          "creative.unity.asset_store", "creative.unreal.ddc", "creative.godot.cache",
                          "creative.autocad.graphics_cache", "creative.archicad.cache", "creative.indesign.cache"])
        #expect(items.allSatisfy { $0.category == .creative && $0.protections.isEmpty })
        #expect(items.first { $0.ruleID == "creative.redshift.cache" }?.paths.count == 3)
        #expect(items.first { $0.ruleID == "creative.protools.wavecache" }?.paths.map(\.lastPathComponent) == ["WaveCache.wfm"])
        #expect(items.first { $0.ruleID == "creative.indesign.cache" }?.paths.map(\.lastPathComponent) == ["fr_FR"])
        // Ce qu'on ne prend jamais.
        let paths = items.flatMap(\.paths).map(\.path)
        for kept in ["Workspace.wksp", "Avid Attic", "userrepository", "InDesign Recovery"] {
            #expect(!paths.contains { $0.contains(kept) }, "pris à tort : \(kept)")
        }
        // Les packs de l'Asset Store et l'Asset Browser se retéléchargent : à examiner.
        for rule in ["creative.unity.asset_store", "creative.maxon.assetcache"] {
            let item = try #require(items.first { $0.ruleID == rule })
            #expect(item.safety == .review && !PreselectionPolicy().preselects(item))
        }
    }

    @Test("Un fichier du cache ouvert : l'application tourne, c'est protégé, maintenant comme avant d'agir")
    func openFileProtects() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/Godot/thumbnails/t.png", bytes: heavy)
        let file = home.root.appendingPathComponent("Library/Caches/Godot/thumbnails/t.png")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let items = await RuleEngine.collect(home.context(), finders: [.pro])

        let godot = try #require(items.first)
        #expect(godot.protections == [.appRunning(name: "Godot")])
        #expect(AppOwnership.runningOwner(ruleID: "creative.godot.cache", paths: godot.paths, running: []) == "Godot")
    }

    @Test("Lightroom Classic : les aperçus d'un catalogue, jamais les aperçus dynamiques")
    func lightroom() async throws {
        let home = try FakeHome()
        let folder = "Pictures/Lightroom"
        try home.file("\(folder)/Lightroom Catalog.lrcat", bytes: heavy)
        try home.file("\(folder)/Lightroom Catalog Previews.lrdata/0/a.lrprev", bytes: heavy)
        try home.file("\(folder)/Lightroom Catalog Smart Previews.lrdata/0/b.dng", bytes: heavy)
        // Des aperçus sans leur catalogue : on ne sait pas à quoi ils servent.
        try home.file("Pictures/Ailleurs/Orphelin Previews.lrdata/c.lrprev", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.pro])

        let previews = try #require(items.first { $0.ruleID == "creative.lightroom.previews" })
        #expect(items.count == 1 && previews.title == "Lightroom Catalog")
        #expect(previews.paths.map(\.lastPathComponent) == ["Lightroom Catalog Previews.lrdata"])
        #expect(previews.safety == .rebuilds && previews.method == .removeNow)

        // Catalogue ouvert : Lightroom pose un .lrcat.lock à côté.
        try home.text("\(folder)/Lightroom Catalog.lrcat.lock", "")
        let open = await RuleEngine.collect(home.context(), finders: [.pro])
        #expect(open.first?.protections == [.appRunning(name: "Lightroom Classic")])
        #expect(AppOwnership.runningOwner(ruleID: "creative.lightroom.previews", paths: previews.paths, running: [])
            == "Lightroom Classic")
    }

    @Test("Capture One : le cache des catalogues et des sessions, jamais les réglages")
    func captureOne() async throws {
        let home = try FakeHome()
        try home.file("Pictures/Capture One Catalog.cocatalog/Cache/Proxies/a.cop", bytes: heavy)
        try home.file("Pictures/Capture One Catalog.cocatalog/Capture One Catalog.cocatalogdb", bytes: heavy)
        try home.file("Pictures/Sessions/Mariage/Capture/CaptureOne/Cache/Thumbnails/b.cot", bytes: heavy)
        try home.file("Pictures/Sessions/Mariage/Capture/CaptureOne/Settings153/IMG_1.cos", bytes: heavy)
        // Un dossier « CaptureOne » sans réglages : pas forcément le sien.
        try home.file("Pictures/Divers/CaptureOne/Cache/c", bytes: heavy)

        let items = await RuleEngine.collect(home.context(), finders: [.pro])

        #expect(Set(items.map(\.title)) == ["Capture One Catalog", "Capture"])
        #expect(items.allSatisfy { $0.ruleID == "creative.captureone.cache" && $0.paths.map(\.lastPathComponent) == ["Cache"] })
        #expect(!items.flatMap(\.paths).contains { $0.path.contains("Settings") || $0.path.contains("Divers") })
    }
}

@Suite("L'application propriétaire, revérifiée juste avant d'agir")
struct CreativeGamesOwnershipTests {
    @Test("Chaque règle des créatifs et des joueurs connaît son application")
    func owners() {
        let path = [URL(fileURLWithPath: "/x/y")]
        #expect(AppOwnership.runningOwner(ruleID: "creative.library.transcoded", paths: path,
                                          running: ["com.apple.iMovieApp"]) == "iMovie")
        #expect(AppOwnership.runningOwner(ruleID: "creative.library.render", paths: path,
                                          running: ["com.apple.FinalCutTrial"]) == "Final Cut Pro")
        #expect(AppOwnership.runningOwner(ruleID: "creative.resolve.proxy", paths: path,
                                          running: ["com.blackmagic-design.DaVinciResolveStudio"]) == "DaVinci Resolve")
        #expect(AppOwnership.runningOwner(ruleID: "creative.sound_library", paths: path,
                                          running: ["com.apple.logic10"]) == "Logic Pro")
        #expect(AppOwnership.runningOwner(ruleID: "game.epic.vault", paths: path,
                                          running: ["com.epicgames.EpicGamesLauncher"]) == "Epic Games Launcher")
        #expect(AppOwnership.runningOwner(ruleID: "game.steam.leftover", paths: path,
                                          running: ["com.gog.galaxy"]) == nil)
        #expect(AppOwnership.runningOwner(ruleID: "creative.blender.cache", paths: path,
                                          running: ["com.apple.iMovieApp"]) == nil)
    }

    @Test("Chaque règle est au catalogue")
    func catalog() {
        let ids = ["creative.library.render", "creative.library.transcoded", "creative.resolve.cache",
                   "creative.resolve.proxy", "creative.resolve.gallery", "creative.insta360.cache",
                   "creative.insta360.proxy", "creative.blender.cache", "creative.blender.temp",
                   "creative.sound_library", "game.steam.appcache", "game.steam.shadercache",
                   "game.steam.depotcache", "game.steam.leftover", "game.epic.vault",
                   "game.epic.leftover", "game.gog.webcache", "cache.electron", "cache.telegram",
                   "creative.adobe.media_cache", "creative.capcut.cache", "creative.filmora.temp",
                   "creative.plex.updates", "creative.ableton.cache", "creative.lightroom.previews",
                   "creative.captureone.cache", "creative.unreal.ddc"]
        #expect(Set(ids).isSubset(of: Set(RuleCatalog.ruleIDs)))
    }
}
