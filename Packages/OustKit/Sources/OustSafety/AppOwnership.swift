import Foundation

/// À quelle application appartient ce qu'on s'apprête à retirer, pour vérifier
/// qu'elle n'est pas ouverte : au moment de l'analyse, puis juste avant d'agir.
///
/// Une application ouverte écrit dans son cache ; Mail et Messages tiennent
/// leurs pièces jointes. On ne retire rien sous leurs pieds.
public enum AppOwnership {

    /// Le cache d'un assistant (« com.spotify.client.helper ») appartient à son
    /// application, et réciproquement.
    public static func cache(_ name: String, belongsTo bundleID: String) -> Bool {
        let name = name.lowercased()
        let bundle = bundleID.lowercased()
        return name == bundle || name.hasPrefix(bundle + ".") || bundle.hasPrefix(name + ".")
    }

    static let mail = "com.apple.mail"
    static let messages = "com.apple.MobileSMS"

    /// Parmi les applications ouvertes, celle qui possède ce qu'une règle propose ;
    /// `nil` si aucune ne l'est (ou si la règle ne dépend d'aucune application).
    public static func runningOwner(ruleID: String, paths: [URL], running: Set<String>) -> String? {
        switch ruleID {
        case "cache.app":
            guard let folder = paths.first?.lastPathComponent else { return nil }
            return running.first { cache(folder, belongsTo: $0) }
        case "attachments.mail":
            return running.contains(mail) ? "Mail" : nil
        case "attachments.messages":
            return running.contains(messages) ? "Messages" : nil
        case "creative.lightroom.previews":
            // Un catalogue ouvert pose « <catalogue>.lrcat.lock » à côté de lui.
            return paths.contains(where: lightroomCatalogIsOpen) ? "Lightroom Classic" : nil
        case "browser.cache", "browser.history", "browser.cookies":
            return browserOwner(paths: paths, running: running)
        default:
            return creativeOrGameOwner(ruleID: ruleID, running: running) ?? openFileOwner(ruleID: ruleID, paths: paths)
        }
    }

    /// Les applications qui écrivent dans ce que proposent les règles des
    /// créatifs et des joueurs, par préfixe de règle. Un préfixe d'identifiant
    /// suffit : « …DaVinciResolve » couvre la version de l'App Store (« …Lite »)
    /// comme Studio, « com.apple.FinalCut » l'essai.
    ///
    /// Final Cut Pro ouvre aussi les bibliothèques d'iMovie : l'une ou l'autre
    /// ouverte, on ne touche à aucune.
    static let creativeAndGameApps: [(rule: String, name: String, bundle: String)] = [
        ("creative.library.", "Final Cut Pro", "com.apple.FinalCut"),
        ("creative.library.", "iMovie", "com.apple.iMovieApp"),
        ("creative.resolve.", "DaVinci Resolve", "com.blackmagic-design.DaVinciResolve"),
        ("creative.insta360.", "Insta360 Studio", "com.insta360.studio"),
        ("creative.blender.", "Blender", "org.blenderfoundation.blender"),
        ("creative.sound_library", "GarageBand", "com.apple.garageband10"),
        ("creative.sound_library", "Logic Pro", "com.apple.logic10"),
        ("creative.sound_library", "MainStage", "com.apple.mainstage3"),
        // « com.adobe.PremierePro.22 », « …PremierePro.CC13 » : l'identifiant change à chaque version.
        ("creative.adobe.", "Premiere Pro", "com.adobe.PremierePro"),
        ("creative.plex.", "Plex Media Server", "com.plexapp.plexmediaserver"),
        ("game.steam.", "Steam", "com.valvesoftware.steam"),
        ("game.epic.", "Epic Games Launcher", "com.epicgames.EpicGamesLauncher"),
        ("game.gog.", "GOG Galaxy", "com.gog.galaxy"),
        // Identifiants lus dans les dépôts des projets (CMakeLists.txt, electron-builder.yml).
        ("game.prism.", "Prism Launcher", "org.prismlauncher.PrismLauncher"),
        ("game.heroic.", "Heroic", "com.heroicgameslauncher.hgl"),
    ]

