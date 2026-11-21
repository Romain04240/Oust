import Foundation

/// Le seuil sous lequel Oust! prévient que le disque se remplit : une part du
/// disque, ou un nombre de gigaoctets libres.
///
/// Les deux formes, parce qu'aucune ne convient à tous les disques : 10 % d'un
/// disque de 256 Go, c'est 25 Go, déjà juste ; 10 % de 2 To, c'est 200 Go, et
/// celui qui le sait préfère dire « 50 Go ».
public enum LowDiskThreshold: Sendable, Hashable, Codable {
    case percent(Int)
    case gigabytes(Int)

    public static let defaultPercent = 10
    public static let defaultGigabytes = 20
    public static let standard = LowDiskThreshold.percent(defaultPercent)

    public static let percentRange = 1...50
    public static let gigabyteRange = 1...2_000

    /// Le seuil en octets pour un disque de cette taille. Gigaoctets en base
    /// 1000, comme le Finder et `Formatters.bytes`.
    public func bytes(total: Int64) -> Int64 {
        switch self {
        case .percent(let percent):
            let clamped = Int64(min(max(percent, 0), 100))
            return total / 100 * clamped + total % 100 * clamped / 100
        case .gigabytes(let gigabytes):
            return Int64(max(gigabytes, 0)) * 1_000_000_000
        }
    }

    public var isPercent: Bool {
        if case .percent = self { return true }
        return false
    }

    /// La valeur affichée, quelle que soit l'unité.
    public var value: Int {
        switch self {
        case .percent(let percent): percent
        case .gigabytes(let gigabytes): gigabytes
        }
    }
}

/// Prévient une fois par passage sous le seuil, pas toutes les minutes.
///
/// L'état est gardé d'un lancement à l'autre : relancer Oust! sur un disque
/// déjà plein ne redit pas ce qu'on sait déjà.
public struct LowDiskAlarm: Sendable, Hashable, Codable {
    /// L'alerte est partie, et le disque n'est pas encore remonté au-dessus du
    /// seuil et de sa marge.
    public private(set) var hasFired: Bool
    private var rearmLimit: Int64?

    public init(hasFired: Bool = false) {
        self.hasFired = hasFired
        self.rearmLimit = nil
    }

    public enum Decision: Sendable, Equatable {
        case alert
        case quiet
    }

    /// Ce qu'il faut regagner au-dessus du seuil pour réarmer l'alerte : 5 % du
    /// seuil, et au moins 1 Go ou 1 % du disque, le plus petit des deux. Sans
    /// cette marge, un disque qui oscille autour du seuil au gré des caches
    /// préviendrait à chaque téléchargement ; avec 1 Go d'office, une clé de
    /// 200 Mo ne se réarmait jamais (18/10/2026).
    public static func rearmMargin(threshold: Int64, total: Int64) -> Int64 {
        max(threshold / 20, min(1_000_000_000, total / 100))
    }

    /// Lit l'espace libre et dit s'il faut prévenir.
    public mutating func observe(available: Int64, total: Int64, threshold: LowDiskThreshold) -> Decision {
        // Un volume qui ne dit pas sa taille n'apprend rien : on ne crie pas.
        guard total > 0 else { return .quiet }
        let limit = threshold.bytes(total: total)
        if hasFired { rearmLimit = max(rearmLimit ?? 0, limit + Self.rearmMargin(threshold: limit, total: total)) }
        if available < limit {
            guard !hasFired else { return .quiet }
            hasFired = true
            rearmLimit = limit + Self.rearmMargin(threshold: limit, total: total)
            return .alert
        }
        if available >= (rearmLimit ?? (limit + Self.rearmMargin(threshold: limit, total: total))) { hasFired = false; rearmLimit = nil }
        return .quiet
    }

    /// Sous le seuil, que l'alerte soit partie ou non (barre de menus).
    public static func isLow(available: Int64, total: Int64, threshold: LowDiskThreshold) -> Bool {
        total > 0 && available < threshold.bytes(total: total)
    }
}
