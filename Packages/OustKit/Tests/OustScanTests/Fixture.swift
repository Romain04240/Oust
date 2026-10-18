import Darwin
import Foundation

/// Un dossier temporaire à soi, retiré à la fin du test.
///
/// Tous les tests d'Oust! travaillent là, et nulle part ailleurs : une
/// application qui supprime des fichiers ne se teste pas sur de vrais dossiers
/// (RULES.md, règle 8).
final class Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Rendre les droits à un dossier verrouillé par un test, sinon il resterait.
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                chmod(url.path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int, byte: UInt8 = 0x41) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: byte, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Ce qu'un fichier occupe vraiment, d'après `stat`.
    static func allocated(_ url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }
}
