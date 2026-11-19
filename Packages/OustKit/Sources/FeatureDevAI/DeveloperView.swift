import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Développement & IA : ce que laissent les outils et les agents.
public struct DeveloperView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    static let categories: [ItemCategory] = [
        .aiAgents, .projectArtifacts, .simulators, .xcode, .toolVersions, .packageCaches, .aiModels,
        .compressibleProjects, .containers,
    ]

    public var body: some View {
        SectionScaffold(.developer, subtitle: "developer.subtitle") {
            HStack(spacing: Spacing.small) {
                if let volume = model.analyzedVolume, !volume.isBoot {
                    VolumeBadge(name: volume.name, symbol: volume.symbol)
                }
                FilterMenu(filter: Binding(get: { model.filter(for: .developer) },
                                           set: { model.setFilter($0, for: .developer) }))
                ContextHelpButton("help.developer_protections")
                    .foregroundStyle(Palette.onGradient)
                AnalyzeHeaderButton(model: model)
            }
        } content: {
            HStack(alignment: .bottom) {
                HeroSize(model.total(of: Set(Self.categories)), caption: "developer.total_caption")
                Spacer()
                PulseOrb(section: .developer, isActive: model.analysis.isRunning, beat: model.finishedFinders.count, size: 120)
            }
            if !model.currentAnalysis.hasRun && !model.currentAnalysis.isRunning {
                EmptyState(symbol: "sparkle.magnifyingglass", title: "developer.empty_title", message: "developer.empty_detail")
            }
            HiddenByFilters(count: model.hiddenCount(in: Set(Self.categories), section: .developer)) {
                model.setFilter(.none, for: .developer)
            }
            ForEach(Self.categories, id: \.self) { category in
                CategoryList(model: model, category: category, section: .developer)
            }
        }
    }
}

struct AnalyzeHeaderButton: View {
    let model: AppModel
    var body: some View {
        Button { Task { await model.analyze() } } label: {
            Text(model.analysis.isRunning ? "overview.analyzing" : "overview.reanalyze", bundle: .oust)
        }
        .buttonStyle(OnGradientButtonStyle())
        .disabled(model.analysis.isRunning)
    }
}

/// Une catégorie : ses éléments du plus gros au plus petit, dix d'abord, passés
/// au filtre de la section.
public struct CategoryList: View {
    let model: AppModel
    let category: ItemCategory
    let section: AppSection?
    @State private var showAll = false

    public init(model: AppModel, category: ItemCategory, section: AppSection? = nil) {
        self.model = model
        self.category = category
        self.section = section
    }

    public var body: some View {
        let items = section.map { model.visibleItems(in: [category], section: $0) } ?? model.items(in: [category])
        if !items.isEmpty {
            ItemGroup(
                title: L10n.string(category.localizationKey),
                symbol: category.symbol,
                tint: Palette.color(for: category),
                // Le total de ce qui est affiché : filtré, la liste et son chiffre vont ensemble.
                total: items.filter(model.canSelectForCleanup).reduce(0) { $0 + $1.sizes.freeable },
                selectAll: {
                    model.add(items.filter { $0.safety <= .rebuilds && model.canSelectForCleanup($0) })
                }
            ) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    note
                    ForEach(showAll ? items : Array(items.prefix(10))) { item in
                        ItemRow(item, enabled: model.canSelectForCleanup(item), isSelected: model.isInCart(item.id), showOwner: true) { model.toggle(item) }
                        Divider().opacity(0.25)
                    }
                    if items.count > 10 {
                        Button { withAnimation(.snappy) { showAll.toggle() } } label: {
                            Text(verbatim: showAll ? L10n.string("group.show_less") : L10n.string("group.show_all", Formatters.count(items.count)))
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, Spacing.small)
                    }
                }
            }
        }
    }

    /// Ce qu'il faut savoir d'une catégorie avant de cocher quoi que ce soit.
    @ViewBuilder private var note: some View {
        Group {
            switch category {
            case .compressibleProjects: Text("developer.compress_note", bundle: .oust)
            case .containers: Text("developer.containers_note", bundle: .oust)
            default: EmptyView()
            }
        }
        // Blanc pur, jamais `.secondary`, sur les fonds de section (IDENTITE §4).
        .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Spacing.small)
    }
}
