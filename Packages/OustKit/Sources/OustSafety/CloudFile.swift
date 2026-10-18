import Foundation

/// Ce qui peut quitter le disque tout en restant dans le nuage (iCloud Drive,
/// Google Drive, Dropbox, OneDrive… : tout File Provider répond aux mêmes clés).
///
/// La règle est stricte, parce que l'éviction d'un fichier qui n'est pas encore
/// dans le nuage serait une perte : téléchargé **et** envoyé, sans envoi en
/// cours, sans conflit, et synchronisé (un `.DS_Store` de Google Drive est
/// « ubiquitaire » mais jamais envoyé).
public enum CloudFile {
    public static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemHasUnresolvedConflictsKey,
        .ubiquitousItemIsExcludedFromSyncKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey,
        .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
    ]

    /// L'état de synchronisation d'un fichier, tel que macOS le décrit.
    public struct Status: Sendable, Hashable {
        public var isUbiquitous = false
        public var isLocal = false
        public var isUploaded = false
        public var isUploading = false
        public var isDownloading = false
        public var hasConflicts = false
        public var isExcludedFromSync = false
        public var isSymbolicLink = false

        public init() {}

        public init(_ values: URLResourceValues) {
            isUbiquitous = values.isUbiquitousItem == true
            switch values.ubiquitousItemDownloadingStatus {
            case .current?, .downloaded?: isLocal = true
            default: isLocal = false
            }
            isUploaded = values.ubiquitousItemIsUploaded == true
            isUploading = values.ubiquitousItemIsUploading == true
            isDownloading = values.ubiquitousItemIsDownloading == true
            hasConflicts = values.ubiquitousItemHasUnresolvedConflicts == true
            isExcludedFromSync = values.ubiquitousItemIsExcludedFromSync == true
            isSymbolicLink = values.isSymbolicLink == true
        }

        /// Vrai si le fichier (ou le paquet) peut être évincé sans rien perdre.
        public var isEvictable: Bool {
            isUbiquitous && isLocal && isUploaded && !isUploading && !isDownloading && !hasConflicts
                && !isExcludedFromSync && !isSymbolicLink
        }
    }

    public static func isEvictable(_ values: URLResourceValues) -> Bool { Status(values).isEvictable }

    /// Ce que l'éviction rendrait : la place des fichiers évinçables sous `url`,
    /// un paquet (`.pages`, `.photoslibrary`) comptant pour un.
    ///
    /// `visit` reçoit chaque fichier ou paquet évinçable et sa taille allouée.
    /// Lire ces attributs ne télécharge rien : on ne descend jamais dans un
    /// dossier resté dans le nuage.
    public static func walk(_ url: URL, visit: (URL, Int64, Date?) -> Bool) {
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: keys) else { return }
        if values.isDirectory != true {
            if isEvictable(values) { _ = visit(fresh, Int64(values.totalFileAllocatedSize ?? 0), values.contentModificationDate) }
            return
        }
        if values.isPackage == true {
            if let bytes = evictablePackage(fresh, values) { _ = visit(fresh, bytes, values.contentModificationDate) }
            return
        }
        let enumerator = FileManager.default.enumerator(at: fresh, includingPropertiesForKeys: Array(keys), options: [])
        while let entry = enumerator?.nextObject() as? URL {
            guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true {
                if values.isPackage == true {
                    enumerator?.skipDescendants()
                    if let bytes = evictablePackage(entry, values), !visit(entry, bytes, values.contentModificationDate) { return }
                } else if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    enumerator?.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, isEvictable(values) else { continue }
            if !visit(entry, Int64(values.totalFileAllocatedSize ?? 0), values.contentModificationDate) { return }
        }
    }

    /// La taille d'un paquet (`.pages`, `.logicx`, `.rtfd`), s'il peut partir en
    /// entier ; `nil` sinon.
    ///
    /// Pour un File Provider, un paquet n'est qu'un dossier : il se dit envoyé
    /// alors qu'un fichier dedans attend encore son envoi. On exige donc que
    /// chaque fichier du paquet soit évinçable lui aussi.
    static func evictablePackage(_ url: URL, _ values: URLResourceValues) -> Int64? {
        guard isEvictable(values) else { return nil }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [])
        while let entry = enumerator?.nextObject() as? URL {
            guard let child = try? entry.resourceValues(forKeys: keys) else { return nil }
            guard child.isRegularFile == true else { continue }
            guard isEvictable(child) else { return nil }
            total += Int64(child.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
