import SwiftUI
import OustModel

/// Veille : ce qu'Oust! fait seul, fenêtre fermée. Les sections viennent de
/// `WatchSettingsSections`, où chaque réglage de veille se branche d'une ligne.
struct WatchSettingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsForm {
            WatchSettingsSections(model: model)
        }
    }
}
