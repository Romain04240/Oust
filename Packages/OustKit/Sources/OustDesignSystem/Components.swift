import SwiftUI
import OustCore
import OustLocalization

// MARK: - Grand chiffre

/// « 63,4 Go » en très grand, qui défile quand la valeur change.
public struct HeroSize: View {
    let bytes: Int64
    let caption: LocalizedStringKey?
    let showsZero: Bool

    public init(_ bytes: Int64, caption: LocalizedStringKey? = nil, showsZero: Bool = false) {
        self.bytes = bytes
        self.caption = caption
        self.showsZero = showsZero
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(verbatim: showsZero && bytes == 0 ? Formatters.bytes(bytes) : Formatters.compactBytes(bytes))
                .font(Typography.hero)
                .foregroundStyle(Palette.onGradient)
                .contentTransition(.numericText(value: Double(bytes)))
                .animation(.snappy, value: bytes)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            if let caption {
                Text(caption, bundle: .oust)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.onGradientSecondary)
            }
        }
    }
}

// MARK: - Pulsation

/// L'orbe qui bat pendant l'analyse et le nettoyage (SPEC §9.3).
///
/// Ce n'est pas une barre de progression, à dessein : on ne sait pas combien
/// de fichiers reste à parcourir, et une barre qui ment sur sa fin est pire
/// qu'une absence de barre. L'orbe respire en continu et donne une impulsion à
/// chaque élément traité (`beat` change).
public struct PulseOrb: View {
    let section: AppSection
    let isActive: Bool
    let beat: Int
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kick = false

    public init(section: AppSection, isActive: Bool, beat: Int = 0, size: CGFloat = 180) {
        self.section = section
        self.isActive = isActive
        self.beat = beat
        self.size = size
    }

    public var body: some View {
        let glow = Palette.colors(for: section).glow
        TimelineView(.animation(paused: !isActive || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = isActive && !reduceMotion ? (sin(t * 2.4) + 1) / 2 : 0
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let progress = isActive && !reduceMotion
                        ? (t * 0.6 + Double(ring) / 3).truncatingRemainder(dividingBy: 1) : 0
                    Circle()
                        .stroke(Color.white.opacity(0.5 * (1 - progress)), lineWidth: 2)
                        .scaleEffect(0.6 + progress * 0.8)
                }
                Circle()
                    .fill(Palette.eclat)
                    .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .topLeading,
                                                          startRadius: 0, endRadius: size * 0.4)))
                    .frame(width: size * 0.55, height: size * 0.55)
                    .scaleEffect(1 + breath * 0.04 + (kick ? 0.04 : 0))
                    .shadow(color: Palette.eclatSolid.opacity(0.7), radius: 26 + breath * 18)
                    .shadow(color: glow.opacity(0.5), radius: 50)
            }
            .frame(width: size, height: size)
        }
        .onChange(of: beat) {
            guard !reduceMotion else { return }
            // Un battement par élément traité : 1 → 1,04 → 1 en 160 ms (IDENTITE §5).
            withAnimation(.easeOut(duration: 0.08)) { kick = true }
            withAnimation(.easeIn(duration: 0.08).delay(0.08)) { kick = false }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Badges

/// La classe de sécurité, en pastille pleine (IDENTITE §6) : fond « foncé »,
/// mot et symbole blancs, liseré blanc. La seule forme lisible sur tous les fonds
/// de section ; la classe se lit par son mot et son symbole, pas par sa couleur.
public struct SafetyBadge: View {
    let safety: SafetyClass

    public init(_ safety: SafetyClass) {
        self.safety = safety
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Palette.symbol(for: safety)).font(.system(size: 9, weight: .bold))
            Text(LocalizedStringKey(safety.localizationKey), bundle: .oust)
        }
        // Jamais coupée : serrée dans une ligne étroite, « À examiner » finissait
        // sur trois lignes (« À / examine / r »), signalé par Romain le 18/10/2026.
        .lineLimit(1)
        .fixedSize()
        .font(Typography.caption)
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.hair)
        .foregroundStyle(.white)
        .background(Palette.color(for: safety), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// Une petite étiquette neutre (méthode, note).
public struct Tag: View {
    let text: String
    let symbol: String?
    let tint: Color
    let truncation: Text.TruncationMode

    /// `truncation` : `.middle` quand la fin compte autant que le début
    /// (« Dans le paquet « … » : le retirer seul l'abîmerait »).
    public init(_ text: String, symbol: String? = nil, tint: Color = .secondary, truncation: Text.TruncationMode = .tail) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.truncation = truncation
    }

    public var body: some View {
        HStack(spacing: Spacing.tight) {
            if let symbol { Image(systemName: symbol) }
            Text(verbatim: text)
                // Une ligne, tronquée s'il le faut : « Accès complet au disque
                // requis » finissait sur quatre lignes dans une capsule
                // (Romain, 18/10/2026). Le texte complet reste dans « Pourquoi ? ».
                .lineLimit(1)
                .truncationMode(truncation)
        }
        .font(Typography.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.hair)
        .background(tint.opacity(0.12), in: Capsule())
        .help(text)
    }
}

