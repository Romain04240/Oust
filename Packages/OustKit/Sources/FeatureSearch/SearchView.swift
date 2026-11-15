import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// La recherche globale : tout ce que les analyses ont trouvé, quelle que soit la
/// section, par nom, chemin ou propriétaire.
///
/// Les éléments protégés restent dans les résultats, avec leur raison : chercher
/// « Xcode » et ne pas voir l'Xcode actif ferait croire qu'il n'a pas été vu.
public struct SearchView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let results = model.searchResults
        SectionScaffold(.overview, title: "search.title", symbol: "magnifyingglass", subtitle: "search.subtitle") {
            Text(verbatim: L10n.string("search.count", Formatters.count(results.count)))
                .font(Typography.headline)
                .foregroundStyle(Palette.onGradient)
        } content: {
            if results.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "search.empty_title", message: "search.empty_detail")
            }
            ForEach(Self.sections(of: results), id: \.self) { section in
                ResultGroup(model: model, section: section, items: results.filter { $0.category.section == section })
            }
        }
    }

    /// Les sections des résultats, dans l'ordre de la barre latérale.
    static func sections(of results: [CleanupItem]) -> [AppSection] {
        let present = Set(results.map(\.category.section))
        return AppSection.allCases.filter(present.contains)
    }
}

/// Les résultats d'une section, vingt d'abord, comme les listes des sections.
private struct ResultGroup: View {
    let model: AppModel
    let section: AppSection
    let items: [CleanupItem]
    @State private var showAll = false

    var body: some View {
        ItemGroup(title: L10n.string(section.localizationKey), symbol: section.symbol,
                  tint: Palette.colors(for: section).glow,
                  total: items.filter(model.canSelectForCleanup).reduce(0) { $0 + $1.sizes.freeable }) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(showAll ? items : Array(items.prefix(20))) { item in
                    ItemRow(item, enabled: model.canSelectForCleanup(item), isSelected: model.isInCart(item.id), showOwner: true) { model.toggle(item) }
                    Divider().opacity(0.25)
                }
                if items.count > 20 {
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
