import CryptoKit
import Foundation

/// Ce qu'on retient d'une analyse pour la comparer à la suivante : la taille
/// de chaque dossier qui compte.
///
/// Le 18/10/2026, un projet est passé de 33 à 125 Go en quelques heures, sous
/// l'effet d'un agent qui générait des données cartographiques. Personne ne
/// l'aurait vu sans comparer deux mesures. TreeSize appelle ça l'historique ;
/// ici, c'est la colonne et l'onglet « Évolution ».
public struct TreeSummary: Codable, Sendable {
    public let rootPath: String
    public let date: Date
    /// Chemin → octets alloués, pour les dossiers d'au moins `minimumBytes`.
    public let sizes: [String: Int64]

    public static let minimumBytes: Int64 = 50_000_000

    /// Résume une arborescence : les dossiers de 50 Mo et plus, au plus 30 000.
    public static func make(from root: TreeNode, date: Date = Date(), limit: Int = 30_000) -> TreeSummary {
        var sizes: [String: Int64] = [:]
        var stack: [TreeNode] = [root]
        while let node = stack.popLast(), sizes.count < limit {
            guard node.total.allocated >= minimumBytes else { continue }
            sizes[node.path] = node.total.allocated
            stack.append(contentsOf: node.children)
        }
        return TreeSummary(rootPath: root.path, date: date, sizes: sizes)
    }

    /// L'écart d'un dossier depuis ce résumé, ou `nil` s'il n'y figurait pas.
    public func delta(for node: TreeNode) -> Int64? {
        sizes[node.path].map { node.total.allocated - $0 }
    }

    /// Ce qui a le plus changé, sans répéter toute une lignée de parents : un
    /// dossier n'est montré que si son écart ne s'explique pas presque
    /// entièrement par celui d'un de ses enfants.
    public func changes(comparedTo current: TreeSummary, limit: Int = 40) -> [Change] {
        var deltas: [String: Int64] = [:]
        for (path, size) in current.sizes {
            deltas[path] = size - (sizes[path] ?? 0)
        }
        for (path, size) in sizes where current.sizes[path] == nil {
            deltas[path] = -size
        }
        var strongestChild: [String: Int64] = [:]
        for (path, delta) in deltas {
            let parent = (path as NSString).deletingLastPathComponent
            if abs(delta) > abs(strongestChild[parent] ?? 0) { strongestChild[parent] = delta }
        }
        return deltas
            .filter { path, delta in
                guard abs(delta) >= 10_000_000 else { return false }
                guard let child = strongestChild[path] else { return true }
                return Double(abs(child)) < Double(abs(delta)) * 0.9
            }
            .map { Change(path: $0.key, delta: $0.value, before: sizes[$0.key], after: current.sizes[$0.key]) }
            .sorted { abs($0.delta) > abs($1.delta) }
            .prefix(limit)
            .map { $0 }
    }

    public struct Change: Sendable, Identifiable, Hashable {
        public var id: String { path }
        public let path: String
        public let delta: Int64
        public let before: Int64?
        public let after: Int64?
    }
}

/// Où l'on range les résumés : un fichier par dossier analysé.
public struct TreeSummaryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Oust/analyses`.
    public static func standard() -> TreeSummaryStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TreeSummaryStore(directory: support.appendingPathComponent("Oust/analyses", isDirectory: true))
    }

    private func url(for rootPath: String) -> URL {
        let digest = SHA256.hash(data: Data(rootPath.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    public func load(rootPath: String) -> TreeSummary? {
        guard let data = try? Data(contentsOf: url(for: rootPath)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TreeSummary.self, from: data)
    }

    public func save(_ summary: TreeSummary) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(summary).write(to: url(for: summary.rootPath), options: .atomic)
    }
}
