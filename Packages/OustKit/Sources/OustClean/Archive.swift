import Darwin
import Foundation
import OustCore
import OustSafety

/// Le dernier contrôle avant d'envoyer à la corbeille du Mac un projet archivé :
/// l'original est-il encore exactement celui qu'on a copié ?
///
/// La copie a été vérifiée octet par octet au moment de la faire. Entre-temps,
/// quelqu'un a pu ouvrir le projet, y enregistrer un fichier, en ajouter un :
/// alors l'original n'est plus couvert par l'archive, et il reste en place.
/// La comparaison porte sur la structure, les tailles, les dates et les cibles
/// des liens ; elle ne relit pas les contenus, déjà comparés à la copie.
public enum ArchiveSeal {

    public static func originalMatchesCopy(original: URL, copy: URL) -> Bool {
        guard let mine = listing(of: original.path), let theirs = listing(of: copy.path) else { return false }
        for (relative, entry) in mine {
            guard let other = theirs[relative], entry.matches(other) else { return false }
        }
        // Rien de plus dans la copie, sinon les fichiers `._` qu'un volume exFAT
        // ou FAT ajoute pour garder les attributs étendus.
        for relative in theirs.keys where mine[relative] == nil {
            guard (relative as NSString).lastPathComponent.hasPrefix("._") else { return false }
        }
        return true
    }

    struct Entry {
        let type: mode_t
        let size: Int64
        let modified: Double
        let target: String?

        func matches(_ other: Entry) -> Bool {
            guard type == other.type else { return false }
            switch type {
            case S_IFREG:
                // Deux secondes : la précision des dates sur FAT (exFAT : 10 ms).
                return size == other.size && abs(modified - other.modified) <= 2
            case S_IFLNK:
                return target == other.target
            default:
                return true
            }
        }
    }

    /// Toutes les entrées sous `root`, par chemin relatif ; `nil` si une seule
    /// est illisible (dans le doute, on garde l'original).
    static func listing(of root: String) -> [String: Entry]? {
        var entries: [String: Entry] = [:]
        var pending = [""]
        while let relativeDirectory = pending.popLast() {
            let directory = relativeDirectory.isEmpty ? root : root + "/" + relativeDirectory
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
            for name in names {
                let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
                var info = stat()
                guard lstat(directory + "/" + name, &info) == 0 else { return nil }
                let type = info.st_mode & S_IFMT
                var target: String?
                if type == S_IFLNK {
                    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                    let length = readlink(directory + "/" + name, &buffer, buffer.count - 1)
                    guard length >= 0 else { return nil }
                    target = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
                entries[relative] = Entry(type: type, size: Int64(info.st_size), modified: modified, target: target)
                if type == S_IFDIR { pending.append(relative) }
            }
        }
        return entries
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
