import Foundation
import OustCore
import OustSafety

/// Retire les copies locales de ce qui est déjà dans le nuage, sans rien
/// supprimer : `FileManager.evictUbiquitousItem`, que macOS relaie au démon
/// d'iCloud Drive ou au File Provider concerné (Google Drive, Dropbox…).
///
/// L'état de chaque fichier est relu juste avant d'agir, et non repris de
/// l'analyse : un fichier modifié depuis, et pas encore renvoyé, perdrait sa
/// dernière version (RULES.md, règle 2).
enum Evictor {

    struct Summary: Sendable, Equatable {
        var evictedBytes: Int64 = 0
        var evicted = 0
        var failures: [String] = []
    }

    /// Évince ce qui peut l'être sous chaque chemin. `evict` est remplacé en
    /// test, faute de vrai nuage dans un dossier temporaire.
    static func evict(
        _ paths: [URL],
        isCancelled: @escaping () -> Bool = { false },
        walk: (URL, (URL, Int64, Date?) -> Bool) -> Void = CloudFile.walk,
        evict: @escaping (URL) throws -> Void = { try FileManager.default.evictUbiquitousItem(at: $0) }
    ) -> Summary {
        var summary = Summary()
        for path in paths {
            if isCancelled() { break }
            guard !CloudFile.isSafariDownload(path) else { continue }
            walk(path) { url, bytes, _ in
                if isCancelled() { return false }
                guard !CloudFile.isSafariDownload(url) else { return true }
                do {
                    try evict(url)
                    summary.evicted += 1
                    summary.evictedBytes += bytes
                } catch {
                    summary.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                return true
            }
        }
        return summary
    }
}
