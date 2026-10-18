import Foundation
import OustCore

/// L'historique local des nettoyages (SPEC §6.3).
///
/// Une ligne JSON par élément traité, ajoutée à la fin d'un fichier : rien ne se
/// réécrit, rien ne se perd si l'application s'arrête au milieu d'un nettoyage.
/// Ce qui a été restauré est noté à part, pour ne jamais modifier une ligne.
public actor HistoryStore {
    public nonisolated let directory: URL
    private var historyURL: URL { directory.appendingPathComponent(Self.historyName) }
    private var restoredURL: URL { directory.appendingPathComponent(Self.restoredName) }
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
        try append(outcome, to: historyURL)
    }

    /// Tout l'historique, le plus récent d'abord.
    public func load() -> [CleanupOutcome] {
        lines(of: historyURL).compactMap { try? decoder.decode(CleanupOutcome.self, from: $0) }.reversed()
    }

    public func restoredIDs() -> Set<String> {
        Set(lines(of: restoredURL).compactMap { try? decoder.decode(RestoredMark.self, from: $0).id })
    }

    /// Remet à sa place ce qui est parti à la corbeille.
    ///
    /// Refuse si l'emplacement d'origine est de nouveau occupé (on n'écrase
    /// jamais), ou si l'élément n'est plus dans la corbeille (elle a été vidée).
    public func restore(_ outcome: CleanupOutcome) throws {
        guard outcome.result == .trashed, outcome.trashedTo.count == outcome.paths.count else {
            throw RestoreError.notRestorable
        }
        let fileManager = FileManager.default
        for (original, trashed) in zip(outcome.paths, outcome.trashedTo) {
            guard fileManager.fileExists(atPath: trashed) else { throw RestoreError.goneFromTrash }
            guard !fileManager.fileExists(atPath: original) else { throw RestoreError.originalOccupied }
        }
        for (original, trashed) in zip(outcome.paths, outcome.trashedTo) {
            let destination = URL(fileURLWithPath: original)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: URL(fileURLWithPath: trashed), to: destination)
        }
        try append(RestoredMark(id: outcome.id, date: Date()), to: restoredURL)
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = try Self.openForAppending(historyURL)
        close(descriptor)
    }

    private func append(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try encoder.encode(value)
        data.append(0x0A)
        // `O_APPEND` : la CLI des agents écrit dans ce journal depuis un autre
        // processus que l'app. Chaque ligne va au bout du fichier au moment même
        // où elle est écrite ; « aller au bout, puis écrire » laissait deux
        // processus écrire au même endroit, l'un par-dessus l'autre.
        let descriptor = try Self.openForAppending(url)
        defer { close(descriptor) }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }

    private static func openForAppending(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    private func lines(of url: URL) -> [Data] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).map { Data($0) }
    }
}
