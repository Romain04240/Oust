import Darwin
import Foundation
import OustCore
import OustSafety

/// Les lanceurs de jeux : caches de Steam, d'Epic Games Launcher et de GOG
/// Galaxy, et dossiers de jeux restés là après une désinstallation.
///
/// Relevé sur un Mac le 18/10/2026 : `appcache` de Steam, `WebCache` de GOG
/// (dans `/Users/Shared`), `VaultCache` d'Epic, `LauncherInstalled.dat`. Les
/// noms que ce Mac n'avait pas encore (`shadercache`, `depotcache`,
/// `/Users/Shared/Epic Games`) viennent des binaires des lanceurs eux-mêmes.
///
/// Le cache web du lanceur d'Epic, lui, est dans `~/Library/Caches/
/// com.epicgames.EpicGamesLauncher` (aide d'Epic, section Mac) : la règle des
/// caches d'applications le propose déjà, on ne le compte pas deux fois.
///
/// Sur un autre disque (`context.volume`), les bibliothèques qu'on y a rangées :
/// celles de Steam, et les jeux qu'Epic Games Launcher y a installés.
///
/// Un jeu se lance par son lanceur : lanceur ouvert, rien n'est proposé.
struct GamesFinder {
    let context: RuleContext

    static let minimumAllocated: Int64 = 1_000_000

    func find() async -> [Candidate] {
        guard context.volumeAnchor == nil || context.volume != nil else { return [] }
        let found = context.volume != nil
            ? await volumeLibraries()
            : steam() + epic() + gog() + ProAppsFinder.fixedCaches(Self.launchers, context: context)
        return found.map { candidate in
            var candidate = candidate
            if let owner = AppOwnership.runningOwner(ruleID: candidate.item.ruleID, paths: candidate.item.paths,
                                                     running: context.runningApps) {
                candidate.item.protect(.appRunning(name: owner))
            }
            return candidate
        }
    }

    func candidate(_ title: String, detail: URL, paths: [URL], owner: String, rule: String, safety: SafetyClass,
                   method: CleanupMethod, rebuild: RebuildCost, lastActivity: Date? = nil) -> Candidate {
        Candidate(item: CleanupItem(
            title: title, detail: detail.abbreviated(home: context.home), paths: paths, category: .games,
            owner: owner, ruleID: rule, safety: safety, method: method, lastActivity: lastActivity, rebuild: rebuild
        ), minimumAllocated: Self.minimumAllocated)
    }

