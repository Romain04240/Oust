import Foundation

/// Une seule façon d'écrire un chemin avant de le comparer.
///
/// Le même dossier a plusieurs noms sur macOS : `/System/Volumes/Data/Users/x`
/// et `/Users/x` (firmlink), `/private/var/folders/…` et `/var/folders/…`
/// (lien symbolique), et Foundation ne rend pas toujours le même. Deux chemins
/// comparés sous deux noms différents, c'est une protection qui ne se déclenche
/// pas.
public enum PathNormalizer {
    public static func normalize(_ path: String) -> String {
        var path = path
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        for alias in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(alias) {
            path = String(path.dropFirst("/private".count))
        }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Vrai si `path` est `base` ou se trouve en dessous.
    public static func isWithin(_ path: String, _ base: String) -> Bool {
        let path = normalize(path)
        let base = normalize(base)
        return path == base || path.hasPrefix(base + "/")
    }
}
