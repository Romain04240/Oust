import Darwin
import Foundation
import OustCore
import OustSafety
import zlib

/// La compression transparente d'APFS, fichier par fichier, sans jamais mettre
/// l'original en jeu.
///
/// Le format est celui de `decmpfs` (type 4 : zlib par blocs de 64 Kio dans la
/// ressource du fichier), que le noyau décompresse à la lecture ; c'est celui
/// qu'écrivent `ditto` et afsctool depuis Mac OS X 10.6. Pour chaque fichier :
///
/// 1. la version compressée est écrite dans un fichier temporaire, à côté, avec
///    les métadonnées de l'original, puis poussée vers le disque ;
/// 2. elle est **relue par le noyau et comparée octet par octet** à l'original,
///    ses droits, propriétaire, attributs étendus et ACL aussi ;
/// 3. elle n'est gardée que si elle occupe vraiment moins de blocs ;
/// 4. les deux fichiers sont échangés d'un seul `renamex_np(RENAME_SWAP)`, et
///    celui qui sort est revérifié : si ce n'est plus l'original tel qu'on l'a lu
///    (une écriture s'est glissée), l'échange est défait. En cas de doute, le
///    temporaire est jeté et l'original reste tel quel.
///
/// Le premier prototype, le 18/10/2026, recopiait l'en-tête de la ressource au
/// début de sa carte : `chflags` acceptait le fichier, `du` le montrait plus
/// petit, et toute lecture échouait (EINVAL). La relecture de l'étape 2 existe
/// pour ce genre d'erreur-là.
enum Compressor {

    struct Summary: Sendable, Equatable {
        var savedBytes: Int64 = 0
        var compressed = 0
        var skipped = 0
        var failures: [String] = []
    }

    enum FileResult: Sendable, Equatable {
        case compressed(saved: Int64)
        case skipped(String)
        case failed(String)
    }

    static let chunk = 65_536
    static let decmpfsName = "com.apple.decmpfs"
    static let decmpfsMagic: UInt32 = 0x636d_7066 // « cmpf »
    static let zlibInResourceFork: UInt32 = 4

