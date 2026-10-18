import Foundation

/// Ce qu'on cherche dans une liste d'éléments : un texte, des classes, un âge,
/// des méthodes, une taille.
///
/// Le même filtre sert à la recherche globale (texte seul, sur tout ce qui a été
/// trouvé) et aux filtres de chaque section. Il ne cache jamais une protection :
/// un élément protégé qui correspond reste affiché, avec sa raison.
public struct ItemFilter: Sendable, Hashable, Codable {
    public var query: String
    /// Vide : toutes les classes.
    public var safety: Set<SafetyClass>
    public var age: AgeFilter
    /// Vide : toutes les méthodes.
    public var families: Set<MethodFamily>
    public var size: SizeFilter

    public init(query: String = "", safety: Set<SafetyClass> = [], age: AgeFilter = .any,
                families: Set<MethodFamily> = [], size: SizeFilter = .any) {
        self.query = query
        self.safety = safety
        self.age = age
        self.families = families
        self.size = size
    }

    public static let none = ItemFilter()

    /// Vrai si le filtre retire quelque chose.
    public var isActive: Bool {
        !Self.tokens(of: query).isEmpty || !safety.isEmpty || age != .any || !families.isEmpty || size != .any
    }

    /// Le nombre de critères posés, pour la pastille du bouton « Filtres ».
    public var criteriaCount: Int {
        (safety.isEmpty ? 0 : 1) + (age == .any ? 0 : 1) + (families.isEmpty ? 0 : 1) + (size == .any ? 0 : 1)
    }

    public func matches(_ item: CleanupItem, now: Date = Date()) -> Bool {
        if !safety.isEmpty, !safety.contains(item.safety) { return false }
        if !families.isEmpty, !families.contains(item.method.family) { return false }
        if !size.accepts(item.sizes.freeable) { return false }
        if !age.accepts(item.lastActivity, now: now) { return false }
        return matchesQuery(item)
    }

    /// Chaque mot doit se retrouver dans le nom, le détail, le propriétaire ou
    /// un chemin, sans tenir compte de la casse ni des accents : « telechargements »
    /// trouve « Téléchargements ».
    public func matchesQuery(_ item: CleanupItem) -> Bool {
        let words = Self.tokens(of: query)
        guard !words.isEmpty else { return true }
        let haystack = Self.fold(([item.title, item.detail ?? "", item.owner] + item.paths.prefix(50).map(\.path))
            .joined(separator: "\n"))
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Publics pour chercher aussi ce qui n'est pas encore un élément : les
    /// fichiers du cloud, tant qu'on ne les a pas cochés.
    public static func tokens(of query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            // L'apostrophe typographique des noms de fichiers macOS (« Capture d’écran »)
            // doit répondre à celle du clavier.
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }
}

/// Depuis combien de temps l'élément n'a pas bougé.
public enum AgeFilter: String, Sendable, Hashable, Codable, CaseIterable {
    case any
    case week
    case month
    case quarter
    case year

    public var days: Int? {
        switch self {
        case .any: nil
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        }
    }

    /// Un élément dont on ne connaît pas l'âge ne passe pas un filtre d'âge :
    /// on ne prétend pas qu'il est ancien.
    public func accepts(_ lastActivity: Date?, now: Date) -> Bool {
        guard let days else { return true }
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= Double(days) * 86_400
    }

    public var localizationKey: String { "filter.age.\(rawValue)" }
}

/// Ce que l'élément rendrait au minimum.
public enum SizeFilter: String, Sendable, Hashable, Codable, CaseIterable {
    case any
    case megabytes10
    case megabytes100
    case gigabyte1
    case gigabytes10

    public var minimum: Int64 {
        switch self {
        case .any: 0
        case .megabytes10: 10_000_000
        case .megabytes100: 100_000_000
        case .gigabyte1: 1_000_000_000
        case .gigabytes10: 10_000_000_000
        }
    }

    public func accepts(_ bytes: Int64) -> Bool { bytes >= minimum }

    public var localizationKey: String { "filter.size.\(rawValue)" }
}
