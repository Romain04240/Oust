import Foundation
import OustCore
import OustSafety

/// Les caches que des applications rangent hors de `~/Library/Caches`, là où la
/// règle des caches d'applications ne regarde pas : ceux de Chromium dans les
/// applications Electron (Slack, Discord, Notion, Teams, VS Code, Canva…), et
/// celui de Telegram Desktop.
///
/// Relevé sur un Mac le 18/10/2026 : 3,5 Go dans `~/Library/Application Support`,
/// dont 2,2 Go pour l'application Claude et 760 Mo pour Notion.
struct AppDataCachesFinder {
    let context: RuleContext

    static let minimumAllocated: Int64 = 1_000_000

    func find() async -> [Candidate] {
        let support = context.path("Library/Application Support")
        // Le parcours de l'analyse tourne pendant que les chercheurs démarrent, et
        // les dossiers qu'il lit seraient pris pour des fichiers ouverts : on
        // attend qu'il ait fini. Puis une seule lecture pour tout le dossier.
        _ = await context.tree?()
        let open = OpenFiles.paths(under: support.path)
        let runningNames = Set(context.runningApps.compactMap(context.applicationName).map { $0.lowercased() })
        return (electronCaches(in: support) + telegram()).map { candidate in
            var candidate = candidate
            let paths = candidate.item.paths
            let busy = open.contains { file in paths.contains { PathNormalizer.isWithin(file, $0.path) } }
            if busy || runningNames.contains(candidate.item.owner.lowercased()) {
                candidate.item.protect(.appRunning(name: candidate.item.owner))
            }
            return candidate
        }
    }

    func directories(in folder: URL) -> [URL] {
        let fileManager = FileManager.default
        return fileManager.children(of: folder).filter { fileManager.isDirectory($0) && !$0.isSymbolicLink }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Applications Electron

    /// Ce que Chromium recrée seul : le cache HTTP, le code JavaScript compilé,
    /// les shaders. Jamais `Service Worker`, `IndexedDB` ni `Local Storage` :
    /// des applications y gardent de quoi marcher hors ligne, ou vos réglages.
    static let chromiumCaches = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache",
        "ShaderCache",
    ]

    /// Un profil Chromium a ses réglages à côté de ses caches.
    static let profileMarkers = ["Preferences", "Local State"]

    /// Écartés : les navigateurs (leur section les traite, navigateur fermé
    /// exigé), Cursor et Windsurf (déjà comptés par les agents), Oust! lui-même.
    static let excludedFolders: Set<String> = [
        "google", "arc", "bravesoftware", "microsoft edge", "vivaldi", "chromium", "firefox", "cursor", "windsurf",
        "oust",
    ]

    /// Un élément par application : ses caches à la racine de son profil et dans
    /// chacune de ses partitions (`Partitions/<nom>/Cache`). Un profil se trouve
    /// au premier niveau (`Notion`) ou au second, sous le dossier d'un éditeur
    /// (`Microsoft/Skype for Desktop`).
    ///
    /// Les dossiers nommés comme un identifiant (`com.foo.app`) sont laissés au
    /// désinstalleur, qui les propose quand l'application a disparu : un même
    /// dossier compté à deux endroits le serait deux fois (RULES.md, règle 9).
    func electronCaches(in support: URL) -> [Candidate] {
        var candidates: [Candidate] = []
        for folder in directories(in: support) where !Self.isExcluded(folder.lastPathComponent) {
            let profiles = Self.isProfile(folder) ? [folder]
                : directories(in: folder).filter { !Self.isExcluded($0.lastPathComponent) && Self.isProfile($0) }
            for profile in profiles {
                let caches = cacheFolders(of: profile)
                guard !caches.isEmpty else { continue }
                // « Codex/Default » se nomme d'après son application, pas « Default ».
                let name = profile == folder || !Self.isGenericProfile(profile.lastPathComponent)
                    ? profile.lastPathComponent : folder.lastPathComponent
                candidates.append(Candidate(item: CleanupItem(
                    title: name, detail: profile.abbreviated(home: context.home), paths: caches, category: .appCaches,
                    owner: name, ruleID: "cache.electron", safety: .safe, method: .removeNow, rebuild: .automatic
                ), minimumAllocated: Self.minimumAllocated))
            }
        }
        return candidates
    }

    func cacheFolders(of profile: URL) -> [URL] {
        let roots = [profile] + directories(in: profile.appendingPathComponent("Partitions", isDirectory: true))
        return roots.flatMap { root in
            Self.chromiumCaches.map { root.appendingPathComponent($0, isDirectory: true) }
                .filter { FileManager.default.isDirectory($0) && !$0.isSymbolicLink }
        }
    }

    static func isProfile(_ folder: URL) -> Bool {
        let fileManager = FileManager.default
        guard profileMarkers.contains(where: { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) })
        else { return false }
        return chromiumCaches.contains { fileManager.isDirectory(folder.appendingPathComponent($0)) }
            || fileManager.isDirectory(folder.appendingPathComponent("Partitions"))
    }

    /// Les noms que Chromium donne lui-même à ses profils.
    static func isGenericProfile(_ name: String) -> Bool {
        name == "Default" || name.hasPrefix("Profile ")
    }

    static func isExcluded(_ name: String) -> Bool {
        let lower = name.lowercased()
        return excludedFolders.contains(lower) || AppCachesFinder.isBundleIdentifier(name)
            || AppCachesFinder.passwordManagerMarkers.contains { lower.contains($0) }
    }

    // MARK: - Telegram Desktop

    /// Les fichiers et les médias que Telegram Desktop a téléchargés en faisant
    /// défiler les discussions (`tdata/user_data/cache`, `media_cache`), compte
    /// par compte (`user_data#2`…). Ce que vide « Gérer le stockage local ».
    /// Ni les clés de session ni les réglages, à côté.
    func telegram() -> [Candidate] {
        let tdata = context.path("Library/Application Support/Telegram Desktop/tdata")
        let caches = directories(in: tdata).filter { $0.lastPathComponent.hasPrefix("user_data") }.flatMap { account in
            ["cache", "media_cache"].map { account.appendingPathComponent($0, isDirectory: true) }
        }.filter { FileManager.default.isDirectory($0) && !$0.isSymbolicLink }
        guard !caches.isEmpty else { return [] }
        return [Candidate(item: CleanupItem(
            title: "Telegram Desktop", detail: tdata.abbreviated(home: context.home), paths: caches,
            category: .appCaches, owner: "Telegram", ruleID: "cache.telegram", safety: .safe, method: .removeNow,
            rebuild: .download
        ), minimumAllocated: Self.minimumAllocated)]
    }
}