// MARK: - Barres

/// Une barre proportionnelle, pour l'arborescence et les listes.
public struct SizeBar: View {
    let fraction: Double
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(fraction: Double, tint: Color) {
        self.fraction = fraction
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [tint, tint.mix(with: .white, by: 0.25)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .snappy, value: fraction)
    }
}

/// La barre de stockage d'un volume : utilisé, purgeable, sélectionné, libre.
///
/// « Sélectionné » est découpé dans l'utilisé et suit le panier en direct :
/// on voit ce que le nettoyage va rendre avant de l'avoir lancé.
public struct StorageBar: View {
    let capacity: Capacity
    let selected: Int64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(capacity: Capacity, selected: Int64) {
        self.capacity = capacity
        self.selected = selected
    }

    public var body: some View {
        GeometryReader { proxy in
            let total = Double(max(1, capacity.total))
            let width = proxy.size.width
            let selectedPart = min(Double(selected), Double(capacity.occupied)) / total
            let usedPart = Double(capacity.occupied) / total - selectedPart
            let purgeablePart = min(Double(capacity.purgeable), Double(capacity.available) + Double(capacity.purgeable)) / total
            HStack(spacing: 2) {
                Rectangle().fill(Color.white.opacity(0.92)).frame(width: width * usedPart)
                Rectangle().fill(Palette.eclat).frame(width: width * selectedPart)
                Rectangle().fill(Color.white.opacity(0.45)).frame(width: width * min(purgeablePart, 1 - usedPart - selectedPart))
                Rectangle().fill(Color.white.opacity(0.16))
            }
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .animation(reduceMotion ? nil : .snappy, value: selected)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: capacity)
    }
}

// MARK: - Boutons

/// Le grand bouton d'action.
///
/// `eclat` : l'action de faire le vide, en Éclat avec un texte profond — la seule
/// place de cette couleur dans les commandes. Sinon : blanc, texte au dégradé de
/// la section.
public struct PrimaryButtonStyle: ButtonStyle {
    let section: AppSection
    let eclat: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(section: AppSection, eclat: Bool = false) {
        self.section = section
        self.eclat = eclat
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.headline)
            .foregroundStyle(eclat ? AnyShapeStyle(Palette.onEclat) : AnyShapeStyle(Palette.linearGradient(for: section)))
            .padding(.horizontal, Spacing.xLarge)
            .padding(.vertical, Spacing.medium)
            .background(eclat ? AnyShapeStyle(Palette.eclat) : AnyShapeStyle(Color.white), in: Capsule())
            .shadow(color: (eclat ? Palette.eclatSolid : .black).opacity(0.35), radius: configuration.isPressed ? 4 : 16,
                    y: configuration.isPressed ? 1 : 6)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Un bouton secondaire sur fond coloré.
public struct OnGradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body.weight(.semibold))
            .foregroundStyle(Palette.onGradient)
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.small)
            .glassEffect(.regular.tint(.black.opacity(0.14)).interactive(), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

// MARK: - Titres

/// L'en-tête d'une section : symbole, titre, sous-titre, sur le dégradé.
public struct SectionHeader<Trailing: View>: View {
    let section: AppSection
    let title: LocalizedStringKey?
    let symbol: String?
    let subtitle: LocalizedStringKey?
    let trailing: Trailing

    public init(_ section: AppSection, title: LocalizedStringKey? = nil, symbol: String? = nil,
                subtitle: LocalizedStringKey? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.section = section
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Spacing.medium) {
            Image(systemName: symbol ?? section.symbol)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Palette.onGradient)
                .frame(width: 52, height: 52)
                .glassEffect(.regular.tint(.black.opacity(0.14)), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(title ?? LocalizedStringKey(section.localizationKey), bundle: .oust)
                    .font(Typography.title)
                    .foregroundStyle(Palette.onGradient)
                if let subtitle {
                    Text(subtitle, bundle: .oust)
                        .font(Typography.body)
                        .foregroundStyle(Palette.onGradientSecondary)
                }
            }
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    public init(_ section: AppSection, subtitle: LocalizedStringKey? = nil) {
        self.init(section, subtitle: subtitle) { EmptyView() }
    }
}

/// Un état vide, sur le dégradé.
public struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?

    public init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Palette.onGradient)
            Text(title, bundle: .oust)
                .font(Typography.headline)
                .foregroundStyle(Palette.onGradient)
            if let message {
                Text(message, bundle: .oust)
                    .font(Typography.body)
                    .foregroundStyle(Palette.onGradientSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(Spacing.huge)
        .frame(maxWidth: .infinity)
    }
}
