import SwiftUI
import OustCore
import OustLocalization
import OustModel

/// La fenêtre Réglages : quatre onglets, comme dans les apps d'Apple.
///
/// C'était une section de la fenêtre, une seule longue page dans un défilement
/// imbriqué (Romain, 18/10/2026 : « trop long, ça défile », « mal rangé »).
/// Chaque onglet prend la hauteur de son contenu ; seul celui qui dépasse
/// `SettingsMetrics.maxHeight` défile, une seule fois.
public struct SettingsView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab(value: SettingsTab.general) { GeneralSettingsTab(model: model) } label: { label(.general) }
            Tab(value: SettingsTab.analysis) { AnalysisSettingsTab(model: model) } label: { label(.analysis) }
            Tab(value: SettingsTab.watch) { WatchSettingsTab(model: model) } label: { label(.watch) }
            Tab(value: SettingsTab.advanced) { AdvancedSettingsTab(model: model) } label: { label(.advanced) }
        }
        .onAppear { model.recheckFullDiskAccess() }
        .task { await model.watch.refreshPermissions() }
    }

    private func label(_ tab: SettingsTab) -> some View {
        Label { Text(LocalizedStringKey(tab.localizationKey), bundle: .oust) } icon: { Image(systemName: tab.symbol) }
    }
}

enum SettingsMetrics {
    static let width: CGFloat = 620
    /// Au-delà, l'onglet défile : la fenêtre ne doit pas dépasser un écran de portable.
    static let maxHeight: CGFloat = 720
}

/// Le formulaire d'un onglet : groupé, de largeur fixe, à la hauteur de son
/// contenu jusqu'à `SettingsMetrics.maxHeight`.
///
/// Sans `fixedSize`, la fenêtre gardait 450 pt pour tous les onglets, et
/// chacun défilait : exactement ce qu'on voulait quitter (vu à l'écran,
/// 18/10/2026). Le formulaire donne sa hauteur idéale, plafonnée, et la
/// fenêtre la prend.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: SettingsMetrics.width)
            .frame(maxHeight: SettingsMetrics.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }
}
