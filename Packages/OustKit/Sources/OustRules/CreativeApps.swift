import Darwin
import Foundation
import OustCore
import OustSafety
import OustScan

/// Ce que les logiciels de création laissent derrière eux : rendus et médias
/// transcodés de Final Cut Pro et d'iMovie, caches de DaVinci Resolve,
/// d'Insta360 Studio et de Blender, sons de GarageBand et de Logic Pro.
///
/// Chaque chemin a été relevé sur un Mac le 18/10/2026, ou, quand l'application
/// n'y avait encore rien écrit, dans ses propres binaires : le framework Flexo
/// d'iMovie (celui de Final Cut Pro) nomme `Render Files` et `Transcoded Media`,
/// Resolve écrit `RenderCaching.CacheDir = CacheClip`. Pour Adobe, absent de ce
/// Mac, c'est l'aide officielle qui fait foi : rien n'est deviné.
///
/// Jamais une bibliothèque ni ses médias d'origine, seulement ce que
/// l'application recalcule ; tout est protégé tant qu'elle est ouverte.
struct CreativeAppsFinder {
    let context: RuleContext

    /// Cent caches de quelques kilo-octets noieraient ceux qui pèsent.
    static let minimumAllocated: Int64 = 1_000_000

    func find() async -> [Candidate] {
        // Sur un autre disque, ce que ces logiciels y rangent : leurs
        // bibliothèques et les dossiers de travail qu'on leur a choisis là.
        let candidates = context.volume != nil || context.volumeAnchor != nil
            ? await videoLibraries() + volumeResolveCaches() + volumeAdobeMediaCaches()
            : await videoLibraries() + resolve() + insta360() + blender() + soundLibrary()
                + adobeMediaCache() + capCut() + filmora() + plexUpdates()
        return candidates.map { candidate in
            var candidate = candidate
            if let owner = AppOwnership.runningOwner(ruleID: candidate.item.ruleID, paths: candidate.item.paths,
                                                     running: context.runningApps) {
                candidate.item.protect(.appRunning(name: owner))
            }
            return candidate
        }
    }

    func candidate(_ title: String, detail: URL, paths: [URL], owner: String, rule: String, safety: SafetyClass,
                   method: CleanupMethod, rebuild: RebuildCost) -> Candidate {
        Candidate(item: CleanupItem(
            title: title, detail: detail.abbreviated(home: context.home), paths: paths, category: .creative,
            owner: owner, ruleID: rule, safety: safety, method: method, rebuild: rebuild
        ), minimumAllocated: Self.minimumAllocated)
    }

    /// Les dossiers qui existent vraiment, liens symboliques écartés : un lien
    /// vers un disque externe ne se vide pas d'ici.
    func existing(_ urls: [URL]) -> [URL] {
        if let anchor = context.volumeAnchor {
            return urls.filter {
                guard let facts = VolumeDirectory.entry($0, in: anchor).facts else { return false }
                return facts.mode & S_IFMT == S_IFDIR
            }
        }
        return urls.filter { FileManager.default.isDirectory($0) && !$0.isSymbolicLink }
    }

    // MARK: - Final Cut Pro et iMovie

    /// Le paquet d'une bibliothèque, et l'application qui l'a créé.
    static let libraryApps = ["fcpbundle": "Final Cut Pro", "imovielibrary": "iMovie"]

    /// Dans chaque événement d'une bibliothèque, les rendus (recalculés en tâche
    /// de fond ou à l'export) et les médias transcodés (optimisés et proxys).
    ///
    /// Les médias transcodés sont « à examiner » : sans les originaux, débranchés
    /// ou effacés, ils sont la seule copie lisible des plans.
    func videoLibraries() async -> [Candidate] {
        var candidates: [Candidate] = []
        for library in await libraries() {
            let app = Self.libraryApps[library.pathExtension.lowercased()] ?? "Final Cut Pro"
            let name = library.deletingPathExtension().lastPathComponent
            let events: [URL]
            if context.volumeAnchor != nil {
                events = (context.volumeEntries(in: library) ?? []).compactMap { entry in
                    let name = entry.url.lastPathComponent
                    guard entry.facts.mode & S_IFMT == S_IFDIR, !name.hasPrefix("."),
                          !VolumeProtection.isTimeMachineName(name), !VolumePackages.isPackage(name)
                    else { return nil }
                    return entry.url
                }
            } else {
                events = existing(FileManager.default.children(of: library))
            }
            let renders = existing(events.map { $0.appendingPathComponent("Render Files") })
            let transcoded = existing(events.map { $0.appendingPathComponent("Transcoded Media") })
            if !renders.isEmpty {
                candidates.append(candidate(name, detail: library, paths: renders, owner: app,
                                            rule: "creative.library.render", safety: .rebuilds, method: .removeNow,
                                            rebuild: .automatic))
            }
            if !transcoded.isEmpty {
                candidates.append(candidate(name, detail: library, paths: transcoded, owner: app,
                                            rule: "creative.library.transcoded", safety: .review, method: .trash,
                                            rebuild: .irreversible))
            }
        }
        return candidates
    }

