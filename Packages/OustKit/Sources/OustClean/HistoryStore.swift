import Darwin
import Foundation
import OustCore
import OustSafety

/// L'historique local des nettoyages (SPEC §6.3).
///
/// Une ligne JSON par élément traité, ajoutée à la fin d'un fichier : rien ne se
/// réécrit, rien ne se perd si l'application s'arrête au milieu d'un nettoyage.
/// Ce qui a été restauré est noté à part, pour ne jamais modifier une ligne.
public actor HistoryStore {
    public nonisolated let directory: URL
    private static let historyName = "history.jsonl"
    private static let restoredName = "restored.jsonl"

    /// Vrai si `path` est l'un des fichiers du journal (nettoyages ou
    /// restaurations) : ce qui, en changeant, change l'Historique.
    public static func isJournal(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == historyName || name == restoredName
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Oust` : le seul endroit où Oust! écrit.
    public static func standard() -> HistoryStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HistoryStore(directory: support.appendingPathComponent("Oust", isDirectory: true))
    }

    public func append(_ outcome: CleanupOutcome) throws {
        try withHistoryWriter { file, _ in try write(outcome, to: file) }
    }

    func appendRecoveredUserLog(_ outcome: CleanupOutcome) throws {
        // Si l'historique manque, la reprise conserve le reçu sans rien créer.
        try withHistoryWriter(create: false) { file, parent in
            try validateDestination(file)
            let existing = try lines(in: file).reversed().lazy
                .compactMap { try? self.decoder.decode(CleanupOutcome.self, from: $0) }
                .first { $0.id == outcome.id }
            if try existing.map(encoder.encode) != encoder.encode(outcome) {
                try write(outcome, to: file)
            }
            guard fsync(file) == 0, fsync(parent) == 0 else { throw Self.posixError() }
        }
    }

    /// Tout l'historique, le plus récent d'abord.
    public func load() -> [CleanupOutcome] {
        var seenUserLogs = Set<String>()
        return read(Self.historyName).reversed().compactMap { line in
            guard let outcome = try? decoder.decode(CleanupOutcome.self, from: line) else { return nil }
            guard outcome.category != .userLogs || seenUserLogs.insert(outcome.id).inserted else { return nil }
            return outcome
        }
    }

    public func restoredIDs() -> Set<String> {
        Set(read(Self.restoredName).compactMap { try? decoder.decode(RestoredMark.self, from: $0).id })
    }

    /// Un chemin stocké dans l'historique peut changer après le contrôle.
    /// La restauration reste bloquée tant que les identités et l'emplacement
    /// des dossiers ne peuvent pas être garantis au moment du renommage.
    public func restore(_: CleanupOutcome, pathGuard _: PathGuard = PathGuard()) throws {
        throw RestoreError.notRestorable
    }

    public enum RestoreError: Error, Sendable {
        case notRestorable
        case goneFromTrash
        case originalOccupied
    }

    private struct RestoredMark: Codable {
        let id: String
        let date: Date
    }

    /// Lève une erreur si le journal ne peut pas être écrit : la CLI des agents
    /// refuse de nettoyer ce qu'elle ne pourrait pas journaliser.
    public func ensureWritable() throws {
        try withHistoryWriter { file, _ in try validateDestination(file) }
    }

    private func withHistoryWriter(create: Bool = true, _ action: (Int32, Int32) throws -> Void) throws {
        let parent = try openDirectory(create: create)
        defer { close(parent) }
        let flags = O_RDWR | O_APPEND | (create ? O_CREAT : 0)
        let file = try Self.openFile(Self.historyName, in: parent, flags: flags)
        defer { close(file) }
        // Garder le même fichier pour la lecture, le dédoublonnage et l'écriture.
        while flock(file, LOCK_EX) != 0 {
            if errno != EINTR { throw Self.posixError() }
        }
        try action(file, parent)
    }

    private func write(_ outcome: CleanupOutcome, to file: Int32) throws {
        // Le séparateur de tête isole une ligne tronquée par un arrêt brutal.
        var data = Data([0x0A])
        data.append(try encoder.encode(outcome))
        data.append(0x0A)
        try validateDestination(file)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(file, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw written == 0 ? POSIXError(.EIO) : Self.posixError() }
                offset += written
            }
        }
    }

    private func validateDestination(_ file: Int32) throws {
        let parent = try openDirectory(create: false)
        defer { close(parent) }
        var named = stat()
        var opened = stat()
        guard fstat(file, &opened) == 0, opened.st_nlink == 1,
              fstatat(parent, Self.historyName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else { throw POSIXError(.EPERM) }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        let path = PathNormalizer.normalize(directory.path)
        guard directory.isFileURL, path.hasPrefix("/"), path != "/",
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !PathGuard().protectsUserLogs(directory) else { throw POSIXError(.EPERM) }
        // Seuls les alias système connus sont développés. Les autres liens
        // sont refusés par openat, à chaque composant du chemin.
        let physical = ["/var", "/tmp", "/etc"].contains(where: {
            path == $0 || path.hasPrefix($0 + "/")
        }) ? "/private" + path : path
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var parent = open("/", flags)
        guard parent >= 0 else { throw Self.posixError() }
        do {
            for component in physical.split(separator: "/").map(String.init) {
                var child = openat(parent, component, flags)
                if child < 0, errno == ENOENT, create {
                    guard mkdirat(parent, component, 0o700) == 0 || errno == EEXIST else { throw Self.posixError() }
                    child = openat(parent, component, flags)
                }
                guard child >= 0 else { throw Self.posixError() }
                close(parent)
                parent = child
            }
            var info = stat()
            guard fstat(parent, &info) == 0, info.st_uid == getuid() else { throw POSIXError(.EPERM) }
            return parent
        } catch {
            close(parent)
            throw error
        }
    }

    private static func openFile(_ name: String, in parent: Int32, flags: Int32) throws -> Int32 {
        let file = openat(parent, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            close(file)
            throw POSIXError(.EPERM)
        }
        return file
    }

    private func read(_ name: String) -> [Data] {
        guard let parent = try? openDirectory(create: false) else { return [] }
        defer { close(parent) }
        guard let file = try? Self.openFile(name, in: parent, flags: O_RDONLY) else { return [] }
        defer { close(file) }
        return (try? lines(in: file)) ?? []
    }

    private func lines(in file: Int32) throws -> [Data] {
        let data = try FileHandle(fileDescriptor: file, closeOnDealloc: false).readToEnd() ?? Data()
        return data.split(separator: 0x0A).map { Data($0) }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
