import SwiftUI
import OustCore

// MARK: - Couleurs

extension Color {
    /// Une couleur écrite comme dans `Design/IDENTITE.md`, pour qu'on puisse
    /// comparer les deux d'un coup d'œil.
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Les couleurs d'Oust!, par rôle — reportées de `Design/IDENTITE.md`, qui fait
/// foi (contrastes vérifiés par `Design/outils/palette.py`).
public enum Palette {

    /// Les quatre teintes d'une section (IDENTITE §3) : le dégradé vif (départ →
    /// arrivée) porte le texte blanc à 4,5:1 sur toute sa longueur ; la lueur sert
    /// au décor et aux jauges, jamais sous du texte ; le profond est le fond en
    /// apparence sombre.
    public struct SectionColors: Sendable {
        public let start: Color
        public let end: Color
        public let glow: Color
        public let deep: Color
    }

    /// Les sections de la phase 2 n'ont pas encore de dégradé à elles dans
    /// IDENTITE.md : chacune prend, en attendant, celui de la section dont elle
    /// prolonge le travail (l'archivage, les projets ; les gros fichiers,
    /// l'Explorateur ; les applications, le Système). Des couleurs déjà vérifiées
    /// plutôt que des couleurs inventées (RULES.md, « Identité »).
    ///
    /// Photos fait de même avec le dégradé chaud des Navigateurs : vérifié, et
    /// distinct de ses voisines dans la barre latérale (Doublons, vert ;
    /// Développement & IA, violet), là où celui des Doublons, qu'elle prolonge,
    /// aurait fait deux sections vertes à la suite. À trancher avec l'identité
    /// visuelle (`palette.py`).
    ///
    /// Le Cloud prend le bleu ciel de l'Explorateur : vérifié, et entre le
    /// dégradé chaud de Photos et le violet du Développement, ses voisins.
    public static func colors(for section: AppSection) -> SectionColors {
        switch section {
        case .overview, .advice, .cart:
            SectionColors(start: Color(hex: 0xE0157F), end: Color(hex: 0x6E3BF5), glow: Color(hex: 0xFF6FB8), deep: Color(hex: 0x1B0E52))
        case .developer, .archive, .transfer:
            SectionColors(start: Color(hex: 0x8E3CF7), end: Color(hex: 0x2F5BF5), glow: Color(hex: 0x9E8CFF), deep: Color(hex: 0x0A1652))
        case .explorer, .largeFiles, .clouds:
            SectionColors(start: Color(hex: 0x0A6BE0), end: Color(hex: 0x007D8F), glow: Color(hex: 0x4FC3FF), deep: Color(hex: 0x002142))
        case .duplicates:
            SectionColors(start: Color(hex: 0x00806C), end: Color(hex: 0x14853A), glow: Color(hex: 0x3EE0A8), deep: Color(hex: 0x002917))
        case .browsers, .photos:
            SectionColors(start: Color(hex: 0xCC4A06), end: Color(hex: 0xD3145E), glow: Color(hex: 0xFF8A4C), deep: Color(hex: 0x420018))
        case .system, .applications, .timeMachine:
            SectionColors(start: Color(hex: 0x5148D6), end: Color(hex: 0x334D73), glow: Color(hex: 0x8FA2FF), deep: Color(hex: 0x121E39))
        case .history:
            SectionColors(start: Color(hex: 0xA35F00), end: Color(hex: 0xB03F0B), glow: Color(hex: 0xFFB547), deep: Color(hex: 0x391100))
        }
    }

    public static func gradient(for section: AppSection) -> (start: Color, end: Color) {
        let colors = colors(for: section)
        return (colors.start, colors.end)
    }

