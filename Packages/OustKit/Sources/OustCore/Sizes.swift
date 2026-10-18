import Foundation

/// Les deux tailles qui comptent pour un élément.
///
/// `allocated` est ce que l'élément occupe sur le disque — pas sa taille
/// logique, que le Finder affiche et qui ment dans les deux sens : un fichier
/// compressé occupe moins, un dossier de petits fichiers occupe plus.
///
/// `freeable` est ce que sa suppression rendrait *vraiment* : la part privée,
/// une fois retirés les blocs partagés avec un clone APFS ou retenus par un
/// snapshot. C'est le seul chiffre qu'Oust! promet (RULES.md, règle 9).
public struct Sizes: Sendable, Hashable, Codable {
    public var allocated: Int64
    public var freeable: Int64

    public init(allocated: Int64, freeable: Int64) {
        self.allocated = allocated
        self.freeable = min(freeable, allocated)
    }

    /// Un élément dont rien n'est partagé.
    public init(private bytes: Int64) {
        self.init(allocated: bytes, freeable: bytes)
    }

    public static let zero = Sizes(allocated: 0, freeable: 0)

    /// Ce qui reste sur le disque après suppression, partagé ailleurs.
    public var retained: Int64 { max(0, allocated - freeable) }

    public static func + (lhs: Sizes, rhs: Sizes) -> Sizes {
        Sizes(allocated: lhs.allocated + rhs.allocated, freeable: lhs.freeable + rhs.freeable)
    }

    public static func += (lhs: inout Sizes, rhs: Sizes) {
        lhs = lhs + rhs
    }
}

extension Sequence where Element == Sizes {
    public func total() -> Sizes { reduce(.zero, +) }
}
