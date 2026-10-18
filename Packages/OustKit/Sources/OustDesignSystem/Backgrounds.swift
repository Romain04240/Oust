import SwiftUI
import OustCore

/// Le fond d'une section (IDENTITE §4) : jamais blanc.
///
/// Apparence claire : le dégradé vif de la section, avec un halo de sa lueur en
/// haut à gauche. Apparence sombre : son fond profond, avec deux halos (départ en
/// bas à gauche, arrivée en haut à droite). Le passage d'une section à l'autre
/// est un fondu de 250 ms, simple aussi avec « Réduire les animations ».
public struct SectionBackground: View {
    let section: AppSection
    @Environment(\.colorScheme) private var colorScheme

    public init(_ section: AppSection) {
        self.section = section
    }

    public var body: some View {
        let colors = Palette.colors(for: section)
        ZStack {
            if colorScheme == .dark {
                colors.deep
                RadialGradient(colors: [colors.start.opacity(0.45), .clear], center: .bottomLeading,
                               startRadius: 0, endRadius: 700)
                    .blendMode(.screen)
                RadialGradient(colors: [colors.end.opacity(0.45), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 700)
                    .blendMode(.screen)
            } else {
                LinearGradient(colors: [colors.start, colors.end], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [colors.glow.opacity(0.35), .clear], center: .topLeading,
                               startRadius: 0, endRadius: 600)
                    .blendMode(.screen)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: section)
        .accessibilityHidden(true)
    }
}

/// Ce qui est posé sur le fond est rendu en schéma sombre, dans les deux
/// apparences (IDENTITE §4, règle 2). Seul le fond suit le système.
public struct OnSectionBackground: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content.environment(\.colorScheme, .dark)
    }
}

extension View {
    public func onSectionBackground() -> some View { modifier(OnSectionBackground()) }

    /// Le contenu qui défile s'arrête au bas de la barre d'outils, après un court
    /// fondu, au lieu de passer derrière le verre des disques et de s'y lire
    /// (Romain, 18/10/2026). Le fond de la section, lui, monte jusqu'en haut.
    /// L'effet de bord de défilement du système ne s'applique pas à cette fenêtre
    /// sans barre de titre.
    public func stopsUnderToolbar() -> some View {
        clipped()
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                    Rectangle()
                }
            }
    }
}

/// Une carte en verre posée sur le fond coloré.
public struct GlassCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    public init(padding: CGFloat = Spacing.large, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.black.opacity(0.14)), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// Une surface pour les listes longues : le verre sur un fond très
/// coloré fatigue la lecture au-delà de quelques lignes.
public struct ListSurface<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