    /// Les bibliothèques du dossier personnel ; sans l'arbre de l'analyse, là où
    /// les deux applications les créent d'office (`~/Movies`), et un dossier plus bas.
    func libraries() async -> [URL] {
        await context.findFolders(fallback: [context.home.appendingPathComponent("Movies", isDirectory: true)], depth: 1) {
            Self.libraryApps[($0 as NSString).pathExtension.lowercased()] != nil
        }
    }

    // MARK: - DaVinci Resolve

    /// Le dossier de travail par défaut de Resolve : son cache de rendu
    /// (`CacheClip`), ses proxys (`ProxyMedia`) et les images fixes de la Galerie
    /// (`.gallery`), que l'on a saisies soi-même.
    func resolve() -> [Candidate] {
        let root = context.path("Movies/DaVinci Resolve")
        guard FileManager.default.isDirectory(root) else { return [] }
        let entries: [(folder: String, rule: String, safety: SafetyClass, method: CleanupMethod, rebuild: RebuildCost)] = [
            ("CacheClip", "creative.resolve.cache", .rebuilds, .removeNow, .automatic),
            ("ProxyMedia", "creative.resolve.proxy", .review, .trash, .irreversible),
            (".gallery", "creative.resolve.gallery", .review, .trash, .irreversible),
        ]
        return entries.compactMap { entry in
            let folder = root.appendingPathComponent(entry.folder, isDirectory: true)
            guard !existing([folder]).isEmpty else { return nil }
            return candidate("DaVinci Resolve", detail: folder, paths: [folder], owner: "DaVinci Resolve",
                             rule: entry.rule, safety: entry.safety, method: entry.method, rebuild: entry.rebuild)
        }
    }

    /// Sur un autre disque, le dossier de travail de Resolve est celui qu'on lui
    /// a choisi (Préférences, Stockage des médias) : on le reconnaît à son
    /// `CacheClip`, nom que Resolve est seul à écrire. Ses `ProxyMedia` et sa
    /// `.gallery` ne sont pris qu'à côté de lui.
    func volumeResolveCaches() async -> [Candidate] {
        let caches = await context.findFolders(fallback: [], depth: 0) { $0 == "CacheClip" }
        return caches.flatMap { cache -> [Candidate] in
            if context.volumeAnchor != nil, existing([cache]).isEmpty { return [] }
            let root = cache.deletingLastPathComponent()
            let entries: [(folder: URL, rule: String, safety: SafetyClass, method: CleanupMethod, rebuild: RebuildCost)] = [
                (cache, "creative.resolve.cache", .rebuilds, .removeNow, .automatic),
                (root.appendingPathComponent("ProxyMedia", isDirectory: true), "creative.resolve.proxy", .review, .trash,
                 .irreversible),
                (root.appendingPathComponent(".gallery", isDirectory: true), "creative.resolve.gallery", .review, .trash,
                 .irreversible),
            ]
            return entries.compactMap { entry in
                guard !existing([entry.folder]).isEmpty else { return nil }
                return candidate("DaVinci Resolve", detail: entry.folder, paths: [entry.folder], owner: "DaVinci Resolve",
                                 rule: entry.rule, safety: entry.safety, method: entry.method, rebuild: entry.rebuild)
            }
        }
    }

    /// Le Media Cache d'Adobe, déplacé sur un autre disque (réglage courant pour
    /// les gros montages) : `Media Cache Files`, et `Media Cache` à côté.
    func volumeAdobeMediaCaches() async -> [Candidate] {
        let caches = await context.findFolders(fallback: [], depth: 0) { $0 == "Media Cache Files" }
        return caches.compactMap { files in
            let folders = existing([files, files.deletingLastPathComponent().appendingPathComponent("Media Cache",
                                                                                               isDirectory: true)])
            if context.volumeAnchor != nil, !folders.contains(files) { return nil }
            return candidate("Adobe", detail: files, paths: folders, owner: "Adobe", rule: "creative.adobe.media_cache",
                             safety: .rebuilds, method: .removeNow, rebuild: .automatic)
        }
    }

