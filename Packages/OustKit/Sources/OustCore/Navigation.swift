import Foundation

/// Les onglets de la fenêtre Réglages.
///
/// Les réglages ont quitté la barre latérale puis la barre d'outils : une
/// fenêtre à part, à onglets, comme dans les apps d'Apple (Romain, 18/10/2026 :
/// une seule longue page « trop longue, ça défile » et « mal rangée »).
public enum SettingsTab: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Démarrage, barre des menus et son icône, les promesses d'Oust!.
    case general
    /// Où chercher, et avec quelle prudence : dossiers de projets, seuils.
    case analysis
    /// Ce qu'Oust! fait seul : alerte disque bas, règles planifiées.
    case watch
    /// Accès complet au disque, démon privilégié.
    case advanced

    public var id: String { rawValue }
    public var localizationKey: String { "settings.tab.\(rawValue)" }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .analysis: "magnifyingglass"
        case .watch: "bell.badge"
        case .advanced: "gearshape.2"
        }
    }
}

/// Où mène un clic venu d'en dehors de la fenêtre : une notification, la barre
/// des menus. Une section de la fenêtre, ou un onglet des Réglages.
public enum Destination: Sendable, Hashable {
    case section(AppSection)
    case settings(SettingsTab)

    static let sectionKey = "section"
    static let settingsKey = "settingsTab"

    /// Ce qu'une notification emporte pour retrouver son chemin quand on la clique.
    public var userInfo: [String: String] {
        switch self {
        case .section(let section): [Self.sectionKey: section.rawValue]
        case .settings(let tab): [Self.settingsKey: tab.rawValue]
        }
    }

    /// Relit une notification cliquée. Ce qu'on ne reconnaît pas (une section
    /// disparue depuis, une notification d'une autre version) mène à la vue
    /// d'ensemble plutôt que nulle part.
    public init(userInfo: [AnyHashable: Any]) {
        if let raw = userInfo[Self.settingsKey] as? String, let tab = SettingsTab(rawValue: raw) {
            self = .settings(tab)
        } else if let raw = userInfo[Self.sectionKey] as? String, let section = AppSection(rawValue: raw) {
            self = .section(section)
        } else {
            self = .section(.overview)
        }
    }
}
