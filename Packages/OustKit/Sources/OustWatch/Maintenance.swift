import Foundation
import OustCore

/// L'entretien planifié, l'équivalent honnête d'un « Smart Care » (Romain,
/// 18/10/2026) : « des entretiens qui peuvent se faire une fois qu'on les
/// programme, par exemple une fois par semaine… après ça te montre ce qui peut
/// être gagné et comment le faire. »
///
/// À la différence des règles planifiées, l'entretien ne supprime rien : il
/// analyse en arrière-plan, compte ce que la présélection cocherait, et le
/// montre. Le vide passe ensuite par la corbeille d'Oust!, sa revue et sa
/// confirmation, comme n'importe quel autre.
public struct MaintenanceSettings: Sendable, Hashable, Codable {
    /// Désactivé tant que l'utilisateur ne l'a pas coché.
    public var isEnabled: Bool
    public var frequency: RetentionFrequency
    /// Le résultat en pastille, sous la barre des menus.
    public var showsCapsule: Bool
    /// Et, si on le veut, en notification de macOS.
    public var notifies: Bool
    /// Le moment où on l'a coché : le premier entretien vient une période plus
    /// tard, comme une règle planifiée. « Faire l'entretien maintenant » est là
    /// pour qui ne veut pas attendre.
    public var enabledSince: Date?

    public init(isEnabled: Bool = false, frequency: RetentionFrequency = .weekly, showsCapsule: Bool = true,
                notifies: Bool = false, enabledSince: Date? = nil) {
        self.isEnabled = isEnabled
        self.frequency = frequency
        self.showsCapsule = showsCapsule
        self.notifies = notifies
        self.enabledSince = enabledSince
    }

    /// Un réglage absent (fichier d'une version plus ancienne) prend sa valeur
    /// par défaut, sans faire perdre les autres.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MaintenanceSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        frequency = try container.decodeIfPresent(RetentionFrequency.self, forKey: .frequency) ?? defaults.frequency
        showsCapsule = try container.decodeIfPresent(Bool.self, forKey: .showsCapsule) ?? defaults.showsCapsule
        notifies = try container.decodeIfPresent(Bool.self, forKey: .notifies) ?? defaults.notifies
        enabledSince = try container.decodeIfPresent(Date.self, forKey: .enabledSince)
    }

    /// Le prochain entretien, ou `nil` s'il est désactivé.
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

    /// Lu tolérant : un fichier abîmé rend les réglages par défaut, entretien désactivé.
    public static func decode(_ data: Data?) -> MaintenanceSettings {
        guard let data, let settings = try? JSONDecoder().decode(MaintenanceSettings.self, from: data) else {
            return MaintenanceSettings()
        }
        return settings
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// Ce que l'entretien retient d'un lancement à l'autre : le dernier passage et
/// ce qu'il a trouvé, pour les Réglages.
public struct MaintenanceState: Sendable, Hashable, Codable {
    public var lastRun: Date?
    public var lastTotal: Int64?
    public var lastCount: Int?

    public init(lastRun: Date? = nil, lastTotal: Int64? = nil, lastCount: Int? = nil) {
        self.lastRun = lastRun
        self.lastTotal = lastTotal
        self.lastCount = lastCount
    }

    public static func decode(_ data: Data?) -> MaintenanceState {
        guard let data, let state = try? JSONDecoder().decode(MaintenanceState.self, from: data) else {
            return MaintenanceState()
        }
        return state
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// Ce que l'entretien annonce, parmi ce que l'analyse vient de trouver.
///
/// On n'annonce que ce qui sera vraiment libéré (RULES.md, règle 9) : ce que
/// la présélection cocherait d'office (sûr, ou qui se reconstruit et n'a pas
/// servi depuis la garde de récence ; jamais l'« À examiner »), qui rend son
/// espace sans attendre la corbeille du Mac, et dont la taille est mesurée,
/// pas estimée.
public enum MaintenanceSelection {

    /// En dessous, l'entretien se tait : ni pastille, ni notification pour
    /// quelques mégaoctets. Les Réglages disent quand même ce qu'il a trouvé.
    public static let worthTelling: Int64 = 100_000_000

    public static func announced(_ items: [CleanupItem], recencyDays: Int, now: Date = Date()) -> [CleanupItem] {
        var seen = Set<String>()
        return items.filter { admits($0, recencyDays: recencyDays, now: now) && seen.insert($0.id).inserted }
            .sorted { $0.sizes.freeable > $1.sizes.freeable }
    }

    public static func admits(_ item: CleanupItem, recencyDays: Int, now: Date = Date()) -> Bool {
        // La présélection d'abord : elle seule dit ce qui se coche sans regarder.
        guard PreselectionPolicy(recencyDays: recencyDays).preselects(item, now: now) else { return false }
        guard item.safety == .safe || item.safety == .rebuilds else { return false }
        // Une VM, une image Docker : pas du « vide à faire ».
        guard item.countsInHeadline else { return false }
        // Rendu tout de suite : rien qui attende la corbeille du Mac, Photos ou
        // un geste à la main ; pas de snapshot, qui demande le mot de passe.
        guard item.method.freesImmediately else { return false }
        if case .localSnapshot = item.method { return false }
        // Un gain estimé n'est pas un chiffre qu'on annonce.
        guard !item.notes.contains(.estimated) else { return false }
        return item.sizes.freeable > 0
    }
}

/// Ce qu'un entretien a trouvé.
public struct MaintenanceFinding: Sendable, Equatable {
    public var date: Date
    /// Du plus libérable au moins.
    public var items: [CleanupItem]
    /// Le disque de démarrage au moment de l'entretien, pour le contour de la pastille.
    public var capacity: Capacity?
    /// Faux si une partie du gain n'a pas pu être vérifiée à l'affichage.
    public var measurementIsComplete = true

    public init(date: Date = Date(), items: [CleanupItem], capacity: Capacity? = nil) {
        self.date = date
        self.items = items
        self.capacity = capacity
    }

    public var total: Int64 { items.reduce(0) { $0 + $1.sizes.freeable } }
    public var isWorthTelling: Bool { total >= MaintenanceSelection.worthTelling }

    /// Les règles les plus généreuses, une fois chacune : de quoi dire en une
    /// ligne d'où vient le chiffre (« Xcode, npm, Safari »).
    public func leadingOwners(_ count: Int = 3) -> [String] {
        var owners: [String] = []
        for item in items where !owners.contains(item.owner) {
            owners.append(item.owner)
            if owners.count == count { break }
        }
        return owners
    }

    /// Le contour de la pastille : la part occupée du disque, et la part de
    /// cette part que l'entretien rendrait, au bout, en vert. Un rendu trop fin
    /// pour se voir garde un trait visible : on montre qu'il existe, pas sa
    /// taille exacte, que le grand chiffre dit.
    public var gauge: (filled: Double, giveBack: Double) {
        guard let capacity, capacity.total > 0 else { return (0, 0) }
        let filled = min(1, max(0, capacity.usedFraction))
        guard total > 0 else { return (filled, 0) }
        let exact = Double(total) / Double(capacity.total)
        return (filled, min(filled, max(Self.minimumVisible, exact)))
    }

    static let minimumVisible = 0.015
}
