import Foundation

extension Bundle {
    /// Le bundle qui porte le catalogue unique d'Oust!.
    ///
    /// Un seul catalogue pour toute l'application, et non un par module comme
    /// dans Markio : les sections partagent l'essentiel de leur vocabulaire
    /// (classes de sécurité, méthodes, catégories), et une clé dupliquée dans deux
    /// catalogues finit toujours traduite de deux façons.
    public static let oust: Bundle = .module
}

/// Accès au catalogue depuis du code qui n'est pas une vue.
public enum L10n {
    /// La chaîne d'une clé.
    ///
    /// La clé est passée telle quelle à `LocalizationValue` : surtout pas
    /// d'interpolation dans l'initialiseur, qui construirait un *format*
    /// (« rule.%@.what ») introuvable dans le catalogue.
    public static func string(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .oust)
    }

    /// La chaîne d'une clé dont la valeur contient des `%@`.
    public static func string(_ key: String, _ arguments: String...) -> String {
        let format = string(key)
        return String(format: format, locale: .current, arguments: arguments.map { $0 as NSString })
    }
}

/// Un jeu unique de formats. Deux formats différents pour la même grandeur,
/// c'est une interface qui paraît bricolée.
public enum Formatters {

    /// Octets, comme le Finder et les Réglages Système : en base 1000.
    ///
    /// Le style `.memory` (base 1024) afficherait « 931 Go » pour un disque que
    /// macOS présente partout comme « 1 To » ; on ne contredit pas le système sur
    /// sa propre unité.
    public static func bytes(_ value: Int64) -> String {
        max(0, value).formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    /// Octets en colonne étroite : une décimale seulement sous 10 unités.
    public static func compactBytes(_ value: Int64) -> String {
        guard value > 0 else { return "—" }
        let units: [(Double, UnitInformationStorage)] = [
            (1e12, .terabytes), (1e9, .gigabytes), (1e6, .megabytes), (1e3, .kilobytes),
        ]
        for (scale, unit) in units where Double(value) >= scale {
            let scaled = Double(value) / scale
            return Measurement(value: scaled, unit: unit).formatted(
                .measurement(width: .abbreviated, usage: .asProvided,
                             numberFormatStyle: .number.precision(.fractionLength(scaled < 10 ? 1 : 0))))
        }
        return Measurement(value: Double(value), unit: UnitInformationStorage.bytes).formatted(
            .measurement(width: .abbreviated, usage: .asProvided))
    }

    /// « 42 % », sans décimale au-delà de 10 %.
    public static func percent(_ fraction: Double) -> String {
        let value = max(0, fraction)
        return value.formatted(.percent.precision(.fractionLength(value < 0.1 && value > 0 ? 1 : 0)))
    }

    /// « il y a 3 jours ».
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// Date et heure courtes, pour l'historique.
    public static func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    /// « 12 s », « 3 min ».
    public static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    /// Un nombre entier avec séparateurs.
    public static func count(_ value: Int) -> String {
        value.formatted(.number)
    }
}