    // MARK: - Insta360 Studio

    /// Les caches de Qt et du navigateur intégré, l'aperçu du montage, et les
    /// proxys basse définition que Studio refait en relisant les rushes.
    ///
    /// Pas `cache/cloud_cache` : malgré son nom, il tient la file des exports en
    /// cours dans le nuage (`cloudexportlist.db`).
    func insta360() -> [Candidate] {
        let support = context.path("Library/Application Support/Insta360/Insta360 Studio")
        let caches = existing([
            context.path("Library/Caches/Insta360/Insta360 Studio"),
            support.appendingPathComponent("cache/cef_cache", isDirectory: true),
            support.appendingPathComponent("previewer_cache_nle", isDirectory: true),
        ])
        var candidates: [Candidate] = []
        if let first = caches.first {
            candidates.append(candidate("Insta360 Studio", detail: first, paths: caches, owner: "Insta360 Studio",
                                        rule: "creative.insta360.cache", safety: .safe, method: .removeNow,
                                        rebuild: .automatic))
        }
        let proxies = support.appendingPathComponent("proxy_file", isDirectory: true)
        if !existing([proxies]).isEmpty {
            candidates.append(candidate("Insta360 Studio", detail: proxies, paths: [proxies], owner: "Insta360 Studio",
                                        rule: "creative.insta360.proxy", safety: .rebuilds, method: .removeNow,
                                        rebuild: .automatic))
        }
        return candidates
    }

    // MARK: - Blender

    /// Le cache de Blender (index des bibliothèques d'assets, assets en ligne),
    /// et les dossiers de session `blender_XXXXXX` que chaque Blender ouvre dans
    /// le dossier temporaire et laisse derrière lui s'il se ferme mal.
    ///
    /// Pas `quit.blend` ni les sauvegardes automatiques, à côté : ce sont elles
    /// qui permettent de retrouver une séance perdue.
    func blender() -> [Candidate] {
        var candidates: [Candidate] = []
        let cache = context.path("Library/Caches/Blender")
        if !existing([cache]).isEmpty {
            candidates.append(candidate("Blender", detail: cache, paths: [cache], owner: "Blender",
                                        rule: "creative.blender.cache", safety: .safe, method: .removeNow,
                                        rebuild: .automatic))
        }
        let sessions = existing(FileManager.default.children(of: context.temporaryDirectory)
            .filter { $0.lastPathComponent.hasPrefix("blender_") })
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !sessions.isEmpty {
            candidates.append(candidate("Blender", detail: context.temporaryDirectory, paths: sessions, owner: "Blender",
                                        rule: "creative.blender.temp", safety: .safe, method: .removeNow,
                                        rebuild: .nothing))
        }
        return candidates
    }

    // MARK: - Adobe

    /// Le Media Cache que Premiere Pro, After Effects et Media Encoder partagent :
    /// fichiers d'accélération (`.pek`, `.cfa`) dans `Media Cache Files`, et la
    /// base qui les relie aux médias dans `Media Cache`. Rien d'autre de
    /// `Adobe/Common` (modèles d'animations, préférences d'équipe).
    ///
    /// Source : aide d'Adobe, « Manage media cache » et « Delete media cache files
    /// manually » (janvier 2026) ; « Deleted cache files are recreated whenever
    /// the source media requires them ».
    func adobeMediaCache() -> [Candidate] {
        let common = context.path("Library/Application Support/Adobe/Common")
        let folders = existing([
            common.appendingPathComponent("Media Cache Files", isDirectory: true),
            common.appendingPathComponent("Media Cache", isDirectory: true),
        ])
        guard let first = folders.first else { return [] }
        return [candidate("Adobe", detail: first, paths: folders, owner: "Adobe", rule: "creative.adobe.media_cache",
                          safety: .rebuilds, method: .removeNow, rebuild: .automatic)]
    }

    // MARK: - CapCut et Filmora

    /// Le cache de CapCut, dans `~/Movies/CapCut/User Data/Cache` : effets
    /// téléchargés, lecteur réseau, images. Pas `cloudDraft` ni `Bytesync`, qui
    /// suivent les brouillons synchronisés, et jamais `Projects`, à côté.
    static let capCutKept: Set<String> = ["clouddraft", "bytesync"]

