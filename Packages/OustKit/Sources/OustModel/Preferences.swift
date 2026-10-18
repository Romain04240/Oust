import Foundation
import OustRules

/// Les réglages de l'utilisateur, gardés dans ses préférences.
public struct Preferences: Sendable, Equatable {
    public var projectRoots: [URL]
    public var historyRetentionDays: Int
    public var recencyDays: Int
    public var duplicateMinimumMegabytes: Int
    /// Un projet est proposé à l'archivage après tant de mois sans modification.
    public var archiveInactiveMonths: Int
    /// Un projet intact depuis tant de mois est proposé à la compression.
    public var compressionAgeMonths: Int
    /// Doublons : cocher d'office, dans chaque groupe, tout sauf l'exemplaire à
    /// garder. Désactivé par défaut (RULES.md, règle 4) : c'est l'utilisateur
    /// qui le choisit.
    public var duplicateAutoSelect: Bool

    public init(projectRoots: [URL], historyRetentionDays: Int = 30, recencyDays: Int = 7,
                duplicateMinimumMegabytes: Int = 1, archiveInactiveMonths: Int = 6, compressionAgeMonths: Int = 6,
                duplicateAutoSelect: Bool = false) {
        self.projectRoots = projectRoots
        self.historyRetentionDays = historyRetentionDays
        self.recencyDays = recencyDays
        self.duplicateMinimumMegabytes = duplicateMinimumMegabytes
        self.archiveInactiveMonths = archiveInactiveMonths
        self.compressionAgeMonths = compressionAgeMonths
        self.duplicateAutoSelect = duplicateAutoSelect
    }

    static let rootsKey = "projectRoots"
    static let retentionKey = "historyRetentionDays"
    static let recencyKey = "recencyDays"
    static let duplicatesKey = "duplicateMinimumMegabytes"
    static let archiveKey = "archiveInactiveMonths"
    static let compressionKey = "compressionAgeMonths"
    static let duplicateAutoSelectKey = "duplicateAutoSelect"

    public static func load(home: URL, defaults: UserDefaults = .standard) -> Preferences {
        let stored = defaults.stringArray(forKey: rootsKey)?.map { URL(fileURLWithPath: $0) }
        return Preferences(
            projectRoots: stored ?? RuleContext.defaultProjectRoots(home: home),
            historyRetentionDays: defaults.object(forKey: retentionKey) as? Int ?? 30,
            recencyDays: defaults.object(forKey: recencyKey) as? Int ?? 7,
            duplicateMinimumMegabytes: defaults.object(forKey: duplicatesKey) as? Int ?? 1,
            archiveInactiveMonths: defaults.object(forKey: archiveKey) as? Int ?? 6,
            compressionAgeMonths: defaults.object(forKey: compressionKey) as? Int ?? 6,
            duplicateAutoSelect: defaults.bool(forKey: duplicateAutoSelectKey)
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(projectRoots.map(\.path), forKey: Self.rootsKey)
        defaults.set(historyRetentionDays, forKey: Self.retentionKey)
        defaults.set(recencyDays, forKey: Self.recencyKey)
        defaults.set(duplicateMinimumMegabytes, forKey: Self.duplicatesKey)
        defaults.set(archiveInactiveMonths, forKey: Self.archiveKey)
        defaults.set(compressionAgeMonths, forKey: Self.compressionKey)
        defaults.set(duplicateAutoSelect, forKey: Self.duplicateAutoSelectKey)
    }
}
