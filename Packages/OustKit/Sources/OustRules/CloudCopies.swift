import Darwin
import Foundation
import OustCore
import OustSafety
import OustScan

/// Ce qui occupe le disque alors qu'il est déjà dans le nuage : les copies
/// locales d'iCloud Drive et des File Providers (Google Drive, Dropbox,
/// OneDrive, Box…).
///
/// Libérer sans supprimer : l'éviction retire la copie locale, le fichier reste
/// dans le nuage et revient à l'ouverture. « À examiner » quand même : hors
/// connexion, ce qui a été évincé n'est plus là, et c'est à l'utilisateur de
/// dire ce qu'il veut garder sous la main.
struct CloudCopiesFinder {
    let context: RuleContext

    struct Provider: Sendable {
        let root: URL
        let name: String
        let rule: String
    }

    /// Les dossiers de premier niveau que Google Drive intercale avant ceux de
    /// l'utilisateur : on regroupe un cran plus bas.
    static let containerFolders: Set<String> = [
        "My Drive", "Mon Drive", "Mi unidad", "Meine Ablage", "Il mio Drive", "Shared drives", "Drive partagés",
        "Other computers", "Autres ordinateurs",
    ]

    /// Parcourt les fichiers évinçables d'un dossier ; remplacé en test, faute de
    /// pouvoir fabriquer un fichier iCloud dans un dossier temporaire.
    typealias Walk = (URL, (URL, Int64, Date?) -> Bool) -> Void

    /// Seuls les fichiers d'au moins 1 Mo sont comptés à l'analyse.
    ///
    /// Lire l'état de synchronisation d'un fichier passe par le démon du nuage,
    /// environ 3 ms chacun : sur les 167 000 fichiers d'iCloud et de Google Drive
    /// de ce Mac, le 18/10/2026, l'analyse y passait 195 s. Les gros fichiers font
    /// l'essentiel de la place ; les petits ne sont pas comptés (le chiffre
    /// annoncé reste en dessous du vrai, jamais au-dessus), mais l'éviction les
    /// traite aussi, et l'historique note ce qui a vraiment été rendu.
    static let countedFileBytes: Int64 = 1_000_000

    func find() async -> [Candidate] {
        // Ne rien télécharger en lisant : un dossier resté dans le nuage reste fermé.
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let tree = await context.tree?()
        return providers().flatMap { provider in
            // L'arbre de l'analyse connaît déjà les gros fichiers : pas besoin de relire le disque.
            let node = tree?.descendant(atPath: provider.root.path)
            return candidates(for: provider, walk: node.map { Self.largeFiles(in: $0) } ?? { Self.largeFiles(under: $0, visit: $1) })
        }
    }

