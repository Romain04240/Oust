import Foundation
import OustCore
import OustRules

/// Ce qu'une règle planifiée a le droit de prendre : une famille de caches,
/// rien d'autre.
///
/// Les règles admises sont nommées une à une plutôt que déduites d'une
/// catégorie : une règle ajoutée plus tard n'entre dans un passage sans
/// témoin que si quelqu'un l'a décidé ici, test à l'appui.
public enum RetentionFamily: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// npm, pip, Homebrew, Cargo… : retéléchargés au prochain usage.
    case packageCaches
    /// DerivedData, caches de modules et d'aperçus d'Xcode, caches d'outils de
    /// build dans les projets (`.turbo`, `.pytest_cache`, `__pycache__`…).
    case buildCaches

    public var id: String { rawValue }

    /// Les chercheurs à relancer, et seulement eux.
    public var finders: [FinderKind] {
        switch self {
        case .packageCaches: [.packageCaches]
        case .buildCaches: [.xcode, .projectArtifacts]
        }
    }

    public var categories: Set<ItemCategory> {
        switch self {
        case .packageCaches: [.packageCaches]
        case .buildCaches: [.xcode, .projectArtifacts]
        }
    }

    /// Hors liste, et voulu : `cache.maven` (à examiner : un dépôt local peut
    /// porter des artefacts publiés nulle part ailleurs), `xcode.device_support`
    /// et `xcode.logs` (des journaux d'appareils, pas des caches),
    /// `xcode.archive` (les dSYM des versions publiées), et tous les artefacts
    /// qui ne sont pas des caches : `node_modules`, `.venv`, `build`, `dist`,
    /// `target`. Leur date dit quand on les a installés, pas quand le projet a
    /// servi pour la dernière fois.
    public var ruleIDs: Set<String> {
        switch self {
        case .packageCaches:
            ["cache.npm", "cache.yarn", "cache.pnpm", "cache.bun", "cache.pip", "cache.gradle",
             "cache.cocoapods", "cache.cargo", "cache.go", "cache.homebrew", "cache.pub", "cache.browsers_test"]
        case .buildCaches:
            ["xcode.derived_data", "xcode.derived_data_orphan", "xcode.module_cache", "xcode.previews",
             "artifact.build_cache", "artifact.pycache"]
        }
    }

    public var localizationKey: String { "watch.family.\(rawValue)" }
    public var detailKey: String { "watch.family.\(rawValue).detail" }

    public var symbol: String {
        switch self {
        case .packageCaches: ItemCategory.packageCaches.symbol
        case .buildCaches: ItemCategory.xcode.symbol
        }
    }
}

/// Tous les combien une règle passe.
public enum RetentionFrequency: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .daily: 1
        case .weekly: 7
        case .monthly: 30
        }
    }

    public var localizationKey: String { "watch.frequency.\(rawValue)" }
}

/// Une règle planifiée : une famille, une fréquence, un âge minimal.
/// Désactivée tant que l'utilisateur ne l'a pas cochée.
public struct RetentionPolicy: Sendable, Hashable, Codable, Identifiable {
    public var family: RetentionFamily
    public var isEnabled: Bool
    public var frequency: RetentionFrequency
    /// Un élément n'est pris que s'il n'a pas changé depuis tant de jours.
    public var minimumAgeDays: Int
    /// Le moment où on l'a cochée : le premier passage vient une période plus
    /// tard, jamais à l'instant où l'on coche.
    public var enabledSince: Date?

    public static let ageChoices = [7, 14, 30, 60, 90]

    public var id: RetentionFamily { family }

    public init(family: RetentionFamily, isEnabled: Bool = false, frequency: RetentionFrequency = .weekly,
                minimumAgeDays: Int = 30, enabledSince: Date? = nil) {
        self.family = family
        self.isEnabled = isEnabled
        self.frequency = frequency
        self.minimumAgeDays = minimumAgeDays
        self.enabledSince = enabledSince
    }

    /// Le prochain passage, ou `nil` si la règle est désactivée.
    public func nextRun(lastRun: Date?) -> Date? {
        guard isEnabled else { return nil }
        let anchors = [lastRun, enabledSince].compactMap(\.self)
        guard let anchor = anchors.max() else { return nil }
        return anchor.addingTimeInterval(Double(frequency.days) * 86_400)
    }

    public func isDue(now: Date, lastRun: Date?) -> Bool {
        guard let next = nextRun(lastRun: lastRun) else { return false }
        return now >= next
    }
}

/// Ce qu'un passage planifié a le droit de supprimer, parmi ce que les
/// chercheurs viennent de trouver.
///
/// Le passage se fait sans que personne regarde : chaque condition ferme une
/// porte, et dans le doute l'élément reste (RULES.md, règle 3). La
/// revalidation de `CleanupEngine` passe encore derrière, juste avant d'agir.
public enum RetentionFilter {

    /// Les notes qui n'appellent pas de regard : un DerivedData orphelin, des
    /// blocs en partie partagés. Toute autre note (récemment modifié, utilisé
    /// par un projet, estimé, géré à part) écarte l'élément.
    static let harmlessNotes: Set<ItemNote> = [.orphan, .partlyShared]

    public static func eligible(_ items: [CleanupItem], policy: RetentionPolicy, recencyDays: Int,
                                now: Date = Date()) -> [CleanupItem] {
        items.filter { admits($0, policy: policy, recencyDays: recencyDays, now: now) }
            .sorted { $0.sizes.freeable > $1.sizes.freeable }
    }

    public static func admits(_ item: CleanupItem, policy: RetentionPolicy, recencyDays: Int,
                              now: Date = Date()) -> Bool {
        let family = policy.family
        // La famille : la règle et sa catégorie, toutes deux nommées.
        guard family.ruleIDs.contains(item.ruleID), family.categories.contains(item.category) else { return false }
        // La classe : sûr ou se reconstruit, rien de protégé, rien à examiner.
        guard item.safety == .safe || item.safety == .rebuilds, item.protections.isEmpty, item.isSelectable
        else { return false }
        // La méthode : supprimé tout de suite, par Oust!. Jamais la corbeille du
        // Mac, jamais un outil, jamais un snapshot.
        guard item.method == .removeNow else { return false }
        guard item.countsInHeadline, item.notes.allSatisfy(harmlessNotes.contains) else { return false }
        guard item.sizes.freeable > 0 else { return false }
        // L'âge : connu, et au-delà du minimum. Ce qui se reconstruit garde en
        // plus la garde de récence de la présélection.
        guard let last = item.lastActivity else { return false }
        let minimumDays = item.safety == .rebuilds ? max(policy.minimumAgeDays, recencyDays) : policy.minimumAgeDays
        guard now.timeIntervalSince(last) >= Double(max(minimumDays, 0)) * 86_400 else { return false }
        // Jamais plus que ce que la présélection cocherait d'office.
        return PreselectionPolicy(recencyDays: recencyDays).preselects(item, now: now)
    }
}
