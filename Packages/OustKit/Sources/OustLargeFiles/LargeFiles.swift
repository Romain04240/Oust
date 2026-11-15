import Foundation
import OustCore
import OustSafety
import OustScan

/// Un gros fichier de l'arborescence.
public struct LargeFileMatch: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let sizes: Sizes
    public let modified: Date?
    public let accessed: Date?
    /// La famille du fichier, d'après son extension (celle de l'Explorateur).
    public let kind: FileKind
    public let fileID: UInt64
    public let isClone: Bool
    /// Le paquet (application, bibliothèque Photos, projet Final Cut…) dont le
    /// fichier fait partie : le retirer seul abîmerait le paquet.
    public let package: String?

    /// La date qui dit le mieux « plus servi depuis » : le dernier accès quand le
    /// système le tient, sinon la dernière modification.
    public var lastUse: Date? {
        switch (accessed, modified) {
        case (let accessed?, let modified?): max(accessed, modified)
        case (let accessed?, nil): accessed
        case (nil, let modified?): modified
        case (nil, nil): nil
        }
    }
}

/// Les critères de la vue « Gros et vieux fichiers ».
public struct LargeFileFilter: Sendable, Hashable {
    public var minimumSize: Int64
    /// Pas utilisé depuis cette date (ni ouvert ni modifié) ; `nil` : peu importe.
    public var unusedSince: Date?
    /// Les natures retenues ; vide : toutes.
    public var kinds: Set<FileKind>

    public init(minimumSize: Int64 = 100_000_000, unusedSince: Date? = nil, kinds: Set<FileKind> = []) {
        self.minimumSize = minimumSize
        self.unusedSince = unusedSince
        self.kinds = kinds
    }

    public func accepts(_ file: LargeFileMatch) -> Bool {
        guard file.sizes.allocated >= minimumSize else { return false }
        if !kinds.isEmpty, !kinds.contains(file.kind) { return false }
        if let unusedSince {
            // Sans date, on ne peut pas dire « vieux » : on ne le prétend pas.
            guard let last = file.lastUse, last < unusedSince else { return false }
        }
        return true
    }
}

/// Ce que la vue montre : les fichiers retenus et ce que le filtre a laissé de côté.
public struct LargeFileResult: Sendable {
    public let files: [LargeFileMatch]
    /// Tous les fichiers retenus, même au-delà de la limite d'affichage.
    public let matchCount: Int
    public let matchBytes: Int64
}

/// Les gros fichiers d'une arborescence déjà analysée par `OustScan`.
///
/// Aucune lecture du disque : tout vient de l'analyse de l'Explorateur, qui
/// garde déjà un à un les fichiers de plus de 1 Mo. Les petits n'y existent que
/// regroupés, et c'est très bien ainsi : un fichier de 800 Ko n'est jamais
/// « gros ».
public enum LargeFileFinder {

    /// Les extensions de paquets dont le contenu ne se retire pas fichier par fichier.
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "appex", "xpc", "kext", "photoslibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "aplibrary", "lrlibrary", "lrdata",
        "sparsebundle", "xcarchive", "xcodeproj", "xcworkspace", "playground", "pages", "numbers", "key",
        "rtfd", "dvdmedia", "lproj", "mlpackage", "mlmodelc", "docarchive",
        // Symboles de débogage, dépôts git nus et machines virtuelles : un seul
        // fichier retiré, et le reste ne sert plus à rien (revue du 18/10/2026).
        "dsym", "git", "vmwarevm", "pvm", "utm",
    ]

    /// Les dossiers de gestion de versions. La revue du 18/10/2026 a vu proposer
    /// seul un pack git de 4,6 Go (`Meteo/.git/objects/pack`) : le jeter
    /// cassait le dépôt.
    static let repositoryFolders: Set<String> = [".git", ".hg", ".svn"]

    /// Tous les fichiers de l'arborescence qui passent le filtre, du plus gros au
    /// plus petit, limités à `limit` pour l'affichage.
    public static func find(in root: TreeNode, filter: LargeFileFilter, limit: Int = 2_000) -> LargeFileResult {
        var matches: [LargeFileMatch] = []
        var count = 0
        var bytes: Int64 = 0
        // Parcours itératif : l'arborescence d'un disque est profonde.
        var stack: [(TreeNode, String?)] = [(root, nil)]
        while let (node, package) = stack.popLast() {
            let base = PathNormalizer.normalize(node.path)
            for leaf in node.files where leaf.sizes.allocated >= filter.minimumSize {
                let file = LargeFileMatch(
                    url: URL(fileURLWithPath: base).appendingPathComponent(leaf.name), sizes: leaf.sizes,
                    modified: leaf.modified, accessed: leaf.accessed, kind: FileKind.of(leaf.name),
                    fileID: leaf.fileID, isClone: leaf.isClone, package: package
                )
                guard filter.accepts(file) else { continue }
                count += 1
                bytes += file.sizes.freeable
                matches.append(file)
            }
            for child in node.children where child.total.allocated >= filter.minimumSize {
                let ext = (child.name as NSString).pathExtension.lowercased()
                // Un dépôt se nomme par son projet : « Meteo/.git » dit plus que « .git ».
                let own = repositoryFolders.contains(child.name) ? "\(node.name)/\(child.name)"
                    : (SafariDownloadPath.hasPackageExtension(child.name) || packageExtensions.contains(ext) ? child.name : nil)
                stack.append((child, package ?? own))
            }
        }
        matches.sort { $0.sizes.allocated > $1.sizes.allocated }
        return LargeFileResult(files: Array(matches.prefix(limit)), matchCount: count, matchBytes: bytes)
    }
}

extension LargeFileMatch {
    /// Comme élément de la corbeille d'Oust! : du contenu personnel, à examiner,
    /// qui part à la corbeille du Mac. Jamais coché d'office (RULES.md, règle 4).
    public func cleanupItem(volume: String, guard pathGuard: PathGuard) -> CleanupItem {
        var item = CleanupItem(
            id: "largefile|\(url.path)", title: url.lastPathComponent, detail: url.deletingLastPathComponent().path,
            paths: [url], category: .largeFiles, owner: volume, ruleID: "largefile.item", safety: .review,
            notes: isClone ? [.alreadyClone] : (sizes.retained > 0 ? [.partlyShared] : []),
            method: .trash, sizes: sizes, lastActivity: lastUse, rebuild: .irreversible,
            fingerprint: Fingerprint(modificationDate: modified, fileID: fileID)
        )
        if let package { item.protect(.insidePackage(name: package)) }
        if !pathGuard.allows(url) { item.protect(.systemPath) }
        return item
    }
}
