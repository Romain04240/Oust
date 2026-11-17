import Foundation
import OustCore
import OustDuplicates
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
    public internal(set) var duplicateExclusions: DuplicateExclusions
    public private(set) var sidebarPins: [AppSection]

    public init(projectRoots: [URL], historyRetentionDays: Int = 30, recencyDays: Int = 7,
                duplicateMinimumMegabytes: Int = 1, archiveInactiveMonths: Int = 6, compressionAgeMonths: Int = 6,
                duplicateAutoSelect: Bool = false, duplicateExclusions: DuplicateExclusions = .init(),
                sidebarPins: [AppSection] = []) {
        self.projectRoots = projectRoots
        self.historyRetentionDays = historyRetentionDays
        self.recencyDays = recencyDays
        self.duplicateMinimumMegabytes = duplicateMinimumMegabytes
        self.archiveInactiveMonths = archiveInactiveMonths
        self.compressionAgeMonths = compressionAgeMonths
        self.duplicateAutoSelect = duplicateAutoSelect
        self.duplicateExclusions = duplicateExclusions
        var seen = Set<AppSection>()
        self.sidebarPins = sidebarPins.filter { Self.canPin($0) && seen.insert($0).inserted }
    }

    public mutating func toggleSidebarPin(_ section: AppSection) {
        guard Self.canPin(section) else { return }
        if let index = sidebarPins.firstIndex(of: section) {
            sidebarPins.remove(at: index)
        } else {
            sidebarPins.append(section)
        }
    }

    public func orderedSidebarTools(_ tools: [AppSection]) -> [AppSection] {
        sidebarPins.filter(tools.contains) + tools.filter { !sidebarPins.contains($0) }
    }

    private static func canPin(_ section: AppSection) -> Bool {
        section != .overview && section != .cart && section != .history
    }

    static let rootsKey = "projectRoots"
    static let retentionKey = "historyRetentionDays"
    static let recencyKey = "recencyDays"
    static let duplicatesKey = "duplicateMinimumMegabytes"
    static let archiveKey = "archiveInactiveMonths"
    static let compressionKey = "compressionAgeMonths"
    static let duplicateAutoSelectKey = "duplicateAutoSelect"
    static let sidebarPinsKey = "sidebarPins"

    static let duplicateExclusionsKey = "duplicateExclusions.v1"

    public static func load(home: URL, defaults: UserDefaults = .standard) -> Preferences {
        let stored = defaults.stringArray(forKey: rootsKey)?.map { URL(fileURLWithPath: $0) }
        let exclusions: DuplicateExclusions
        if defaults.object(forKey: duplicateExclusionsKey) == nil {
            exclusions = DuplicateExclusions()
        } else if let data = defaults.data(forKey: duplicateExclusionsKey),
                  let folders = try? JSONDecoder().decode([DuplicateExclusion].self, from: data) {
            exclusions = DuplicateExclusions(folders: folders)
        } else {
            exclusions = DuplicateExclusions(isReadable: false)
        }
        return Preferences(
            projectRoots: stored ?? RuleContext.defaultProjectRoots(home: home),
            historyRetentionDays: defaults.object(forKey: retentionKey) as? Int ?? 30,
            recencyDays: defaults.object(forKey: recencyKey) as? Int ?? 7,
            duplicateMinimumMegabytes: defaults.object(forKey: duplicatesKey) as? Int ?? 1,
            archiveInactiveMonths: defaults.object(forKey: archiveKey) as? Int ?? 6,
            compressionAgeMonths: defaults.object(forKey: compressionKey) as? Int ?? 6,
            duplicateAutoSelect: defaults.bool(forKey: duplicateAutoSelectKey),
            duplicateExclusions: exclusions,
            sidebarPins: defaults.stringArray(forKey: sidebarPinsKey)?.compactMap(AppSection.init(rawValue:)) ?? []
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
        defaults.set(sidebarPins.map(\.rawValue), forKey: Self.sidebarPinsKey)
        if duplicateExclusions.isReadable, let data = try? JSONEncoder().encode(duplicateExclusions.folders) {
            defaults.set(data, forKey: Self.duplicateExclusionsKey)
        }
    }
}
