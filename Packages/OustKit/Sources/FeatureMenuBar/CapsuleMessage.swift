import OustCore
import OustLocalization
import OustModel
import OustWatch

/// Ce que dit une pastille (`CapsulePresenter`) : une ligne, un grand chiffre,
/// et un contour qui sert de jauge.
///
/// La pastille est née pour l'alerte disque bas ; l'entretien planifié, puis
/// d'autres veilles, y passent aussi (18/10/2026). Toutes gardent la même
/// forme, celle que Romain a validée : on la reconnaît d'un coup d'œil, et
/// seul ce qu'elle dit change.
///
///     [symbole]  label  FIGURE mot  [✓ note sûre]
public struct CapsuleMessage: Sendable, Equatable {
    /// Le symbole de tête (SF Symbols).
    public var symbol: String
    /// Ce dont parle la pastille : « Espace disque · Macintosh HD », « Entretien ».
    public var label: String
    /// Le grand chiffre (« 210 Go »), ou rien.
    public var figure: String?
    /// Le mot qui le suit (« libres », « à récupérer »), ou qui dit tout seul.
    public var word: String
    /// En vert après la coche de sûreté : « 12 Go à récupérer ».
    public var safeNote: String?
    public var gauge: CapsuleGauge
    /// Ce que VoiceOver annonce à l'arrivée, et lit sur la pastille.
    public var announcement: String
    /// Ce que fait un clic, pour VoiceOver.
    public var hint: String

    public init(symbol: String, label: String, figure: String? = nil, word: String, safeNote: String? = nil,
                gauge: CapsuleGauge, announcement: String, hint: String) {
        self.symbol = symbol
        self.label = label
        self.figure = figure
        self.word = word
        self.safeNote = safeNote
        self.gauge = gauge
        self.announcement = announcement
        self.hint = hint
    }
}

/// Le contour de la pastille en jauge : la part pleine, dans le dégradé de
/// l'anneau (IDENTITE §5), et au bout de celle-ci, en vert, ce qu'on peut rendre.
public struct CapsuleGauge: Sendable, Equatable {
    /// De 0 à 1 : la part occupée.
    public var filled: Double
    /// De 0 à `filled` : la part de l'occupé qui peut partir, dessinée au bout.
    public var giveBack: Double

    public init(filled: Double, giveBack: Double = 0) {
        self.filled = min(1, max(0, filled))
        self.giveBack = min(self.filled, max(0, giveBack))
    }
}

extension CapsuleMessage {

    /// L'alerte disque bas, telle que Romain l'a validée (18/10/2026).
    public static func lowDisk(_ alert: LowDiskAlert) -> CapsuleMessage {
        CapsuleMessage(
            symbol: alert.isBoot ? "internaldrive.fill" : "externaldrive.fill",
            label: L10n.string("watch.capsule.label", alert.volumeName),
            figure: Formatters.compactBytes(alert.capacity.available),
            word: L10n.string("watch.capsule.word"),
            safeNote: alert.safeTotal.flatMap { $0 > 0 ? L10n.string("watch.capsule.safe", Formatters.compactBytes($0)) : nil },
            gauge: CapsuleGauge(filled: alert.capacity.usedFraction),
            announcement: alert.title + ". " + alert.message,
            hint: L10n.string("watch.capsule.hint")
        )
    }

    /// L'entretien : « Entretien · 12 Go à récupérer » (Romain : « à récupérer »,
    /// pas « à rendre »). Le contour garde la jauge
    /// du disque, et ce que l'entretien rendrait s'y voit en vert, au bout de
    /// la part occupée.
    public static func maintenance(_ finding: MaintenanceFinding) -> CapsuleMessage {
        let gauge = finding.gauge
        let total = finding.total
        let announcement = total > 0
            ? L10n.string("maintenance.capsule.announcement", Formatters.bytes(total))
            : L10n.string("maintenance.capsule.announcement_clean")
        return CapsuleMessage(
            symbol: "sparkles",
            label: L10n.string("maintenance.capsule.label"),
            figure: total > 0 ? Formatters.compactBytes(total) : nil,
            word: L10n.string(total > 0 ? "maintenance.capsule.word" : "maintenance.capsule.clean"),
            gauge: CapsuleGauge(filled: gauge.filled, giveBack: gauge.giveBack),
            announcement: announcement,
            hint: L10n.string(total > 0 ? "maintenance.capsule.hint" : "maintenance.capsule.hint_clean")
        )
    }
}