    /// Les règles dont l'application ne se reconnaît pas à son identifiant : une
    /// application Electron s'appelle « Notion » dans Application Support, After
    /// Effects et Media Encoder partagent le Media Cache de Premiere. Un fichier
    /// ouvert dedans suffit à dire qu'elle tourne : le 18/10/2026, Claude et
    /// Discord ouverts tenaient des fichiers de `Cache` et de `GPUCache`, Notion
    /// et Canva fermés aucun. Le nom vide se lit dans le chemin.
    static let openFileRules: [String: String] = [
        "cache.electron": "", "cache.telegram": "Telegram", "creative.adobe.media_cache": "Adobe",
        "creative.capcut.cache": "CapCut", "creative.filmora.temp": "Filmora",
        "creative.ableton.cache": "Ableton Live", "creative.protools.wavecache": "Pro Tools",
        "creative.avid.cache": "Media Composer", "creative.redshift.cache": "Redshift",
        "creative.maxon.assetcache": "Cinema 4D", "creative.unity.cache": "Unity", "creative.unity.asset_store": "Unity",
        "creative.unreal.ddc": "Unreal Engine", "creative.godot.cache": "Godot",
        "creative.autocad.graphics_cache": "AutoCAD", "creative.archicad.cache": "Archicad",
        "creative.indesign.cache": "InDesign", "creative.captureone.cache": "Capture One",
        "game.battlenet.cache": "Battle.net", "game.roblox.logs": "Roblox",
    ]

    static func openFileOwner(ruleID: String, paths: [URL]) -> String? {
        guard let name = openFileRules[ruleID], let first = paths.first,
              paths.contains(where: { !OpenFiles.paths(under: $0.path).isEmpty }) else { return nil }
        return name.isEmpty ? applicationSupportFolder(of: first) ?? first.lastPathComponent : name
    }

    /// « Catalogue Previews.lrdata » → « Catalogue.lrcat.lock » existe-t-il ?
    static func lightroomCatalogIsOpen(_ previews: URL) -> Bool {
        let name = previews.lastPathComponent
        guard name.hasSuffix(" Previews.lrdata") else { return false }
        let catalog = String(name.dropLast(" Previews.lrdata".count))
        let lock = previews.deletingLastPathComponent().appendingPathComponent(catalog + ".lrcat.lock")
        return FileManager.default.fileExists(atPath: lock.path)
    }

    /// « …/Application Support/Notion/Partitions/notion/Cache » → « Notion ».
    public static func applicationSupportFolder(of url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard let index = components.lastIndex(of: "Application Support"), index + 1 < components.count else { return nil }
        return components[index + 1]
    }

    /// Les navigateurs, reconnus aux dossiers de leurs profils et de leurs
    /// caches (SPEC §8 : navigateur fermé exigé). L'analyse protège déjà ce
    /// qu'un navigateur ouvert possède ; mais il a pu s'ouvrir depuis, et
    /// l'entretien compte ses caches comme s'il était fermé, la revue
    /// proposant de le fermer. Juste avant d'agir, un navigateur ouvert garde
    /// donc ce qui est à lui. `OustBrowsersTests` vérifie que chaque profil
    /// connu y retrouve son navigateur.
    static let browserApps: [(name: String, bundle: String, folders: [String])] = [
        ("Safari", "com.apple.Safari",
         ["/Library/Safari/", "/Library/Caches/com.apple.Safari/", "/Library/Containers/com.apple.Safari/",
          "/Library/Cookies/"]),
        ("Google Chrome", "com.google.Chrome",
         ["/Library/Application Support/Google/Chrome/", "/Library/Caches/Google/Chrome/"]),
        ("Arc", "company.thebrowser.Browser", ["/Library/Application Support/Arc/", "/Library/Caches/Arc/"]),
        ("Brave", "com.brave.Browser",
         ["/Library/Application Support/BraveSoftware/", "/Library/Caches/BraveSoftware/"]),
        ("Microsoft Edge", "com.microsoft.edgemac",
         ["/Library/Application Support/Microsoft Edge/", "/Library/Caches/Microsoft Edge/"]),
        ("Vivaldi", "com.vivaldi.Vivaldi", ["/Library/Application Support/Vivaldi/", "/Library/Caches/Vivaldi/"]),
        ("Opera", "com.operasoftware.Opera",
         ["/Library/Application Support/com.operasoftware.Opera/", "/Library/Caches/com.operasoftware.Opera/"]),
        ("Firefox", "org.mozilla.firefox", ["/Library/Application Support/Firefox/", "/Library/Caches/Firefox/"]),
    ]

    static func browserOwner(paths: [URL], running: Set<String>) -> String? {
        browserApps.first { entry in
            running.contains(entry.bundle) && paths.contains { path in
                let candidate = path.standardizedFileURL.path + "/"
                return entry.folders.contains { candidate.contains($0) }
            }
        }?.name
    }

    static func creativeOrGameOwner(ruleID: String, running: Set<String>) -> String? {
        let running = running.map { $0.lowercased() }
        return creativeAndGameApps.first { entry in
            ruleID.hasPrefix(entry.rule) && running.contains { $0.hasPrefix(entry.bundle.lowercased()) }
        }?.name
    }
}
