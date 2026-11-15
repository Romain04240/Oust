import Darwin
import Foundation

/// Constantes de `sys/attr.h` et `sys/stat.h`, réécrites ici en `UInt32`.
///
/// Swift importe ces macros en `Int32` (ou pas du tout pour certaines) ; les
/// réécrire évite une conversion à chaque masque et rend les valeurs vérifiables
/// contre le SDK d'un coup d'œil (vérifiées sur MacOSX27.0.sdk le 18/10/2026).
enum Attr {
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnDevID: UInt32 = 0x0000_0002
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnModTime: UInt32 = 0x0000_0400
    static let cmnAccTime: UInt32 = 0x0000_1000
    static let cmnFlags: UInt32 = 0x0004_0000
    static let cmnFileID: UInt32 = 0x0200_0000
    static let cmnError: UInt32 = 0x2000_0000
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000

    static let dirMountStatus: UInt32 = 0x0000_0004
    static let dirMountPoint: UInt32 = 0x0000_0001

    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileAllocSize: UInt32 = 0x0000_0004
    static let fileDataLength: UInt32 = 0x0000_0200

    static let cmnextPrivateSize: UInt32 = 0x0000_0008
    static let cmnextCloneID: UInt32 = 0x0000_0100
    static let cmnextExtFlags: UInt32 = 0x0000_0200

    static let optNoFollow: UInt64 = 0x0000_0001
    static let optCmnExtended: UInt64 = 0x0000_0020

    /// `EF_MAY_SHARE_BLOCKS` : une partie des blocs peut être partagée.
    static let efMayShareBlocks: UInt64 = 0x0000_0001
    /// `EF_SHARES_ALL_BLOCKS` : clone complet, tous les blocs sont partagés.
    static let efSharesAllBlocks: UInt64 = 0x0000_0040

    static let sfFirmlink: UInt32 = 0x0080_0000
    static let sfDataless: UInt32 = 0x4000_0000
    static let ufCompressed: UInt32 = 0x0000_0020

    static let typeRegular: UInt32 = 1
    static let typeDirectory: UInt32 = 2
    static let typeSymlink: UInt32 = 5
}

/// Une entrée de dossier, telle que `getattrlistbulk` la décrit.
struct RawEntry {
    var name: String = ""
    var type: UInt32 = 0
    var device: Int32 = 0
    var flags: UInt32 = 0
    var modified: Date?
    var accessed: Date?
    var fileID: UInt64 = 0
    var mountStatus: UInt32 = 0
    var linkCount: UInt32 = 1
    var allocated: Int64 = 0
    /// Taille logique de la branche de données, celle que `stat` appelle `st_size`.
    var logicalSize: Int64 = 0
    var cloneID: UInt64 = 0
    var extFlags: UInt64 = 0
    var error: UInt32 = 0

    var isDirectory: Bool { type == Attr.typeDirectory }
    var isMountPoint: Bool { mountStatus & Attr.dirMountPoint != 0 }
    var isFirmlink: Bool { flags & Attr.sfFirmlink != 0 }
    var isDataless: Bool { flags & Attr.sfDataless != 0 }
    var isFullClone: Bool { extFlags & Attr.efSharesAllBlocks != 0 }
    var mayShareBlocks: Bool { extFlags & Attr.efMayShareBlocks != 0 }
}

/// Lit un dossier d'un seul appel système par lot d'entrées.
///
/// `getattrlistbulk` est 30 à 46 % plus rapide que `readdir` + `stat`, et rend
/// d'un coup tout ce qu'il faut : taille allouée, inode, nombre de liens, état
/// de montage, identifiant de clone.
enum BulkReader {

    /// Les attributs étendus (clone) ne sont pas acceptés partout : un volume
    /// qui les refuse fait échouer l'appel en `EINVAL`, et on recommence sans.
    static func read(
        directoryFD fd: Int32,
        extended: Bool,
        buffer: UnsafeMutableRawBufferPointer,
        visit: (RawEntry) -> Void
    ) -> Int32 {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = Attr.cmnReturnedAttrs | Attr.cmnError | Attr.cmnName | Attr.cmnDevID
            | Attr.cmnObjType | Attr.cmnModTime | Attr.cmnAccTime | Attr.cmnFlags | Attr.cmnFileID
        list.dirattr = Attr.dirMountStatus
        // La taille logique en plus de l'allouée : les doublons se comparent sur
        // elle (deux copies identiques, l'une compressée, n'occupent pas pareil).
        list.fileattr = Attr.fileLinkCount | Attr.fileAllocSize | Attr.fileDataLength
        list.forkattr = extended ? (Attr.cmnextCloneID | Attr.cmnextExtFlags) : 0
        let options: UInt64 = extended ? Attr.optCmnExtended : 0

        while true {
            let count = getattrlistbulk(fd, &list, buffer.baseAddress, buffer.count, options)
            if count < 0 { return errno }
            if count == 0 { return 0 }
            var offset = 0
            for _ in 0..<count {
                guard let base = buffer.baseAddress else { return EINVAL }
                let entryStart = base.advanced(by: offset)
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                guard length > 0 else { return EINVAL }
                visit(parse(entryStart))
                offset += length
            }
        }
    }

