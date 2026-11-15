import Darwin
import Foundation

/// Envoie des fichiers à la corbeille et dit où ils ont atterri.
public protocol Trasher: Sendable {
    var isAvailable: Bool { get }
    /// Un résultat par chemin, dans le même ordre : l'emplacement dans la
    /// corbeille, ou le message d'erreur du système.
    func trash(_ urls: [URL]) async -> [Result<URL, TrashError>]
}

public extension Trasher {
    var isAvailable: Bool { true }
}

public struct TrashError: Error, Sendable, Hashable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Le Finder et FileManager résolvent les chemins après le contrôle d'Oust.
/// Ils pourraient alors atteindre un journal utilisateur par un autre chemin.
public struct FinderTrasher: Trasher {
    public init() {}

    public var isAvailable: Bool { false }

    public func trash(_ urls: [URL]) async -> [Result<URL, TrashError>] {
        urls.map { _ in .failure(TrashError("skip.refusedByGuard")) }
    }
}

/// L'ancien repli doit respecter le même veto que le Finder.
public struct FileManagerTrasher: Trasher {
    public init() {}

    public var isAvailable: Bool { false }

    public func trash(_ urls: [URL]) async -> [Result<URL, TrashError>] {
        urls.map { _ in .failure(TrashError("skip.refusedByGuard")) }
    }
}

/// Une corbeille dans un dossier choisi : pour les tests, qui ne touchent jamais
/// à la vraie corbeille de l'utilisateur (RULES.md, règle 8).
public struct FolderTrasher: Trasher {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    public func trash(_ urls: [URL]) async -> [Result<URL, TrashError>] {
        urls.map { url in
            let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: destination)
                return .success(destination)
            } catch {
                return .failure(TrashError(error.localizedDescription))
            }
        }
    }
}

/// La suppression immédiate, réservée au régénérable.
enum Remover {
    /// `removefile(3)` : ce qu'utilise FileManager en dessous, mais qui ne
    /// traverse pas les points de montage tant qu'on ne le lui demande pas
    /// (`REMOVEFILE_CROSS_MOUNT`, jamais passé ici).
    static func remove(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let status = removefile(url.path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
        if status == 0 { return nil }
        let code = errno
        // Un fichier verrouillé (`chflags uchg`) : son propriétaire peut le
        // déverrouiller, on réessaie une fois.
        if code == EPERM {
            unlockTree(url)
            if removefile(url.path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 { return nil }
        }
        return String(cString: strerror(code))
    }

    private static func unlockTree(_ url: URL) {
        chflags(url.path, 0)
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return }
        for case let relative as String in enumerator {
            chflags(url.appendingPathComponent(relative).path, 0)
        }
    }
}
