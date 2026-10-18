import Darwin
import Foundation
import OustCore

/// Envoie des fichiers à la corbeille et dit où ils ont atterri.
public protocol Trasher: Sendable {
    /// Un résultat par chemin, dans le même ordre : l'emplacement dans la
    /// corbeille, ou le message d'erreur du système.
    func trash(_ urls: [URL]) async -> [Result<URL, TrashError>]
}

public struct TrashError: Error, Sendable, Hashable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Par le Finder, pour que « Remettre » fonctionne.
///
/// `FileManager.trashItem` n'enregistre pas toujours l'emplacement d'origine
/// (constaté par le support technique d'Apple, sans solution). Le Finder, lui,
/// le fait. Les chemins passent en arguments d'`osascript` et jamais dans le
/// texte du script : un nom de fichier ne peut pas devenir du code.
public struct FinderTrasher: Trasher {
    public init() {}

    static let script = """
    on run argv
        set results to {}
        tell application "Finder"
            repeat with itemPath in argv
                try
                    set trashed to delete (POSIX file (contents of itemPath) as alias)
                    set end of results to "OK:" & (POSIX path of (trashed as alias))
                on error message
                    set end of results to "ERR:" & message
                end try
            end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        return results as text
    end run
    """

    public func trash(_ urls: [URL]) async -> [Result<URL, TrashError>] {
        guard !urls.isEmpty else { return [] }
        let result = await Command.run("/usr/bin/osascript", ["-e", Self.script, "--"] + urls.map(\.path), timeout: 600)
        let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
        guard result.succeeded, lines.count == urls.count else {
            // Le Finder a refusé en bloc (autorisation AppleEvents refusée,
            // Finder absent) : on se rabat sur FileManager pour ne pas bloquer.
            return await FileManagerTrasher().trash(urls)
        }
        return lines.map { line in
            line.hasPrefix("OK:")
                ? .success(URL(fileURLWithPath: String(line.dropFirst(3))))
                : .failure(TrashError(String(line.dropFirst(4))))
        }
    }
}

/// Par FileManager : sans « Remettre » garanti, d'où notre propre journal.
public struct FileManagerTrasher: Trasher {
    public init() {}

    public func trash(_ urls: [URL]) async -> [Result<URL, TrashError>] {
        urls.map { url in
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                return .success((resulting as URL?) ?? url)
            } catch {
                return .failure(TrashError(error.localizedDescription))
            }
        }
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
