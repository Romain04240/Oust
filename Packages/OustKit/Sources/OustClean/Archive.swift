import CryptoKit
import Darwin
import Foundation
import OustCore
import OustSafety

/// Revalidation complète juste avant la corbeille : structure, SHA-256 et
/// stabilité de chaque entrée lue. Une erreur conserve toujours l'original.
public enum ArchiveSeal {
    public static func originalMatchesCopy(original: URL, copy: URL) -> Bool {
        guard let mine = listing(of: original.path), let theirs = listing(of: copy.path) else { return false }
        for (relative, entry) in mine {
            guard let other = theirs[relative], entry.matches(other) else { return false }
        }
        for relative in theirs.keys where mine[relative] == nil {
            guard (relative as NSString).lastPathComponent.hasPrefix("._") else { return false }
        }
        // Relire les identités après les deux empreintes évite de valider un
        // fichier déjà haché qui aurait changé pendant la lecture de la copie.
        return stable(mine, under: original.path) && stable(theirs, under: copy.path)
    }

    struct Stamp: Equatable {
        let device: Int32
        let inode: UInt64
        let mode: mode_t
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev; inode = UInt64(info.st_ino); mode = info.st_mode; size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    struct Entry {
        let stamp: Stamp
        let hash: SHA256.Digest?
        let resourceForkHash: SHA256.Digest?
        let target: String?

        func matches(_ other: Entry) -> Bool {
            guard stamp.mode & S_IFMT == other.stamp.mode & S_IFMT else { return false }
            switch stamp.mode & S_IFMT {
            case S_IFREG: return stamp.size == other.stamp.size && hash == other.hash && resourceForkHash == other.resourceForkHash
            case S_IFLNK: return target == other.target
            case S_IFDIR: return true
            default: return false
            }
        }
    }

    static func stable(_ entries: [String: Entry], under root: String) -> Bool {
        for (relative, entry) in entries {
            let path = relative.isEmpty ? root : root + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0, Stamp(info) == entry.stamp else { return false }
        }
        return true
    }

    /// La fourche de ressources est du contenu personnel aussi ; comparer la
    /// seule fourche de données pourrait autoriser une perte silencieuse.
    static func resourceFork(of path: String) -> (valid: Bool, hash: SHA256.Digest?) {
        let length = getxattr(path, XATTR_RESOURCEFORK_NAME, nil, 0, 0, XATTR_NOFOLLOW)
        if length < 0 { return (errno == ENOATTR || errno == ENOTSUP, nil) }
        if length == 0 { return (true, nil) }
        let fd = open(path + "/..namedfork/rsrc", O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return (false, nil) }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total = 0
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return (false, nil) }
            if count == 0 { break }
            total += count
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return total == length ? (true, hasher.finalize()) : (false, nil)
    }

    /// Aucun lien suivi et aucun autre volume traversé, même à la revalidation.
    static func listing(of root: String) -> [String: Entry]? {
        var rootInfo = stat()
        guard lstat(root, &rootInfo) == 0, [S_IFREG, S_IFDIR].contains(rootInfo.st_mode & S_IFMT) else { return nil }
        var entries: [String: Entry] = [:]
        var pending = [""]
        while let relative = pending.popLast() {
            let path = relative.isEmpty ? root : root + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0, info.st_dev == rootInfo.st_dev,
                  info.st_flags & (UInt32(SF_DATALESS) | 0x0080_0000) == 0 else { return nil }
            let before = Stamp(info)
            var hash: SHA256.Digest?
            var resourceForkHash: SHA256.Digest?
            var target: String?
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
                pending += names.map { relative.isEmpty ? $0 : relative + "/" + $0 }
            case S_IFREG:
                let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { return nil }
                var opened = stat()
                guard fstat(fd, &opened) == 0, Stamp(opened) == before else { close(fd); return nil }
                _ = fcntl(fd, F_NOCACHE, 1)
                var hasher = SHA256()
                var buffer = [UInt8](repeating: 0, count: 1 << 20)
                var failed = false
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count < 0 { if errno == EINTR { continue }; failed = true; break }
                    if count == 0 { break }
                    hasher.update(data: Data(buffer.prefix(count)))
                }
                close(fd)
                guard !failed else { return nil }
                hash = hasher.finalize()
                let fork = resourceFork(of: path)
                guard fork.valid else { return nil }
                resourceForkHash = fork.hash
            case S_IFLNK:
                guard let value = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
                target = value
            default: return nil
            }
            var after = stat()
            guard lstat(path, &after) == 0, Stamp(after) == before else { return nil }
            entries[relative] = Entry(stamp: before, hash: hash, resourceForkHash: resourceForkHash, target: target)
        }
        return stable(entries, under: root) ? entries : nil
    }
}

/// Le dossier de préparation d'une archive : la copie s'y fait, et il n'est
/// renommé qu'une fois la copie vérifiée.
///
/// Son nom porte une marque qu'aucun dossier de l'utilisateur ne porte
/// (`.<projet>.oust-partial-<UUID>`). C'est elle qui autorise `discard` à retirer
/// une copie inachevée, et rien d'autre : l'original, lui, n'a pas été touché.
public enum ArchiveStaging {
    static let marker = ".oust-partial-"

    public static func name(for project: String) -> String {
        "." + project + marker + UUID().uuidString
    }

    public static func isStaging(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), let range = name.range(of: marker, options: .backwards) else { return false }
        return UUID(uuidString: String(name[range.upperBound...])) != nil
    }

    /// Retire une copie inachevée. Refuse tout ce qui n'est pas un dossier de
    /// préparation, et tout ce que la garde de chemins refuse.
    @discardableResult
    public static func discard(_ url: URL, pathGuard: PathGuard = PathGuard()) -> Bool {
        guard isStaging(url), pathGuard.allows(url) else { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        // Une copie peut porter les droits d'un dossier en lecture seule : on se
        // les rend avant de retirer ce qu'on a soi-même écrit.
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            chmod(url.path, 0o700)
            for case let relative as String in enumerator {
                var entry = stat()
                let path = url.path + "/" + relative
                if lstat(path, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR { chmod(path, 0o700) }
            }
        }
        return Remover.remove(url) == nil
    }
}
