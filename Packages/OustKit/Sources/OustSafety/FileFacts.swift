import Darwin
import Foundation

/// Ce qu'on doit savoir d'un fichier avant de le réécrire (compression) ou de
/// l'évincer : lu par `lstat` et `getattrlist`, jamais en suivant un lien.
public struct FileFacts: Sendable {
    public let inode: UInt64
    public let size: Int64
    /// Ce qu'il occupe vraiment (`st_blocks` × 512).
    public let allocated: Int64
    public let linkCount: Int
    public let flags: UInt32
    public let owner: uid_t
    public let group: gid_t
    public let mode: mode_t
    public let device: Int32
    public let created: timespec
    public let modified: timespec
    /// Change à chaque écriture, renommage ou changement d'attribut, même quand
    /// la date de modification est remise en place derrière.
    public let changed: timespec
    public let isRegularFile: Bool

    public static func of(_ path: String) -> FileFacts? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileFacts(info)
    }

    public static func at(_ name: String, in directory: Int32) -> FileFacts? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return FileFacts(info)
    }

    private init(_ info: stat) {
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        allocated = Int64(info.st_blocks) * 512
        linkCount = Int(info.st_nlink)
        flags = info.st_flags
        owner = info.st_uid
        group = info.st_gid
        mode = info.st_mode
        device = info.st_dev
        created = info.st_birthtimespec
        modified = info.st_mtimespec
        changed = info.st_ctimespec
        isRegularFile = (info.st_mode & S_IFMT) == S_IFREG
    }

    public var modificationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1e9)
    }

    public func userLogID(at url: URL) -> String {
        let path = PathNormalizer.normalize(url.path)
        return "logs.user|\(device):\(inode):\(changed.tv_sec):\(changed.tv_nsec)|\(path)"
    }

    /// Déjà compressé par APFS (`UF_COMPRESSED`).
    public var isCompressed: Bool { flags & FileFlag.compressed != 0 }

    /// Verrouillé (`chflags uchg`, `schg`, `uappnd`) : on n'y touche pas.
    public var isLocked: Bool { flags & FileFlag.locked != 0 }

    /// Contenu resté dans le nuage (`SF_DATALESS`) : le lire le téléchargerait.
    public var isDataless: Bool { flags & FileFlag.dataless != 0 }

    /// Le même contenu, à la même place : rien n'a bougé depuis la première lecture.
    ///
    /// `ignoringChangeTime` : après un renommage, que le système date dans `ctime`.
    public func isUnchanged(comparedTo other: FileFacts, ignoringChangeTime: Bool = false) -> Bool {
        inode == other.inode && size == other.size && linkCount == other.linkCount
            && modified.tv_sec == other.modified.tv_sec && modified.tv_nsec == other.modified.tv_nsec
            && (ignoringChangeTime || (changed.tv_sec == other.changed.tv_sec && changed.tv_nsec == other.changed.tv_nsec))
    }

    /// Les attributs étendus visibles, triés (sans ceux de la compression, que
    /// macOS cache sur un fichier compressé).
    public static func extendedAttributeNames(_ path: String) -> [String]? {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(path, &buffer, size, XATTR_NOFOLLOW) == size else { return nil }
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
    }

    /// La liste de contrôle d'accès, en texte ; `""` s'il n'y en a pas.
    public static func accessControlList(_ path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? "" : nil
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    /// Une partie des blocs est peut-être partagée avec un clone (`EF_MAY_SHARE_BLOCKS`).
    ///
    /// Compresser un clone dupliquerait son contenu au lieu d'en libérer :
    /// l'autre copie garde les blocs d'origine, et la version compressée s'y
    /// ajoute. En cas de lecture impossible, on répond « oui », par prudence.
    public static func mayShareBlocks(_ path: String) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = FileFlag.returnedAttributes
        list.forkattr = FileFlag.extendedFlagsAttribute
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, UInt32(FileFlag.optionExtended | FileFlag.optionNoFollow))
        }
        guard status == 0 else { return true }
        return buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            let returned = base.advanced(by: 4).loadUnaligned(as: attribute_set_t.self)
            guard returned.forkattr & FileFlag.extendedFlagsAttribute != 0 else { return true }
            let flags = base.advanced(by: 4 + MemoryLayout<attribute_set_t>.size).loadUnaligned(as: UInt64.self)
            return flags & FileFlag.mayShareBlocks != 0
        }
    }

    /// Le fichier porte déjà une ressource (`com.apple.ResourceFork`) : la
    /// compression y écrirait la sienne.
    public static func hasResourceFork(_ path: String) -> Bool {
        getxattr(path, XATTR_RESOURCEFORK_NAME, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}

/// Constantes de `sys/stat.h` et `sys/attr.h` en `UInt32`/`UInt64` (vérifiées
/// sur MacOSX27.0.sdk le 18/10/2026, comme celles d'`OustScan`).
public enum FileFlag {
    public static let compressed: UInt32 = 0x0000_0020
    public static let dataless: UInt32 = 0x4000_0000
    /// `UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND`.
    public static let locked: UInt32 = 0x0000_0002 | 0x0000_0004 | 0x0002_0000 | 0x0004_0000

    static let returnedAttributes: UInt32 = 0x8000_0000
    static let extendedFlagsAttribute: UInt32 = 0x0000_0200
    static let optionNoFollow: UInt64 = 0x0000_0001
    static let optionExtended: UInt64 = 0x0000_0020
    static let mayShareBlocks: UInt64 = 0x0000_0001
}