    func directories(in folder: URL) -> [URL] {
        let directories: [URL]
        if context.volumeAnchor != nil {
            directories = (context.volumeEntries(in: folder) ?? [])
                .filter { $0.facts.mode & S_IFMT == S_IFDIR }.map(\.url)
        } else {
            let fileManager = FileManager.default
            directories = fileManager.children(of: folder).filter { fileManager.isDirectory($0) && !$0.isSymbolicLink }
        }
        return directories.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func isDirectory(_ url: URL) -> Bool {
        if let anchor = context.volumeAnchor {
            return VolumeDirectory.entry(url, in: anchor).facts.map { $0.mode & S_IFMT == S_IFDIR } ?? false
        }
        return FileManager.default.isDirectory(url) && !url.isSymbolicLink
    }

    private func lastModification(of url: URL) -> Date? {
        if let anchor = context.volumeAnchor {
            return VolumeDirectory.entry(url, in: anchor).facts?.modificationDate
        }
        return url.modificationDate
    }

    private func steamManifestText(at url: URL) -> String? {
        if context.volumeAnchor != nil {
            guard let data = context.volumeData(at: url, maximumBytes: 1_048_576) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Autres lanceurs

    /// Des caches à un emplacement fixe, chacun d'après son éditeur ou le dépôt
    /// du projet libre ; ce qui est à côté (comptes, instances, jeux) jamais.
    static let launchers: [ProAppsFinder.Entry] = [
        // us.support.blizzard.com, article 14377 : « Battle.net cache data », à
        // mettre à la corbeille. Pas `Battle.net/Agent` : l'effacer fait oublier
        // où les jeux sont installés.
        ProAppsFinder.Entry(rule: "game.battlenet.cache", owner: "Battle.net", base: .shared,
                            patterns: ["Blizzard/Battle.net", "Blizzard/Blizzard Entertainment"],
                            safety: .rebuilds, method: .removeNow, rebuild: .download, category: .games),
        // prismlauncher.org, « Data location », et `MainWindow.cpp` : téléchargements
        // et métadonnées en cache. Jamais `instances`, `accounts.json`, `java`.
        ProAppsFinder.Entry(rule: "game.prism.cache", owner: "Prism Launcher", base: .home,
                            patterns: ["Library/Application Support/PrismLauncher/cache",
                                       "Library/Application Support/PrismLauncher/meta"],
                            safety: .safe, method: .removeNow, rebuild: .download, category: .games),
        // Heroic, `src/backend/images_cache.ts` et `cache.ts` : ce que vide « Clear
        // Heroic Cache ». Jamais les connexions Epic et GOG, ni `~/Games/Heroic`.
        ProAppsFinder.Entry(rule: "game.heroic.cache", owner: "Heroic", base: .home,
                            patterns: ["Library/Application Support/heroic/images-cache",
                                       "Library/Application Support/heroic/store_cache"],
                            safety: .safe, method: .removeNow, rebuild: .download, category: .games),
        // en.help.roblox.com, article 203312990 : tout effacer dans ce dossier.
        ProAppsFinder.Entry(rule: "game.roblox.logs", owner: "Roblox", base: .home,
                            patterns: ["Library/Logs/Roblox"], safety: .safe, method: .removeNow,
                            rebuild: .nothing, category: .games),
    ]

    // MARK: - Steam

    /// `appcache` (fiches des jeux, images de la bibliothèque), les manifestes de
    /// dépôts (`depotcache`) — tous deux recréés selon la documentation de Steam
    /// (partner.steamgames.com, « Uploading ») —, puis ce que chaque bibliothèque
    /// propose (`steamLibrary`).
    func steam() -> [Candidate] {
        let root = context.path("Library/Application Support/Steam")
        guard isDirectory(root) else { return [] }
        var candidates: [Candidate] = []
        let appcache = root.appendingPathComponent("appcache", isDirectory: true)
        if isDirectory(appcache) {
            candidates.append(candidate("Steam", detail: appcache, paths: [appcache], owner: "Steam",
                                        rule: "game.steam.appcache", safety: .safe, method: .removeNow,
                                        rebuild: .automatic))
        }
        var depots = [root.appendingPathComponent("depotcache", isDirectory: true)]
        for library in steamLibraries(root: root) {
            let steamapps = library.appendingPathComponent("steamapps", isDirectory: true)
            depots.append(steamapps.appendingPathComponent("depotcache", isDirectory: true))
            candidates += steamLibrary(steamapps)
        }
        let existingDepots = depots.filter(isDirectory)
        if let first = existingDepots.first {
            candidates.append(steamDepots(first, paths: existingDepots))
        }
        return candidates
    }

    /// Ce que propose une bibliothèque Steam, où qu'elle soit : ses shaders
    /// compilés, ses téléchargements inachevés, et les dossiers de
    /// `steamapps/common` qu'aucun manifeste ne réclame plus. Ses manifestes de
    /// dépôts à part : au disque de démarrage, ceux de toutes les bibliothèques
    /// font un seul élément.
    func steamLibrary(_ steamapps: URL) -> [Candidate] {
        var candidates: [Candidate] = []
        let shaders = steamapps.appendingPathComponent("shadercache", isDirectory: true)
        if isDirectory(shaders) {
            candidates.append(candidate("Steam", detail: shaders, paths: [shaders], owner: "Steam",
                                        rule: "game.steam.shadercache", safety: .rebuilds, method: .removeNow,
                                        rebuild: .automatic))
        }
        return candidates + steamDownloads(in: steamapps) + steamLeftovers(in: steamapps)
    }

    func steamDepots(_ detail: URL, paths: [URL]) -> Candidate {
        candidate("Steam", detail: detail, paths: paths, owner: "Steam", rule: "game.steam.depotcache", safety: .safe,
                  method: .removeNow, rebuild: .download)
    }

    /// Les téléchargements que Steam n'a pas menés au bout, un élément par jeu :
    /// `downloading/<id>` (les fichiers reçus, pas encore posés dans `common`),
    /// son état (`downloading/state_<id>_<dépôt>.patch`) et `temp/<id>`. Noms lus
    /// dans `steamclient.dylib` (`%s/temp/%u`, `../state_%u_%u.patch`) ; Steam
    /// vide ces dossiers une fois le jeu posé.
    ///
    /// « À examiner » : un téléchargement en pause reprend où il en était ;
    /// supprimé, il repart de zéro, parfois des dizaines de gigaoctets
    /// (RULES.md, règle 4).
    func steamDownloads(in steamapps: URL) -> [Candidate] {
        let downloading = steamapps.appendingPathComponent("downloading", isDirectory: true)
        let temp = steamapps.appendingPathComponent("temp", isDirectory: true)
        var byApp: [String: [URL]] = [:]
        for folder in directories(in: downloading) + directories(in: temp) where Self.isAppID(folder.lastPathComponent) {
            byApp[folder.lastPathComponent, default: []].append(folder)
        }
        let downloadFiles = context.volumeAnchor == nil
            ? FileManager.default.children(of: downloading)
            : (context.volumeEntries(in: downloading) ?? []).filter { $0.facts.isRegularFile }.map(\.url)
        for file in downloadFiles where file.pathExtension == "patch" {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard parts.count >= 3, parts[0] == "state", Self.isAppID(String(parts[1])) else { continue }
            byApp[String(parts[1]), default: []].append(file)
        }
        return byApp.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { app, paths in
            let manifest = steamapps.appendingPathComponent("appmanifest_\(app).acf", isDirectory: false)
            let name = steamManifestText(at: manifest).flatMap { Self.vdfValues("name", in: $0).first }
            return candidate(name.flatMap { $0.isEmpty ? nil : $0 } ?? "Steam", detail: paths[0], paths: paths,
                             owner: "Steam", rule: "game.steam.download", safety: .review, method: .removeNow,
                             rebuild: .download)
        }
    }

    static func isAppID(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy(\.isASCII) && name.allSatisfy(\.isNumber)
    }

    /// Les bibliothèques déclarées dans `libraryfolders.vdf`, celle de Steam
    /// comprise, sur le volume du dossier personnel seulement : on ne promet pas
    /// d'espace sur un disque externe (RULES.md, règle 10). Celles d'un autre
    /// disque, l'analyse de ce disque les trouve (`volumeLibraries`).
    func steamLibraries(root: URL) -> [URL] {
        let file = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        let declared = (try? String(contentsOf: file, encoding: .utf8)).map { Self.vdfValues("path", in: $0) } ?? []
        var seen = Set<String>()
        return ([root] + declared.map { URL(fileURLWithPath: $0, isDirectory: true) }).filter { library in
            let key = PathNormalizer.normalize(library.standardizedFileURL.path).lowercased()
            return seen.insert(key).inserted && isDirectory(library) && Self.sameVolume(library, context.home)
        }
    }

    /// Un dossier de jeu que plus aucun `appmanifest_<id>.acf` ne déclare : Steam
    /// l'a laissé à la désinstallation (mods, sauvegardes locales, fichiers ajoutés).
    /// Un manifeste illisible, et l'on ne sait plus ce qui est installé : protégé.
    func steamLeftovers(in steamapps: URL) -> [Candidate] {
        let folders = directories(in: steamapps.appendingPathComponent("common", isDirectory: true))
        guard !folders.isEmpty else { return [] }
        let (installed, unreadable) = installedSteamFolders(in: steamapps)
        return folders.filter { !installed.contains($0.lastPathComponent.lowercased()) }.map { folder in
            var leftover = candidate(folder.lastPathComponent, detail: folder, paths: [folder], owner: "Steam",
                                     rule: "game.steam.leftover", safety: .review, method: .trash,
                                     rebuild: .download, lastActivity: lastModification(of: folder))
            if unreadable { leftover.item.protect(.unknownState) }
            if context.volumeAnchor != nil, !unreadable {
                leftover.boundProof = {
                    let (current, uncertain) = installedSteamFolders(in: steamapps)
                    return !uncertain && current == installed
                }
            }
            return leftover
        }
    }

    private func installedSteamFolders(in steamapps: URL) -> (Set<String>, unreadable: Bool) {
        let anchor = context.volumeAnchor
        let directory = anchor.flatMap { VolumeDirectory.entry(steamapps, in: $0).facts }
        let manifests: [URL]
        if let anchor {
            // Keep unreadable names in the list. An unverified manifest can still declare a game.
            guard let names = VolumeDirectory.names(in: steamapps, anchor: anchor), directory != nil else {
                return ([], true)
            }
            manifests = names.map { steamapps.appendingPathComponent($0, isDirectory: false) }.filter(Self.isSteamManifest)
        } else {
            manifests = FileManager.default.children(of: steamapps).filter(Self.isSteamManifest)
        }
        var installed = Set<String>()
        var unreadable = false
        var verified: [(URL, FileFacts)] = []
        for manifest in manifests {
            if let anchor {
                guard let before = VolumeDirectory.entry(manifest, in: anchor).facts, before.isRegularFile else {
                    unreadable = true
                    continue
                }
                verified.append((manifest, before))
            }
            guard let text = steamManifestText(at: manifest),
                  let folder = Self.vdfValues("installdir", in: text).first, !folder.isEmpty else {
                unreadable = true
                continue
            }
            installed.insert(folder.lowercased())
        }
        if let anchor, let directory {
            guard VolumeDirectory.entry(steamapps, in: anchor).facts?.isUnchanged(comparedTo: directory) == true,
                  verified.allSatisfy({ manifest, before in
                      VolumeDirectory.entry(manifest, in: anchor).facts?.isUnchanged(comparedTo: before) == true
                  }) else { return (installed, true) }
        }
        return (installed, unreadable)
    }

    private static func isSteamManifest(_ file: URL) -> Bool {
        file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf"
    }

    /// Les valeurs d'une clé d'un fichier VDF de Steam (`"path"  "/Users/…"`),
    /// échappements compris, dans l'ordre du fichier.
    static func vdfValues(_ key: String, in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let tokens = quotedTokens(line)
            guard tokens.count >= 2, tokens[0].caseInsensitiveCompare(key) == .orderedSame else { return nil }
            return tokens[1]
        }
    }

    /// Les chaînes entre guillemets d'une ligne ; `\"` et `\\` sont des caractères.
    static func quotedTokens(_ line: Substring) -> [String] {
        var tokens: [String] = []
        var current: String?
        var escaped = false
        for character in line {
            guard current != nil else {
                if character == "\"" { current = "" }
                continue
            }
            if escaped {
                current?.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                tokens.append(current ?? "")
                current = nil
            } else {
                current?.append(character)
            }
        }
        return tokens
    }

    static func sameVolume(_ first: URL, _ second: URL) -> Bool {
        let a = try? first.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let b = try? second.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }
        return a.isEqual(b)
    }

    // MARK: - Epic Games Launcher

    /// Les assets Unreal du `VaultCache`, un élément par pack, et les jeux de
    /// `/Users/Shared/Epic Games` que le lanceur ne connaît plus.
    func epic() -> [Candidate] {
        var candidates: [Candidate] = []
        let vault = context.sharedFolder.appendingPathComponent("UnrealEngine/Launcher/VaultCache", isDirectory: true)
        for pack in directories(in: vault) {
            candidates.append(candidate(pack.lastPathComponent, detail: pack, paths: [pack],
                                        owner: "Epic Games Launcher", rule: "game.epic.vault", safety: .review,
                                        method: .removeNow, rebuild: .download, lastActivity: pack.modificationDate))
        }
        return candidates + epicLeftovers()
    }

    /// Les dossiers de `/Users/Shared/Epic Games`, que seul le lanceur de ce Mac
    /// remplit (`epicFolders`).
    func epicLeftovers() -> [Candidate] {
        let folders = directories(in: context.sharedFolder.appendingPathComponent(Self.epicLibraryName, isDirectory: true))
        guard !folders.isEmpty else { return [] }
        return epicFolders(folders, installed: Self.epicInstallLocations(epicInstallList), libraryIsOurs: true)
    }

    var epicInstallList: URL {
        context.path("Library/Application Support/Epic/UnrealEngineLauncher/LauncherInstalled.dat")
    }

    /// Les dossiers d'une bibliothèque d'Epic. Un jeu que `LauncherInstalled.dat`
    /// désigne : son téléchargement inachevé, s'il y en a un. Un dossier qu'il ne
    /// désigne plus : ce qu'une désinstallation a laissé.
    ///
    /// Liste absente ou illisible : on ne sait pas ce qui est installé, tout est
    /// protégé (RULES.md, règle 3). Sur un autre disque, qui sert peut-être à
    /// un autre ordinateur, aussi : un dossier qui garde les fichiers du lanceur
    /// (`.egstore`, peut-être le jeu installé d'un autre lanceur), et ceux d'une
    /// bibliothèque dont ce Mac n'a installé aucun jeu (`libraryIsOurs`).
    func epicFolders(_ folders: [URL], installed: [String]?, libraryIsOurs: Bool) -> [Candidate] {
        folders.flatMap { folder -> [Candidate] in
            if let installed, isListed(folder, in: installed) { return epicDownload(in: folder) }
            var leftover = candidate(folder.lastPathComponent, detail: folder, paths: [folder],
                                     owner: "Epic Games Launcher", rule: "game.epic.leftover", safety: .review,
                                     method: .trash, rebuild: .download, lastActivity: lastModification(of: folder))
            let elsewhere = context.volume != nil
                && (!libraryIsOurs || isDirectory(folder.appendingPathComponent(Self.epicStore, isDirectory: true)))
            if installed == nil || elsewhere { leftover.item.protect(.unknownState) }
            return [leftover]
        }
    }

    /// `.egstore/bps` : BuildPatchServices y prépare les fichiers d'un
    /// téléchargement, et le lanceur l'efface une fois le jeu posé (« Deleting
    /// staging area. », dans son binaire). Encore là, le téléchargement n'a pas
    /// abouti. « À examiner », comme celui de Steam : supprimé, il repart de zéro.
    func epicDownload(in install: URL) -> [Candidate] {
        let staging = install.appendingPathComponent(Self.epicStaging, isDirectory: true)
        guard isDirectory(staging) else { return [] }
        return [candidate(install.lastPathComponent, detail: staging, paths: [staging], owner: "Epic Games Launcher",
                          rule: "game.epic.download", safety: .review, method: .removeNow, rebuild: .download)]
    }

    static let epicLibraryName = "Epic Games"
    /// Le lanceur range les manifestes d'un jeu installé dans ce dossier, à sa racine.
    static let epicStore = ".egstore"
    static let epicStaging = ".egstore/bps"

    /// Le lanceur désigne-t-il ce dossier ? Sur un autre disque, le même chemin
    /// depuis sa racine suffit : monté sous un autre nom (« Jeux 1 »), c'est le
    /// même jeu.
    func isListed(_ folder: URL, in installed: [String]) -> Bool {
        let path = Self.comparable(folder.path)
        if installed.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { return true }
        guard let volume = context.volume else { return false }
        let root = Self.comparable(volume.root.path)
        guard path.hasPrefix(root + "/") else { return false }
        let relative = String(path.dropFirst(root.count + 1))
        return installed.contains { location in
            guard location.hasPrefix("/volumes/") else { return false }
            let rest = location.split(separator: "/").dropFirst(2).joined(separator: "/")
            return rest == relative || rest.hasPrefix(relative + "/")
        }
    }

    /// Les `InstallLocation` de la liste des installations, `nil` si elle
    /// manque ou ne se lit pas.
    static func epicInstallLocations(_ url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["InstallationList"] as? [[String: Any]] else { return nil }
        var locations: [String] = []
        for entry in list {
            guard let location = entry["InstallLocation"] as? String else { return nil }
            locations.append(comparable(location))
        }
        return locations
    }

    /// APFS ignore la casse par défaut : on compare comme lui.
    static func comparable(_ path: String) -> String {
        PathNormalizer.normalize(URL(fileURLWithPath: path).standardizedFileURL.path).lowercased()
    }

    // MARK: - Sur un autre disque

    /// Les bibliothèques de jeux d'un autre disque, où qu'on les y ait rangées :
    /// un dossier `steamapps` de Steam (sous `SteamLibrary` quand on l'ajoute
    /// depuis Steam), un dossier `Epic Games`, un jeu d'Epic reconnu à son
    /// `.egstore`. Les caches des lanceurs restent dans le dossier personnel :
    /// l'analyse du disque de démarrage s'en charge.
    func volumeLibraries() async -> [Candidate] {
        guard let volume = context.volume else { return [] }
        let found = await context.findFolders(fallback: [], depth: 0) { name in
            name.caseInsensitiveCompare(Self.steamapps) == .orderedSame
                || name.caseInsensitiveCompare(Self.epicLibraryName) == .orderedSame || name == Self.epicStore
        }
        var candidates: [Candidate] = []
        for steamapps in found where steamapps.lastPathComponent.caseInsensitiveCompare(Self.steamapps) == .orderedSame
            && isSteamLibrary(steamapps) {
            candidates += steamLibrary(steamapps)
            let depots = steamapps.appendingPathComponent("depotcache", isDirectory: true)
            if isDirectory(depots) { candidates.append(steamDepots(depots, paths: [depots])) }
        }

        // The host's registry is outside the opened volume. Epic rows from that volume stay protected.
        let installed = context.volumeAnchor == nil ? Self.epicInstallLocations(epicInstallList) : nil
        func key(_ url: URL) -> String {
            context.volumeAnchor == nil ? Self.comparable(url.path) : url.path
        }
        var seen = Set<String>()
        for library in found where library.lastPathComponent.caseInsensitiveCompare(Self.epicLibraryName) == .orderedSame {
            let folders = directories(in: library).filter { seen.insert(key($0)).inserted }
            let ours = installed.map { list in folders.contains { isListed($0, in: list) } } ?? false
            candidates += epicFolders(folders, installed: installed, libraryIsOurs: ours)
        }
        // Un jeu d'Epic hors d'un dossier `Epic Games` : jamais la racine du
        // disque elle-même, si l'on y a installé un jeu.
        let root = key(volume.root)
        let loose = found.filter { $0.lastPathComponent == Self.epicStore }.map { $0.deletingLastPathComponent() }
            .filter { key($0) != root && seen.insert(key($0)).inserted }
        candidates += epicFolders(loose, installed: installed, libraryIsOurs: false)
        return candidates
    }

    static let steamapps = "steamapps"

    /// Un dossier `steamapps` est une bibliothèque Steam sous `SteamLibrary`, à
    /// côté de son `libraryfolder.vdf` (que Steam écrit dans chaque bibliothèque
    /// d'un autre disque), ou s'il garde des manifestes de jeux.
    func isSteamLibrary(_ steamapps: URL) -> Bool {
        let library = steamapps.deletingLastPathComponent()
        if library.lastPathComponent.caseInsensitiveCompare("SteamLibrary") == .orderedSame { return true }
        if let anchor = context.volumeAnchor {
            let markers = [library, steamapps].map { $0.appendingPathComponent("libraryfolder.vdf", isDirectory: false) }
            return markers.contains { VolumeDirectory.entry($0, in: anchor).facts?.isRegularFile == true }
                || (context.volumeEntries(in: steamapps) ?? []).contains {
                    $0.facts.isRegularFile && Self.isSteamManifest($0.url)
                }
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: library.appendingPathComponent("libraryfolder.vdf").path)
            || fileManager.fileExists(atPath: steamapps.appendingPathComponent("libraryfolder.vdf").path) {
            return true
        }
        return fileManager.children(of: steamapps).contains(where: Self.isSteamManifest)
    }

    // MARK: - GOG Galaxy

    /// Le cache web de Galaxy, que le client range pour tous dans `/Users/Shared`.
    func gog() -> [Candidate] {
        let web = context.sharedFolder.appendingPathComponent("GOG.com/Galaxy/WebCache", isDirectory: true)
        guard isDirectory(web) else { return [] }
        return [candidate("GOG Galaxy", detail: web, paths: [web], owner: "GOG Galaxy", rule: "game.gog.webcache",
                          safety: .safe, method: .removeNow, rebuild: .automatic)]
    }
}
