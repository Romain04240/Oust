import Foundation

/// Les réglages de la veille : alerte disque bas, règles planifiées.
///
/// Deux réglages n'y sont pas. L'ouverture à la connexion, que macOS tient
/// (`SMAppService`) : la recopier ici, c'est risquer de mentir. Et la barre de
/// menus, gardée seule sous `WatchSettings.menuBarKey` (`WatchModel.showsMenuBar`) :
/// un simple booléen, lisible sans décoder le reste.
public struct WatchSettings: Sendable, Hashable, Codable {
    /// La clé de préférence de la barre de menus, affichée par défaut.
    public static let menuBarKey = "watch.showsMenuBar"
    /// Le monogramme en couleur dans la barre de menus plutôt qu'en blanc
    /// (Romain, 18/10/2026). Désactivé par défaut, comme le veut macOS.
    public static let menuBarColorKey = "watch.menuBarIconInColor"

    public var alertsLowDisk: Bool
    /// L'alerte part en capsule ; en plus, une notification de macOS si on le veut.
    public var alsoNotifies: Bool
    public var threshold: LowDiskThreshold
    public var policies: [RetentionPolicy]

    public init(alertsLowDisk: Bool = true, alsoNotifies: Bool = false, threshold: LowDiskThreshold = .standard,
                policies: [RetentionPolicy] = RetentionFamily.allCases.map { RetentionPolicy(family: $0) }) {
        self.alertsLowDisk = alertsLowDisk
        self.alsoNotifies = alsoNotifies
        self.threshold = threshold
        self.policies = policies
    }

    /// Un réglage absent (fichier d'une version plus ancienne) prend sa valeur
    /// par défaut, sans faire perdre les autres.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WatchSettings()
        alertsLowDisk = try container.decodeIfPresent(Bool.self, forKey: .alertsLowDisk) ?? defaults.alertsLowDisk
        alsoNotifies = try container.decodeIfPresent(Bool.self, forKey: .alsoNotifies) ?? defaults.alsoNotifies
        threshold = try container.decodeIfPresent(LowDiskThreshold.self, forKey: .threshold) ?? defaults.threshold
        policies = try container.decodeIfPresent([RetentionPolicy].self, forKey: .policies) ?? defaults.policies
    }

    /// La règle d'une famille ; désactivée si elle n'a jamais été enregistrée.
    public func policy(_ family: RetentionFamily) -> RetentionPolicy {
        policies.first { $0.family == family } ?? RetentionPolicy(family: family)
    }

    public mutating func update(_ family: RetentionFamily, _ change: (inout RetentionPolicy) -> Void) {
        var policy = policy(family)
        change(&policy)
        policies.removeAll { $0.family == family }
        policies.append(policy)
        let order = RetentionFamily.allCases
        policies.sort { (order.firstIndex(of: $0.family) ?? 0) < (order.firstIndex(of: $1.family) ?? 0) }
    }

    /// Lu tolérant : une version plus récente qui aurait ajouté un champ, ou un
    /// fichier abîmé, rend les réglages par défaut plutôt qu'une erreur. Les
    /// règles planifiées y sont désactivées.
    public static func decode(_ data: Data?) -> WatchSettings {
        guard let data, let settings = try? JSONDecoder().decode(WatchSettings.self, from: data) else { return WatchSettings() }
        return settings
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// Ce que la veille retient entre deux lancements : l'alerte de chaque volume,
/// le dernier passage de chaque règle.
public struct WatchState: Sendable, Hashable, Codable {
    /// Par identifiant de volume (son UUID, à défaut son point de montage).
    public var alarms: [String: LowDiskAlarm]
    /// Par famille (`RetentionFamily.rawValue`).
    public var lastRuns: [String: Date]

    public init(alarms: [String: LowDiskAlarm] = [:], lastRuns: [String: Date] = [:]) {
        self.alarms = alarms
        self.lastRuns = lastRuns
    }

    public func lastRun(_ family: RetentionFamily) -> Date? { lastRuns[family.rawValue] }

    public static func decode(_ data: Data?) -> WatchState {
        guard let data, let state = try? JSONDecoder().decode(WatchState.self, from: data) else { return WatchState() }
        return state
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
