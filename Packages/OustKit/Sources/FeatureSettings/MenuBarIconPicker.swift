import SwiftUI
import OustDesignSystem
import OustLocalization

/// « Monochrome » ou « Couleur » : deux vignettes qui montrent l'icône telle
/// que la barre des menus l'affichera, entre le Wi-Fi et la batterie.
///
/// Un interrupteur « Icône en couleur » demandait d'imaginer le résultat ; ici
/// on le voit avant de choisir (Romain, 18/10/2026).
struct MenuBarIconPicker: View {
    @Binding var colored: Bool

    var body: some View {
        HStack(spacing: Spacing.small) {
            option(colored: false, title: "settings.general.icon_monochrome")
            option(colored: true, title: "settings.general.icon_color")
        }
    }

    private func option(colored value: Bool, title: LocalizedStringKey) -> some View {
        let selected = colored == value
        return Button { colored = value } label: {
            VStack(spacing: Spacing.tight + 2) {
                MenuBarPreview(colored: value)
                Text(title, bundle: .oust)
                    .font(Typography.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(Spacing.small)
            .background(.quaternary.opacity(selected ? 0.7 : 0.3),
                        in: RoundedRectangle(cornerRadius: Radius.small + 2, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.small + 2, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: selected ? 2 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.small + 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title, bundle: .oust))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Un bout de barre des menus : l'icône d'Oust! entre deux voisines de macOS.
private struct MenuBarPreview: View {
    let colored: Bool

    var body: some View {
        HStack(spacing: Spacing.small + 2) {
            Image(systemName: "wifi")
            Image(nsImage: MenuBarIcon.image(colored: colored))
                .renderingMode(colored ? .original : .template)
            Image(systemName: "battery.75percent")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary)
        .frame(width: 92, height: 22)
        .background(.bar, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}