    /// Compresse tout ce qui peut l'être sous `root`, sans quitter son volume.
    /// Un fichier modifié après `notAfter` (l'analyse l'a vu endormi, quelqu'un
    /// l'a rouvert depuis) est laissé tel quel, comme tout fichier qu'un
    /// processus garde ouvert. Les dates des dossiers sont rendues à la fin : le
    /// projet garde l'air de n'avoir pas bougé, ce qui est vrai.
    static func compressTree(_ root: URL, notAfter: Date?, isCancelled: () -> Bool = { false }) -> Summary {
        var summary = Summary()
        guard let rootFacts = FileFacts.of(root.path) else { return summary }
        let open = OpenFiles.paths(under: root.path)
        var folderTimes: [(String, timespec, timespec)] = []
        if let facts = times(of: root.path) { folderTimes.append((root.path, facts.0, facts.1)) }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                        options: [])
        while let url = enumerator?.nextObject() as? URL {
            if isCancelled() { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                // Un point de montage ou un dossier d'un autre volume : on n'y descend pas
                // (RULES.md, règle 10).
                if CompressionPolicy.skipsFolder(named: url.lastPathComponent)
                    || FileFacts.of(url.path)?.device != rootFacts.device {
                    enumerator?.skipDescendants()
                    continue
                }
                if let facts = times(of: url.path) { folderTimes.append((url.path, facts.0, facts.1)) }
                continue
            }
            let name = url.lastPathComponent
            if name.hasPrefix(CompressionPolicy.temporaryPrefix) {
                removeLeftover(url)
                continue
            }
            if CompressionPolicy.skipsFile(named: name) || open.contains(PathNormalizer.normalize(url.path)) {
                summary.skipped += 1
                continue
            }
            switch compressFile(url, notAfter: notAfter) {
            case .compressed(let saved):
                summary.compressed += 1
                summary.savedBytes += saved
            case .skipped:
                summary.skipped += 1
            case .failed(let message):
                summary.failures.append("\(name): \(message)")
            }
        }
        // Du plus profond au moins profond : rendre la date d'un dossier ne
        // change pas celle de son parent.
        for (path, access, modification) in folderTimes.reversed() {
            setTimes(path, access: access, modification: modification)
        }
        return summary
    }

    /// Un temporaire qu'un arrêt brutal a laissé : le nôtre (nom, propriétaire,
    /// drapeau de compression), jamais un fichier de l'utilisateur.
    static func removeLeftover(_ url: URL) {
        guard let facts = FileFacts.of(url.path), facts.isRegularFile, facts.isCompressed, facts.owner == getuid(),
              url.lastPathComponent.hasPrefix(CompressionPolicy.temporaryPrefix) else { return }
        unlink(url.path)
    }

    // MARK: - Un fichier

    static func compressFile(_ url: URL, notAfter: Date? = nil) -> FileResult {
        let path = url.path
        guard let original = FileFacts.of(path) else { return .skipped("vanished") }
        guard original.isRegularFile, !original.isCompressed, !original.isLocked, !original.isDataless else {
            return .skipped("not-eligible")
        }
        guard original.linkCount == 1 else { return .skipped("hard-linked") }
        guard original.owner == getuid() else { return .skipped("owner") }
        guard original.size > 0, original.size <= CompressionPolicy.maximumFileSize,
              original.allocated >= CompressionPolicy.minimumFileAllocated else {
            return .skipped("size")
        }
        if let notAfter, original.modificationDate > notAfter.addingTimeInterval(1) { return .skipped("modified") }
        guard !FileFacts.hasResourceFork(path) else { return .skipped("resource-fork") }
        // Un clone partage ses blocs : le compresser ajouterait une copie au lieu d'en retirer une.
        guard !FileFacts.mayShareBlocks(path) else { return .skipped("clone") }
        guard let attributes = FileFacts.extendedAttributeNames(path), let acl = FileFacts.accessControlList(path) else {
            return .skipped("metadata-unreadable")
        }

        guard let fork = compressedFork(of: path, size: original.size) else { return .skipped("incompressible") }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(CompressionPolicy.temporaryPrefix + UUID().uuidString).path
        if let error = writeCompressed(fork, size: original.size, from: path, to: temporary, like: original) {
            unlink(temporary)
            return .failed(error)
        }
        // La preuve : le noyau relit le fichier compressé, et c'est bien l'original.
        guard let written = FileFacts.of(temporary), written.isCompressed, written.size == original.size,
              contentsEqual(path, temporary) else {
            unlink(temporary)
            return .failed("verification")
        }
        // Et il porte les mêmes droits, le même propriétaire, les mêmes attributs :
        // un script qui perdrait son bit d'exécution ne serait plus le même fichier.
        guard written.mode == original.mode, written.owner == original.owner, written.group == original.group,
              FileFacts.extendedAttributeNames(temporary) == attributes, FileFacts.accessControlList(temporary) == acl else {
            unlink(temporary)
            return .failed("metadata")
        }
        guard written.allocated < original.allocated else {
            unlink(temporary)
            return .skipped("no-gain")
        }
        copyTimes(from: path, to: temporary)
        return swapIn(temporary, for: path, original: original, saved: original.allocated - written.allocated)
    }

    /// Échange l'original et sa version compressée, puis s'assure que ce qui est
    /// sorti est bien l'original tel qu'on l'a lu. Sinon, l'échange est défait.
    static func swapIn(_ temporary: String, for path: String, original: FileFacts, saved: Int64) -> FileResult {
        guard let before = FileFacts.of(path), before.isUnchanged(comparedTo: original) else {
            unlink(temporary)
            return .skipped("changed")
        }
        guard renamex_np(temporary, path, UInt32(RENAME_SWAP)) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temporary)
            return .failed(message)
        }
        // `temporary` désigne maintenant l'original. L'échange vient d'en changer le
        // `ctime` ; une écriture glissée entre-temps aurait changé sa date de
        // modification ou sa taille.
        guard let outgoing = FileFacts.of(temporary), outgoing.isUnchanged(comparedTo: original, ignoringChangeTime: true) else {
            // Quelqu'un a écrit dans l'original au dernier moment : on le remet en place.
            if renamex_np(temporary, path, UInt32(RENAME_SWAP)) == 0 { unlink(temporary) }
            return .skipped("changed")
        }
        unlink(temporary)
        return .compressed(saved: saved)
    }

    /// La ressource `decmpfs` du fichier : en-tête, table des blocs, blocs zlib,
    /// carte. `nil` si le fichier ne se compresse pas (on le sait dès les
    /// premiers blocs) ou ne se lit pas.
    static func compressedFork(of path: String, size: Int64) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let count = Int((size + Int64(chunk) - 1) / Int64(chunk))
        var blocks: [[UInt8]] = []
        blocks.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: chunk)
        var input: Int64 = 0
        var output: Int64 = 0
        for index in 0..<count {
            let wanted = Int(min(Int64(chunk), size - Int64(index) * Int64(chunk)))
            guard readFully(fd, into: &buffer, count: wanted) else { return nil }
            guard let block = deflate(Array(buffer.prefix(wanted))) else { return nil }
            input += Int64(wanted)
            output += Int64(block.count)
            // Quatre blocs qui ne gagnent rien : la suite n'en gagnera pas davantage.
            if index == 3, output * 100 > input * 95 { return nil }
            blocks.append(block)
        }
        guard output < input else { return nil }

        var data = littleEndian(UInt32(count))
        var offset = UInt32(4 + 8 * count)
        for block in blocks {
            data += littleEndian(offset) + littleEndian(UInt32(block.count))
            offset += UInt32(block.count)
        }
        for block in blocks { data += block }

        let dataOffset: UInt32 = 0x100
        let dataLength = UInt32(4 + data.count)
        let header = bigEndian(dataOffset) + bigEndian(dataOffset + dataLength) + bigEndian(dataLength) + bigEndian(0x32)
        var fork = header + [UInt8](repeating: 0, count: Int(dataOffset) - header.count)
        fork += bigEndian(UInt32(data.count)) + data
        // La carte : sa copie d'en-tête reste à zéro, sinon le noyau refuse de lire.
        fork += [UInt8](repeating: 0, count: 24)
        fork += [0x00, 0x1C, 0x00, 0x32, 0x00, 0x00] + Array("cmpf".utf8)
        fork += [0x00, 0x00, 0x00, 0x0A, 0x00, 0x01, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        return fork
    }

    /// Crée le fichier compressé : métadonnées de l'original, ressource, en-tête
    /// `decmpfs`, le drapeau qui dit au noyau de décompresser, puis le disque.
    static func writeCompressed(_ fork: [UInt8], size: Int64, from original: String, to temporary: String,
                                like facts: FileFacts) -> String? {
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        defer { close(fd) }
        // ACL et attributs étendus de l'original (étiquettes, quarantaine…). Les
        // droits viennent après : un original en lecture seule interdirait d'écrire
        // la ressource.
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        guard copyfile(original, temporary, state, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else {
            return "copyfile: " + String(cString: strerror(errno))
        }

        var status = fork.withUnsafeBytes { fsetxattr(fd, XATTR_RESOURCEFORK_NAME, $0.baseAddress, $0.count, 0, 0) }
        guard status == 0 else { return "resource-fork: " + String(cString: strerror(errno)) }
        let header = littleEndian(decmpfsMagic) + littleEndian(zlibInResourceFork) + littleEndian(UInt64(size))
        status = header.withUnsafeBytes { fsetxattr(fd, decmpfsName, $0.baseAddress, $0.count, 0, 0) }
        guard status == 0 else { return "decmpfs: " + String(cString: strerror(errno)) }
        guard fchmod(fd, facts.mode & 0o7777) == 0, fchown(fd, uid_t.max, facts.group) == 0 else {
            return "chmod: " + String(cString: strerror(errno))
        }
        // Seuls les drapeaux de l'utilisateur se recopient (`UF_SETTABLE`) : ceux
        // du système ne lui appartiennent pas.
        guard fchflags(fd, (facts.flags & 0x0000_FFFF) | FileFlag.compressed) == 0 else {
            return "chflags: " + String(cString: strerror(errno))
        }
        // Rien n'est échangé avant que la version compressée soit sur le disque : la
        // barrière garantit qu'après un arrêt brutal, le nom désigne soit
        // l'original, soit une copie complète, jamais une ressource à moitié écrite.
        if fcntl(fd, F_BARRIERFSYNC) != 0, fsync(fd) != 0 { return "fsync: " + String(cString: strerror(errno)) }
        return nil
    }

    // MARK: - Vérification

    /// Les deux fichiers lus jusqu'au bout et comparés bloc par bloc.
    static func contentsEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = open(lhs, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let right = open(rhs, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        defer {
            if left >= 0 { close(left) }
            if right >= 0 { close(right) }
        }
        guard left >= 0, right >= 0 else { return false }
        var a = [UInt8](repeating: 0, count: chunk)
        var b = [UInt8](repeating: 0, count: chunk)
        while true {
            let countA = readChunk(left, into: &a)
            let countB = readChunk(right, into: &b)
            guard countA >= 0, countB >= 0, countA == countB else { return false }
            if countA == 0 { return true }
            guard a.prefix(countA) == b.prefix(countB) else { return false }
        }
    }

    /// Lit jusqu'à remplir le tampon ou atteindre la fin ; -1 sur erreur.
    static func readChunk(_ fd: Int32, into buffer: inout [UInt8]) -> Int {
        var done = 0
        while done < buffer.count {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: done), $0.count - done) }
            if count < 0 { return -1 }
            if count == 0 { break }
            done += count
        }
        return done
    }

    // MARK: - Outils

    static func deflate(_ input: [UInt8]) -> [UInt8]? {
        var length = compressBound(uLong(input.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = output.withUnsafeMutableBufferPointer { out in
            input.withUnsafeBufferPointer { source in
                compress2(out.baseAddress, &length, source.baseAddress, uLong(input.count), 6)
            }
        }
        return status == Z_OK ? Array(output.prefix(Int(length))) : nil
    }

    static func readFully(_ fd: Int32, into buffer: inout [UInt8], count: Int) -> Bool {
        var done = 0
        while done < count {
            let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: done), count - done) }
            guard read > 0 else { return false }
            done += read
        }
        return true
    }

    static func times(of path: String) -> (timespec, timespec)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (info.st_atimespec, info.st_mtimespec)
    }

    static func setTimes(_ path: String, access: timespec, modification: timespec) {
        var times = [access, modification]
        _ = utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
    }

    /// Les dates de l'original, création comprise, sur sa version compressée.
    static func copyTimes(from original: String, to temporary: String) {
        var info = stat()
        guard lstat(original, &info) == 0 else { return }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var birth = info.st_birthtimespec
        _ = setattrlist(temporary, &list, &birth, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
        setTimes(temporary, access: info.st_atimespec, modification: info.st_mtimespec)
    }

    static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}
