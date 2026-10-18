import Foundation

/// Ce que la compression sur place laisse tel quel, partagé par l'estimation
/// (`OustRules`) et la compression elle-même (`OustClean`) : un fichier que
/// l'estimation compte et que la compression saute, c'est un chiffre faux.
public enum CompressionPolicy {

    /// L'historique git (déjà compressé, et le dépôt n'est pas à nous), et les
    /// artefacts qu'Oust! propose de supprimer plutôt que de compresser.
    public static let skippedFolders: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "DerivedData", "Pods", ".gradle", ".venv", "venv",
        "__pycache__", ".next", ".nuxt", ".output", ".svelte-kit", ".dart_tool", ".turbo", ".parcel-cache",
        ".angular", ".expo", ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".swiftpm", ".cxx",
    ]

    /// Des paquets dont les fichiers sont écrits par un programme qui les garde
    /// ouverts (images disque, machines virtuelles) : les réécrire sous lui
    /// perdrait ce qu'il écrit ensuite.
    public static let skippedPackageExtensions: Set<String> = [
        "sparsebundle", "sparseimage", "vmwarevm", "pvm", "utm", "photoslibrary", "musiclibrary",
    ]

    /// Des formats déjà compressés : les recompresser coûte du temps pour rien.
    public static let incompressibleExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "mp4", "mov", "m4v", "mkv", "avi", "mp3",
        "m4a", "aac", "flac", "ogg", "opus", "zip", "gz", "tgz", "bz2", "xz", "zst", "lz4", "7z", "rar", "dmg",
        "xip", "pkg", "jar", "apk", "aab", "ipa", "woff", "woff2", "br", "car", "pdf", "docx", "xlsx", "pptx",
        "pages", "numbers", "key", "sketch", "psd", "afdesign", "afphoto", "mlmodelc", "npz", "parquet",
    ]

    /// Des fichiers vivants : bases de données et leurs journaux, verrous, disques
    /// virtuels. Endormis ou non, on ne les remplace pas.
    public static let liveDataExtensions: Set<String> = [
        "sqlite", "sqlite3", "db", "db-wal", "db-shm", "sqlite-wal", "sqlite-shm", "wal", "shm", "realm",
        "lock", "ldb", "mdb", "vmdk", "vdi", "qcow2", "vhd", "vhdx", "img", "raw",
    ]

    /// En dessous de deux blocs, un fichier compressé n'occupe pas moins
    /// (mesuré sur un volume APFS de test le 18/10/2026).
    public static let minimumFileAllocated: Int64 = 8_192
    /// Au-delà, le fichier n'est pas compressé : la ressource se construit en mémoire.
    public static let maximumFileSize: Int64 = 256 * 1_048_576

    /// Le nom des fichiers temporaires de la compression, pour les reconnaître
    /// (et retirer ceux qu'un arrêt brutal aurait laissés).
    public static let temporaryPrefix = ".~oust-z."

    /// Ce fichier est-il, d'après son nom, à laisser tel quel ?
    public static func skipsFile(named name: String) -> Bool {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        return incompressibleExtensions.contains(fileExtension) || liveDataExtensions.contains(fileExtension)
            || name.hasPrefix(temporaryPrefix)
    }

    /// Ce dossier est-il à laisser tel quel, contenu compris ?
    public static func skipsFolder(named name: String) -> Bool {
        skippedFolders.contains(name) || skippedPackageExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}
