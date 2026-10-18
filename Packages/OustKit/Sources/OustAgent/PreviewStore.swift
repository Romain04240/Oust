import Darwin
import Foundation
import OustCore

/// Ce qu'une analyse a montré à un agent, et ce qu'elle lui permet de nettoyer.
///
/// Un agent ne nettoie que ce qu'on lui a montré : `clean` exige le jeton d'un
/// aperçu récent qui contient chaque identifiant, puis vérifie que rien
/// d'essentiel n'a bougé depuis (classe, méthode, chemins).
struct Preview: Codable, Sendable {
    var token: String
    var createdAt: Date
    var expiresAt: Date
    var finders: [String]
    var paths: [String]
    /// Seulement ce qui a été montré : une liste coupée par `limit` ne
    /// permet pas de nettoyer ce qui n'y figurait pas.
    var items: [ItemReport]
    /// Pour chaque élément montré, ce qui ne doit pas avoir changé (`seal(of:)`).
    var seals: [String: String]

    func item(_ id: String) -> ItemReport? { items.first { $0.id == id } }

    /// Classe, méthode et chemins, sous une forme qui se compare. La taille
    /// n'y est pas : un cache grossit sans cesse, et reste un cache.
    static func seal(of item: CleanupItem) -> String {
        struct Seal: Encodable {
            let safety: SafetyClass
            let method: CleanupMethod
            let paths: [String]
        }
        let data = try? JSONEncoder.agent().encode(Seal(safety: item.safety, method: item.method,
                                                        paths: item.paths.map(\.path)))
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// 128 bits au hasard, en hexadécimal.
    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

/// Les aperçus récents, dans un fichier à côté du journal d'Oust!.
///
/// Plusieurs agents peuvent analyser en même temps : chaque lecture-écriture
/// se fait sous un verrou (`flock`), et le fichier est remplacé d'un bloc. Rien
/// n'est jamais effacé ici (RULES.md, règle 1) : les aperçus trop vieux
/// disparaissent simplement de la réécriture suivante.
struct PreviewStore: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("agent-previews.json") }
    var lockURL: URL { directory.appendingPathComponent("agent-previews.lock") }

    /// Les aperçus gardés : assez pour quelques agents à la fois.
    static let kept = 8
    /// `explain` les consulte encore une journée ; `clean`, jusqu'à `expiresAt`.
    static let retention: TimeInterval = 24 * 3600

    func save(_ preview: Preview, now: Date) throws {
        try locked {
            var all = load().filter { now.timeIntervalSince($0.createdAt) < Self.retention && $0.token != preview.token }
            all.insert(preview, at: 0)
            let data = try JSONEncoder.agent().encode(Array(all.prefix(Self.kept)))
            try data.write(to: fileURL, options: .atomic)
            // Des chemins du dossier personnel : lisibles par leur seul propriétaire.
            chmod(fileURL.path, 0o600)
        }
    }

    func preview(token: String) -> Preview? {
        (try? locked { load().first { $0.token == token } }) ?? nil
    }

    /// Le plus récent des aperçus encore valables qui contient tous ces éléments.
    func latest(containing ids: [String], now: Date) -> Preview? {
        (try? locked {
            load().first { preview in
                preview.expiresAt > now && ids.allSatisfy { preview.item($0) != nil }
            }
        }) ?? nil
    }

    /// L'élément tel que le plus récent des aperçus l'a montré.
    func latestItem(id: String) -> ItemReport? {
        (try? locked { load().lazy.compactMap { $0.item(id) }.first }) ?? nil
    }

    private func load() -> [Preview] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.agent().decode([Preview].self, from: data)) ?? []
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