    /// Décode une entrée. L'ordre des champs est fixé par le noyau : longueur,
    /// attributs rendus, erreur, puis les attributs communs dans l'ordre de leurs
    /// bits, puis ceux de dossier, de fichier, et enfin les étendus. Les valeurs
    /// ne sont alignées que sur 4 octets : lecture `loadUnaligned` partout.
    private static func parse(_ start: UnsafeMutableRawPointer) -> RawEntry {
        var entry = RawEntry()
        var cursor = start.advanced(by: 4)
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)

        let common = returned.commonattr
        if common & Attr.cmnError != 0 {
            entry.error = cursor.loadUnaligned(as: UInt32.self)
            cursor = cursor.advanced(by: 4)
        }
        if common & Attr.cmnName != 0 {
            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            let namePointer = cursor.advanced(by: Int(reference.attr_dataoffset))
            let length = max(0, Int(reference.attr_length) - 1)
            entry.name = String(decoding: UnsafeRawBufferPointer(start: namePointer, count: length), as: UTF8.self)
            cursor = cursor.advanced(by: MemoryLayout<attrreference_t>.size)
        }
        if common & Attr.cmnDevID != 0 {
            entry.device = cursor.loadUnaligned(as: Int32.self)
            cursor = cursor.advanced(by: 4)
        }
        if common & Attr.cmnObjType != 0 {
            entry.type = cursor.loadUnaligned(as: UInt32.self)
            cursor = cursor.advanced(by: 4)
        }
        if common & Attr.cmnModTime != 0 {
            let time = cursor.loadUnaligned(as: timespec.self)
            entry.modified = Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
            cursor = cursor.advanced(by: MemoryLayout<timespec>.size)
        }
        // Le dernier accès, pour « Gros et vieux fichiers ». Une date nulle
        // (volume qui ne la tient pas) ne veut pas dire « jamais ouvert ».
        if common & Attr.cmnAccTime != 0 {
            let time = cursor.loadUnaligned(as: timespec.self)
            if time.tv_sec > 0 {
                entry.accessed = Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
            }
            cursor = cursor.advanced(by: MemoryLayout<timespec>.size)
        }
        if common & Attr.cmnFlags != 0 {
            entry.flags = cursor.loadUnaligned(as: UInt32.self)
            cursor = cursor.advanced(by: 4)
        }
        if common & Attr.cmnFileID != 0 {
            entry.fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor = cursor.advanced(by: 8)
        }
        if returned.dirattr & Attr.dirMountStatus != 0 {
            entry.mountStatus = cursor.loadUnaligned(as: UInt32.self)
            cursor = cursor.advanced(by: 4)
        }
        if returned.fileattr & Attr.fileLinkCount != 0 {
            entry.linkCount = cursor.loadUnaligned(as: UInt32.self)
            cursor = cursor.advanced(by: 4)
        }
        if returned.fileattr & Attr.fileAllocSize != 0 {
            entry.allocated = cursor.loadUnaligned(as: Int64.self)
            cursor = cursor.advanced(by: 8)
        }
        if returned.fileattr & Attr.fileDataLength != 0 {
            entry.logicalSize = cursor.loadUnaligned(as: Int64.self)
            cursor = cursor.advanced(by: 8)
        }
        if returned.forkattr & Attr.cmnextCloneID != 0 {
            entry.cloneID = cursor.loadUnaligned(as: UInt64.self)
            cursor = cursor.advanced(by: 8)
        }
        if returned.forkattr & Attr.cmnextExtFlags != 0 {
            entry.extFlags = cursor.loadUnaligned(as: UInt64.self)
            cursor = cursor.advanced(by: 8)
        }
        return entry
    }

    /// La part privée d'un fichier : ce que sa suppression rendrait vraiment.
    ///
    /// Demandée fichier par fichier, et seulement quand `EF_MAY_SHARE_BLOCKS`
    /// le justifie : l'attribut coûte cher, et la plupart des fichiers n'ont rien
    /// de partagé.
    static func privateSize(directoryFD fd: Int32, name: String) -> Int64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = Attr.cmnReturnedAttrs
        list.forkattr = Attr.cmnextPrivateSize
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { raw in
            name.withCString { cName in
                getattrlistat(fd, cName, &list, raw.baseAddress, raw.count,
                              UInt(Attr.optCmnExtended | Attr.optNoFollow))
            }
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let returned = base.advanced(by: 4).loadUnaligned(as: attribute_set_t.self)
            guard returned.forkattr & Attr.cmnextPrivateSize != 0 else { return nil }
            return base.advanced(by: 4 + MemoryLayout<attribute_set_t>.size).loadUnaligned(as: Int64.self)
        }
    }

    /// Même chose pour un chemin complet, appelé sans connaître les drapeaux :
    /// nil quand le fichier ne partage aucun bloc. APFS rend alors une part
    /// privée de 0, pas sa taille, et un doublon ordinaire semblait ne rien
    /// libérer (« — » sur chaque copie, corbeille à « — à libérer »,
    /// 18/10/2026). L'appelant retombe sur la taille allouée.
    static func privateSize(path: String) -> Int64? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return privateSize { list, buffer, count in
            name.withCString { getattrlistat(fd, $0, list, buffer, count, UInt(Attr.optCmnExtended | Attr.optNoFollow)) }
        }.flatMap { $0.sharesBlocks ? $0.size : nil }
    }

    /// Les champs étendus suivent l'ordre de leurs bits et les champs absents
    /// sont omis. Le clone et la taille restent deux preuves indépendantes.
    static func blockSharing(descriptor: Int32, allocated: Int64) -> (privateSize: Int64?, fullCloneID: UInt64?) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = Attr.cmnReturnedAttrs
        list.forkattr = Attr.cmnextPrivateSize | Attr.cmnextCloneID | Attr.cmnextExtFlags
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { raw in
            fgetattrlist(descriptor, &list, raw.baseAddress, raw.count, UInt32(Attr.optCmnExtended))
        }
        guard status == 0 else { return (nil, nil) }
        return buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return (nil, nil) }
            let length = Int(base.loadUnaligned(as: UInt32.self))
            let first = 4 + MemoryLayout<attribute_set_t>.size
            guard (first...raw.count).contains(length) else { return (nil, nil) }
            let returned = base.advanced(by: 4).loadUnaligned(as: attribute_set_t.self)
            var offset = first
            func field(_ bit: UInt32) -> UInt64? {
                guard returned.forkattr & bit != 0, offset + 8 <= length else { return nil }
                defer { offset += 8 }
                return base.advanced(by: offset).loadUnaligned(as: UInt64.self)
            }
            let size = field(Attr.cmnextPrivateSize).flatMap { Int64(exactly: $0) }
            let cloneID = field(Attr.cmnextCloneID)
            guard let flags = field(Attr.cmnextExtFlags) else { return (nil, nil) }
            let privateSize = size.map { bytes in
                flags & Attr.efMayShareBlocks != 0 ? min(allocated, bytes) : allocated
            }
            let fullClone = flags & Attr.efSharesAllBlocks != 0 && cloneID != 0 ? cloneID : nil
            return (privateSize, fullClone)
        }
    }

    private static func privateSize(_ fetch: (UnsafeMutablePointer<attrlist>, UnsafeMutableRawPointer?, Int) -> Int32)
    -> (size: Int64, sharesBlocks: Bool)? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = Attr.cmnReturnedAttrs
        // Rangés dans l'ordre de leurs bits : la part privée, puis les drapeaux.
        let wanted = Attr.cmnextPrivateSize | Attr.cmnextExtFlags
        list.forkattr = wanted
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { raw in
            fetch(&list, raw.baseAddress, raw.count)
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let returned = base.advanced(by: 4).loadUnaligned(as: attribute_set_t.self)
            guard returned.forkattr & wanted == wanted else { return nil }
            let values = base.advanced(by: 4 + MemoryLayout<attribute_set_t>.size)
            let size = values.loadUnaligned(as: Int64.self)
            let flags = values.advanced(by: 8).loadUnaligned(as: UInt64.self)
            guard size >= 0 else { return nil }
            return (size, flags & Attr.efMayShareBlocks != 0)
        }
    }
}