    func capCut() -> [Candidate] {
        let cache = context.path("Movies/CapCut/User Data/Cache")
        let entries = FileManager.default.children(of: cache)
            .filter { !$0.isSymbolicLink && !Self.capCutKept.contains($0.lastPathComponent.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !entries.isEmpty else { return [] }
        return [candidate("CapCut", detail: cache, paths: entries, owner: "CapCut", rule: "creative.capcut.cache",
                          safety: .rebuilds, method: .removeNow, rebuild: .download)]
    }

    /// Les fichiers temporaires de Filmora (analyse des médias, lecture en flux).
    /// Pas ses téléchargements d'effets ni ses réglages.
    func filmora() -> [Candidate] {
        let temp = context.path("Library/Application Support/Wondershare Filmora Mac/ProgramData/Temp")
        guard !existing([temp]).isEmpty else { return [] }
        return [candidate("Filmora", detail: temp, paths: [temp], owner: "Filmora", rule: "creative.filmora.temp",
                          safety: .safe, method: .removeNow, rebuild: .nothing)]
    }

    // MARK: - Plex Media Server

    /// Les paquets des mises à jour que Plex Media Server a déjà installées
    /// (`Updates/<version>-<révision>`), une par version, gardés après coup. Une
    /// version plus récente que celle installée attend d'être appliquée : on la
    /// laisse. Sans l'application, on ne sait pas laquelle est installée : protégé.
    func plexUpdates() -> [Candidate] {
        let updates = context.path("Library/Application Support/Plex Media Server/Updates")
        let folders = existing(FileManager.default.children(of: updates))
        guard !folders.isEmpty else { return [] }
        let plist = context.applications.appendingPathComponent("Plex Media Server.app/Contents/Info.plist")
        let installed = (NSDictionary(contentsOf: plist)?["CFBundleVersion"] as? String)
        let applied = folders.filter { folder in
            let version = String(folder.lastPathComponent.prefix { $0 != "-" })
            guard let installed else { return true }
            return !ToolVersionsFinder.compare(installed, version)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !applied.isEmpty else { return [] }
        var update = candidate("Plex Media Server", detail: updates, paths: applied, owner: "Plex Media Server",
                               rule: "creative.plex.updates", safety: .safe, method: .removeNow, rebuild: .download)
        if installed == nil { update.item.protect(.unknownState) }
        return [update]
    }

    // MARK: - GarageBand et Logic Pro

    /// La bibliothèque de sons que GarageBand et Logic Pro téléchargent pour tout
    /// le Mac : les trois dossiers qu'Apple dit de supprimer pour la retirer.
    ///
    /// Montrée seulement : elle appartient à root, la retirer demande un mot de
    /// passe administrateur qu'Oust! ne demande pas (RULES.md, règle 7).
    func soundLibrary() -> [Candidate] {
        let library = context.systemLibrary
        let folders = existing([
            library.appendingPathComponent("Application Support/GarageBand", isDirectory: true),
            library.appendingPathComponent("Application Support/Logic", isDirectory: true),
            library.appendingPathComponent("Audio/Apple Loops/Apple", isDirectory: true),
        ])
        guard let first = folders.first else { return [] }
        return [candidate("GarageBand · Logic Pro", detail: first, paths: folders, owner: "GarageBand",
                          rule: "creative.sound_library", safety: .review, method: .manual, rebuild: .download)]
    }
}

extension RuleContext {
    /// Des paquets où un catalogue ou une bibliothèque n'ont rien à faire.
    static let otherPackages: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "bundle", "framework",
        "xcodeproj", "xcworkspace", "xcarchive", "logicx", "band", "theater", "dmg", "sparsebundle",
        "backupbundle", "utm", "pvm", "vmwarevm", "vbvm", "macvm",
    ]

    /// Les dossiers du dossier personnel que `matches` reconnaît à leur nom, sans
    /// descendre dedans. L'arbre de l'analyse les trouve où qu'ils soient, hors
    /// `~/Library`, des dossiers cachés et des paquets d'autres applications ;
    /// sans lui, on parcourt le disque sous `fallback`, sur `depth` niveaux de plus.
    ///
    /// Sur un autre disque (`volume`), c'est sa racine qu'on parcourt, et non le
    /// dossier personnel, jamais au-delà de ses sauvegardes Time Machine.
    func findFolders(fallback: [URL], depth: Int, matches: (String) -> Bool) async -> [URL] {
        if let anchor = volumeAnchor {
            return await findBoundFolders(in: anchor, matches: matches)
        }
        let home = (volume?.root ?? self.home).standardizedFileURL
        let fallback = volume.map { [$0.root] } ?? fallback
        let depth = volume == nil ? depth : 6
        let fileManager = FileManager.default
        if let tree = await tree?(), let root = tree.descendant(atPath: home.path) {
            var found: [URL] = []
            var queue: [(node: TreeNode, url: URL, depth: Int)] = [(root, home, 0)]
            var head = 0
            while head < queue.count {
                let (node, url, level) = queue[head]
                head += 1
                for child in node.children {
                    let entry = url.appendingPathComponent(child.name, isDirectory: true)
                    if matches(child.name) { found.append(entry); continue }
                    let ext = (child.name as NSString).pathExtension.lowercased()
                    if child.name.hasPrefix(".") || (level == 0 && child.name == "Library")
                        || Self.otherPackages.contains(ext) || child.name == "node_modules"
                        || child.name == VolumeProtection.timeMachineFolder || child.status != .ok {
                        continue
                    }
                    if level < 6 { queue.append((child, entry, level + 1)) }
                }
            }
            return found.filter { !$0.isSymbolicLink }
        }
        var found: [URL] = []
        var queue = fallback.map { (url: $0, level: 0) }
        var head = 0
        while head < queue.count {
            let (folder, level) = queue[head]
            head += 1
            for entry in fileManager.children(of: folder) where fileManager.isDirectory(entry) && !entry.isSymbolicLink {
                let name = entry.lastPathComponent
                if matches(name) { found.append(entry); continue }
                if name.hasPrefix(".") || Self.otherPackages.contains(entry.pathExtension.lowercased())
                    || name == VolumeProtection.timeMachineFolder || !sameDevice(entry, as: folder) {
                    continue
                }
                if level < depth { queue.append((entry, level + 1)) }
            }
        }
        return found
    }

    /// L'index fournit des noms et des inodes. La racine ouverte reste la
    /// seule autorité pour vérifier un dossier à utiliser.
    private func findBoundFolders(in anchor: AnalysisRoot, matches: (String) -> Bool) async -> [URL] {
        Scanner.configureProcessIOPolicy()
        let root = anchor.url
        let index = await tree?()
        var found: [URL] = []
        var queue: [(url: URL, level: Int, node: TreeNode?)] = [(root, 0, index?.descendant(atPath: root.path))]
        var head = 0
        while head < queue.count, !Task.isCancelled {
            let (directory, level, node) = queue[head]
            head += 1
            let children: [(name: String, node: TreeNode?)]
            if let node {
                guard node.status == .ok else { continue }
                children = node.children.filter { $0.status == .ok }.map { ($0.name, $0) }
            } else {
                children = (volumeEntries(in: directory) ?? []).compactMap {
                    $0.facts.mode & S_IFMT == S_IFDIR ? ($0.url.lastPathComponent, nil) : nil
                }
            }
            for (name, childNode) in children {
                let child = directory.appendingPathComponent(name, isDirectory: true)
                if Self.neverOpened.contains(name) || VolumeProtection.serviceFolders.contains(name)
                    || VolumeProtection.isTimeMachineName(name) || Self.otherPackages.contains(child.pathExtension.lowercased())
                    || (level == 0 && name == "Library") {
                    continue
                }
                if matches(name) {
                    guard let facts = VolumeDirectory.entry(child, in: anchor).facts,
                          facts.mode & S_IFMT == S_IFDIR,
                          childNode.map({ $0.fileID == facts.inode }) ?? true else { continue }
                    found.append(child)
                } else if level < 6, !name.hasPrefix("."), name != "node_modules", !VolumePackages.isPackage(name) {
                    queue.append((child, level + 1, childNode))
                }
            }
        }
        return Task.isCancelled ? [] : found
    }

    /// Le parcours sans arbre ne change jamais de volume (RULES.md, règle 10).
    private func sameDevice(_ entry: URL, as parent: URL) -> Bool {
        var child = stat()
        var base = stat()
        guard lstat(entry.path, &child) == 0, lstat(parent.path, &base) == 0 else { return false }
        return child.st_dev == base.st_dev
    }
}
