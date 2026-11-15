import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Système : corbeille, téléchargements, sauvegardes, machines virtuelles.
public struct SystemView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        SectionScaffold(.system, subtitle: "system.subtitle") {
            HStack(spacing: Spacing.small) {
                if let volume = model.analyzedVolume, !volume.isBoot {
                    VolumeBadge(name: volume.name, symbol: volume.symbol)
                }
                FilterMenu(filter: Binding(get: { model.filter(for: .system) }, set: { model.setFilter($0, for: .system) }))
                Button { Task { await model.analyze() } } label: {
                    Text(model.analysis.isRunning ? "overview.analyzing" : "overview.reanalyze", bundle: .oust)
                }
                .buttonStyle(OnGradientButtonStyle())
                .disabled(model.analysis.isRunning)
            }
        } content: {
            HiddenByFilters(count: model.hiddenCount(in: Set(Self.categories), section: .system)) {
                model.setFilter(.none, for: .system)
            }
            ForEach(Self.categories, id: \.self) { category in
                SystemCategory(model: model, category: category)
            }
        }
    }

    static let categories: [ItemCategory] = [
        .downloads, .systemDownloads, .appCaches, .userLogs, .creative, .games, .cloudFiles, .attachments, .screenshots, .trash,
        .iosBackups, .virtualMachines, .diskTraces, .protectedOnDisk,
    ]
}

private struct SystemCategory: View {
    let model: AppModel
    let category: ItemCategory

    var body: some View {
        let items = model.visibleItems(in: [category], section: .system)
        if !items.isEmpty {
            ItemGroup(title: L10n.string(category.localizationKey), symbol: category.symbol,
                      tint: Palette.color(for: category),
                      total: items.filter(model.canSelectForCleanup).reduce(0) { $0 + $1.sizes.freeable }) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    note
                    ForEach(items) { item in
                        ItemRow(item, enabled: model.canSelectForCleanup(item), isSelected: model.isInCart(item.id), showOwner: Self.showsOwner.contains(category)) {
                            model.toggle(item)
                        }
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }

    /// Le titre seul ne dit pas tout : « iMovie Library » est à iMovie, un dossier
    /// de jeu resté là à Steam ou à Epic.
    static let showsOwner: Set<ItemCategory> = [.cloudFiles, .creative, .games]

    /// Ce qu'il faut savoir d'une catégorie avant de cocher quoi que ce soit.
    @ViewBuilder private var note: some View {
        Group {
            switch category {
            case .virtualMachines where model.analyzedVolume?.isBoot == false: Text("system.vm_volume_note", bundle: .oust)
            case .virtualMachines: Text("system.vm_note", bundle: .oust)
            case .trash where model.analyzedVolume?.isBoot == false: Text("system.volume_trash_note", bundle: .oust)
            case .diskTraces: Text("system.traces_note", bundle: .oust)
            case .protectedOnDisk: Text("system.protected_note", bundle: .oust)
            case .cloudFiles: Text("system.cloud_note", bundle: .oust)
            case .attachments: Text("system.attachments_note", bundle: .oust)
            case .userLogs: Text("system.user_logs_note", bundle: .oust)
            default: EmptyView()
            }
        }
        // Blanc pur, jamais `.secondary`, sur les fonds de section (IDENTITE §4).
        .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Spacing.small)
    }
}