    public static func linearGradient(for section: AppSection) -> LinearGradient {
        let colors = colors(for: section)
        return LinearGradient(colors: [colors.start, colors.end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// L'Éclat : réservé à l'action de faire le vide (bouton principal, panier,
    /// pulsation, espace libéré). Jamais pour une pastille (IDENTITE §6).
    public static let eclat = LinearGradient(
        colors: [Color(hex: 0xFFE45C), Color(hex: 0xFFA51A), Color(hex: 0xFF5A1F)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let eclatSolid = Color(hex: 0xFFA51A)
    public static let onEclat = Color(hex: 0x1B0E52)

    /// La couleur « foncée » d'une classe : fond des pastilles pleines.
    public static func color(for safety: SafetyClass) -> Color {
        switch safety {
        case .safe: Color(hex: 0x006725)
        case .rebuilds: Color(hex: 0x0057B3)
        case .review: Color(hex: 0x963D00)
        case .protected: Color(hex: 0x563ECF)
        case .inaccessible: Color(hex: 0x595961)
        }
    }

    /// La couleur « vive » d'une classe : pictogramme seul sur le verre sombre.
    public static func vivid(for safety: SafetyClass) -> Color {
        switch safety {
        case .safe: Color(hex: 0x3DD68C)
        case .rebuilds: Color(hex: 0x5CB4FF)
        case .review: Color(hex: 0xFFB547)
        case .protected: Color(hex: 0xB3A3FF)
        case .inaccessible: Color(hex: 0xAAAAB3)
        }
    }

    public static func symbol(for safety: SafetyClass) -> String {
        switch safety {
        case .safe: "checkmark.circle.fill"
        case .rebuilds: "arrow.triangle.2.circlepath"
        case .review: "eye.fill"
        case .protected: "lock.fill"
        case .inaccessible: "eye.slash.fill"
        }
    }

    /// La couleur d'une catégorie : la lueur de sa section, nuancée.
    public static func color(for category: ItemCategory) -> Color {
        switch category {
        case .projectArtifacts: Color(hex: 0x9E8CFF)
        case .packageCaches: Color(hex: 0x5CB4FF)
        case .xcode: Color(hex: 0x6F8CFF)
        case .simulators: Color(hex: 0x8FA2FF)
        case .aiAgents: Color(hex: 0xC48CFF)
        case .aiModels: Color(hex: 0xFF6FB8)
        case .toolVersions: Color(hex: 0x7FD8FF)
        case .containers: Color(hex: 0x4F9BFF)
        case .compressibleProjects: Color(hex: 0xB79CFF)
        case .downloads: Color(hex: 0x4FC3FF)
        case .trash: Color(hex: 0xFFB547)
        case .iosBackups: Color(hex: 0x3EE0A8)
        case .appCaches: Color(hex: 0x5CB4FF)
        case .userLogs: Color(hex: 0x5CB4FF)
        case .systemDownloads: Color(hex: 0x6F8CFF)
        case .attachments: Color(hex: 0xFF8A4C)
        case .screenshots: Color(hex: 0xFFD25C)
        case .cloudFiles: Color(hex: 0x7FD8FF)
        case .creative: Color(hex: 0xFF6FB8)
        case .games: Color(hex: 0x3EE0A8)
        case .virtualMachines: Color(hex: 0xAAAAB3)
        case .snapshots: Color(hex: 0x8FA2FF)
        case .browsers: Color(hex: 0xFF8A4C)
        case .duplicates: Color(hex: 0x3EE0A8)
        case .explorer: Color(hex: 0x4FC3FF)
        case .applications: Color(hex: 0x8FA2FF)
        // Celle des applications, un cran plus pâle : ce qu'il en reste.
        case .appLeftovers: Color(hex: 0xAAB8FF)
        case .archives: Color(hex: 0x9E8CFF)
        case .largeFiles: Color(hex: 0x4FC3FF)
        case .photoVideos: Color(hex: 0xFF8A4C)
        case .photoScreenshots: Color(hex: 0xFFD25C)
        case .photoDuplicates: Color(hex: 0x3EE0A8)
        case .photoSimilar: Color(hex: 0xFF6FB8)
        case .photoUtilities: Color(hex: 0x7FD8FF)
        case .diskTraces: Color(hex: 0xFFD25C)
        case .protectedOnDisk: Color(hex: 0xB3A3FF)
        case .cloudItems: Color(hex: 0x7FD8FF)
        // Celle des photos similaires : la même idée, hors de la photothèque.
        case .similarImages: Color(hex: 0xFF6FB8)
        }
    }

    /// Texte posé sur un fond de section : blanc pur, toujours (IDENTITE §4,
    /// règle 3). La hiérarchie passe par la taille et la graisse, pas par
    /// l'opacité, qui repasserait sous 4,5:1 sur les dégradés vifs.
    public static let onGradient = Color.white
    public static let onGradientSecondary = Color.white
}

// MARK: - Espacements et rayons

public enum Spacing {
    public static let hair: CGFloat = 2
    public static let tight: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let xLarge: CGFloat = 24
    public static let xxLarge: CGFloat = 32
    public static let huge: CGFloat = 48
}

public enum Radius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 20
    public static let card: CGFloat = 24
}

// MARK: - Typographie

public enum Typography {
    /// Le grand chiffre d'une section : « 63,4 Go ».
    public static let hero = Font.system(size: 64, weight: .heavy, design: .rounded)
    public static let heroUnit = Font.system(size: 28, weight: .bold, design: .rounded)
    public static let title = Font.system(size: 28, weight: .bold, design: .rounded)
    public static let headline = Font.system(size: 17, weight: .semibold, design: .rounded)
    public static let body = Font.system(size: 13)
    public static let caption = Font.system(size: 11, weight: .medium)
    /// Les tailles en colonne : chiffres tabulaires (RULES.md, règle 15).
    public static let size = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
}
