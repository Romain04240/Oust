import Foundation
import OustSafety
import OustScan

extension LargeFileFinder {
    /// En attendant l'arborescence : les gros fichiers que Spotlight connaît
    /// déjà, sous le même filtre.
    ///
    /// Spotlight ne dit ni le dernier accès ni les clones : le filtre d'ancienneté
    /// porte alors sur la date de modification, et l'arbre corrige tout dès qu'il
    /// est prêt.
    public static func preview(_ files: [SpotlightFile], filter: LargeFileFilter, limit: Int = 2_000) -> LargeFileResult {
        var matches: [LargeFileMatch] = []
        var bytes: Int64 = 0
        for file in files {
            let url = URL(fileURLWithPath: PathNormalizer.normalize(file.path))
            // Le premier paquet (application, bibliothèque) qui contient le fichier.
            let package = url.pathComponents.dropLast().first { component in
                packageExtensions.contains((component as NSString).pathExtension.lowercased())
            }
            let match = LargeFileMatch(url: url, sizes: file.sizes, modified: file.modified, accessed: nil,
                                       kind: FileKind.of(file.name), fileID: file.fileID, isClone: false,
                                       package: package)
            guard filter.accepts(match) else { continue }
            matches.append(match)
            bytes += match.sizes.freeable
        }
        matches.sort { $0.sizes.allocated > $1.sizes.allocated }
        return LargeFileResult(files: Array(matches.prefix(limit)), matchCount: matches.count, matchBytes: bytes)
    }
}
