import Darwin
import Foundation
import OustCore

/// Un gros fichier signalé par Spotlight, mesuré par `lstat`.
public struct SpotlightFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let sizes: Sizes
    public let logicalSize: Int64
    public let modified: Date?
    public let fileID: UInt64

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
}

/// Les gros fichiers tout de suite, pendant que le parcours tourne.
///
/// Spotlight répond en une fraction de seconde (0,2 s pour 400 fichiers de
/// plus de 100 Mo sur un disque de 1 To, le 18/10/2026) là où le parcours
/// complet en prend vingt. Il ne voit pas tout (dossiers exclus, `~/Library`,
/// fichiers cachés) : c'est un aperçu, que l'arborescence remplace dès qu'elle
/// est prête.
public enum Spotlight {

    /// Les fichiers d'au moins `minimumBytes` alloués sous `root`, du plus gros
    /// au plus petit.
    public static func largeFiles(minimumBytes: Int64, under root: URL,
                                  timeout: TimeInterval = 20) async -> [SpotlightFile] {
        // La requête est passée en argument, jamais interprétée par un shell ; le
        // seuil est un entier, rien d'autre n'y entre.
        let query = "kMDItemFSSize >= \(max(0, minimumBytes))"
        let result = await Command.run("/usr/bin/mdfind", ["-0", "-onlyin", root.path, query], timeout: timeout)
        guard result.succeeded else { return [] }
        return parse(result.stdout, minimumBytes: minimumBytes)
    }

    static func parse(_ output: Data, minimumBytes: Int64) -> [SpotlightFile] {
        var files: [SpotlightFile] = []
        var seen = Set<UInt64>()
        for chunk in output.split(separator: 0) where !chunk.isEmpty {
            let path = String(decoding: chunk, as: UTF8.self)
            var info = stat()
            // Un fichier ordinaire seulement : Spotlight compte aussi les paquets
            // (`.app`), qui sont des dossiers.
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let allocated = Int64(info.st_blocks) * 512
            guard allocated >= minimumBytes, seen.insert(UInt64(info.st_ino)).inserted else { continue }
            let freeable = BulkReader.privateSize(path: path) ?? allocated
            files.append(SpotlightFile(
                path: path, sizes: Sizes(allocated: allocated, freeable: freeable), logicalSize: Int64(info.st_size),
                modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)), fileID: UInt64(info.st_ino)
            ))
        }
        return files.sorted { $0.sizes.allocated > $1.sizes.allocated }
    }
}