    /// Les gros fichiers évinçables d'après l'arbre de l'analyse.
    static func largeFiles(in node: TreeNode, eligible: @escaping (URLResourceValues) -> Bool = CloudFile.isEvictable) -> Walk {
        { _, visit in
            var stack = [node]
            while let current = stack.popLast() {
                let directory = current.url
                guard !SafariDownloadPath.containsPackage(current.path),
                      let local = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]),
                      local.isDirectory == true, local.isSymbolicLink != true else { continue }
                if CloudPackage.isIndivisible(named: directory.lastPathComponent, reportedBySystem: local.isPackage == true) {
                    var proceed = true
                    CloudFile.walk(directory, minimumBytes: countedFileBytes, eligible: eligible) { url, bytes, modified in
                        proceed = visit(url, bytes, modified)
                        return proceed
                    }
                    if !proceed { return }
                    continue
                }
                stack += current.children
                for leaf in current.files where leaf.sizes.allocated >= countedFileBytes {
                    let url = current.url.appendingPathComponent(leaf.name)
                    guard let values = try? url.resourceValues(forKeys: CloudFile.keys), eligible(values) else { continue }
                    if !visit(url, leaf.sizes.allocated, leaf.modified) { return }
                }
            }
        }
    }

    /// Les gros fichiers évinçables, en lisant le disque : les attributs locaux
    /// d'abord (rapides), l'état de synchronisation pour les seuls gros fichiers.
    static func largeFiles(under root: URL, eligible: (URLResourceValues) -> Bool = CloudFile.isEvictable,
                           visit: (URL, Int64, Date?) -> Bool) {
        CloudFile.walk(root, minimumBytes: countedFileBytes, eligible: eligible, visit: visit)
    }

    /// Un domaine vivant : la racine elle-même est dans le nuage. Les anciens
    /// dossiers qu'un fournisseur laisse derrière lui en se déconnectant
    /// (« GoogleDrive-x (10-07-2026 16:41) ») ne le sont plus : rien à évincer.
    static func isLive(_ root: URL) -> Bool {
        (try? root.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    func providers(live: (URL) -> Bool = Self.isLive) -> [Provider] {
        let fileManager = FileManager.default
        var providers: [Provider] = []
        let mobile = context.path("Library/Mobile Documents")
        for container in fileManager.children(of: mobile) where fileManager.isDirectory(container) && live(container) {
            let name = container.lastPathComponent
            // Le coffre d'un gestionnaire de mots de passe reste où il est, même dans le nuage.
            if AppCachesFinder.passwordManagerMarkers.contains(where: name.lowercased().contains) { continue }
            if name == "com~apple~CloudDocs" {
                providers.append(Provider(root: container, name: "iCloud Drive", rule: "cloud.icloud"))
            } else if name.hasPrefix("iCloud~") {
                // Le dossier iCloud d'une application (« iCloud~md~obsidian »).
                let app = name.split(separator: "~").last.map(String.init) ?? name
                providers.append(Provider(root: container, name: "iCloud · \(app.capitalized)", rule: "cloud.icloud"))
            }
        }
        for folder in fileManager.children(of: context.path("Library/CloudStorage"))
        where fileManager.isDirectory(folder) && !folder.lastPathComponent.hasPrefix(".") && live(folder) {
            providers.append(Provider(root: folder, name: Self.providerName(folder.lastPathComponent), rule: "cloud.file_provider"))
        }
        return providers
    }

    /// « GoogleDrive-romain@exemple.fr » → « Google Drive », « OneDrive-Personal » → « OneDrive ».
    static func providerName(_ folder: String) -> String {
        let base = folder.split(separator: "-").first.map(String.init) ?? folder
        switch base {
        case "GoogleDrive": return "Google Drive"
        case "OneDrive": return "OneDrive"
        case "Box": return "Box"
        case "Dropbox": return "Dropbox"
        case "pCloudDrive", "pCloud": return "pCloud"
        default: return base
        }
    }

    /// Un élément par dossier de premier niveau (ou de second, sous « Mon Drive »).
    func candidates(for provider: Provider, walk: Walk = CloudFile.walk) -> [Candidate] {
        struct Group {
            var bytes: Int64 = 0
            var latest: Date?
            var loose: [URL] = []
        }
        var groups: [String: Group] = [:]
        // Un même dossier a deux noms : l'arbre de l'analyse rend
        // `/System/Volumes/Data/Users/…`, le dossier personnel `/Users/…`. Comparés
        // tels quels, le premier découpage tombait vingt caractères à côté (revue du
        // 18/10/2026 : tout iCloud Drive en un seul élément, sur un chemin inexistant).
        let base = PathNormalizer.normalize(provider.root.standardizedFileURL.path)
        walk(provider.root) { found, bytes, modified in
            guard !CloudFile.isSafariDownload(found) else { return true }
            let path = PathNormalizer.normalize(found.standardizedFileURL.path)
            guard path.hasPrefix(base + "/") else { return true }
            let relative = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
            guard !relative.isEmpty else { return true }
            // Toujours sous la racine du fournisseur, quel que soit le nom reçu.
            let url = relative.reduce(provider.root) { $0.appendingPathComponent($1) }
            let key: String
            // Un fichier posé à la racine, ou directement dans « Mon Drive » : l'élément
            // liste ces fichiers-là, un par un. Désigner le dossier entier ferait évincer
            // aussi les sous-dossiers, montrés à part et peut-être pas cochés.
            let loose: Bool
            if relative.count == 1 {
                (key, loose) = ("", true)
            } else if Self.containerFolders.contains(relative[0]) {
                (key, loose) = relative.count > 2 ? (relative[0] + "/" + relative[1], false) : (relative[0], true)
            } else {
                (key, loose) = (relative[0], false)
            }
            var group = groups[key] ?? Group()
            group.bytes += bytes
            if let modified, modified > (group.latest ?? .distantPast) { group.latest = modified }
            if loose { group.loose.append(url) }
            groups[key] = group
            return true
        }
        return groups.map { key, group in
            let isLoose = key.isEmpty || Self.containerFolders.contains(key)
            let paths = isLoose ? group.loose : [provider.root.appendingPathComponent(key, isDirectory: true)]
            return Candidate(item: CleanupItem(
                id: "cloud|\(provider.root.path)|\(key)",
                title: key.isEmpty ? provider.name : (key as NSString).lastPathComponent,
                detail: paths.count == 1 ? paths[0].abbreviated(home: context.home) : provider.root.abbreviated(home: context.home),
                paths: paths, category: .cloudFiles, owner: provider.name, ruleID: provider.rule, safety: .review,
                method: .evictLocalCopy, sizes: Sizes(private: group.bytes), lastActivity: group.latest,
                rebuild: .download
            ), needsMeasure: false, minimumAllocated: 1_000_000)
        }
    }
}
