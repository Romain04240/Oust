import SwiftUI
import OustLocalization

/// Le disque sur lequel porte une section, quand ce n'est pas le disque de
/// démarrage : on le choisit dans la vue d'ensemble, et chaque section qui en
/// dépend le rappelle, pour qu'on ne cherche pas ailleurs ce qui n'y est pas.
public struct VolumeBadge: View {
    let name: String
    let symbol: String

    public init(name: String, symbol: String) {
        self.name = name
        self.symbol = symbol
    }

    public var body: some View {
        Label { Text(verbatim: L10n.string("section.on_volume", name)).lineLimit(1) } icon: { Image(systemName: symbol) }
            .font(Typography.body.weight(.semibold))
            .foregroundStyle(Palette.onGradient)
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.small)
            .glassEffect(.regular.tint(.black.opacity(0.14)), in: Capsule())
            // Le nom entier : tronqué (« Sur « Oust… »), il ne disait plus quel disque.
            .fixedSize()
            .help(Text("section.on_volume_help", bundle: .oust))
    }
}
