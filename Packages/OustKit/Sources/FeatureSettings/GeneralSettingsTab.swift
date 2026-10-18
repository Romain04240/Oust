import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Général : le démarrage, la barre des menus et son icône, les promesses.
struct GeneralSettingsTab: View {
    @Bindable var model: AppModel

    private var watch: WatchModel { model.watch }

    var body: some View {
        SettingsForm {
            Section {
                Toggle(isOn: Binding(get: { watch.loginItem.isOn }, set: { watch.setOpensAtLogin($0) })) {
                    Text("settings.watch.login", bundle: .oust)
                    Text("settings.general.login_detail", bundle: .oust)
                }
                // Jamais grisé : macOS répond « introuvable » pour une app jamais
                // inscrite, et l'interrupteur grisé n'appelait jamais register().
                LoginItemRows(watch: watch)
            } header: {
                Text("settings.general.startup", bundle: .oust)
            }

            Section {
                Toggle(isOn: Binding(get: { watch.showsMenuBar }, set: { watch.showsMenuBar = $0 })) {
                    Text("settings.general.show_menubar", bundle: .oust)
                    Text("settings.general.menubar_detail", bundle: .oust)
                }
                LabeledContent {
                    MenuBarIconPicker(colored: Binding(get: { watch.menuBarIconInColor },
                                                       set: { watch.menuBarIconInColor = $0 }))
                } label: {
                    Text("settings.general.icon", bundle: .oust)
                    Text("settings.general.icon_detail", bundle: .oust)
                }
                .disabled(!watch.showsMenuBar)
            } header: {
                Text("settings.general.menubar", bundle: .oust)
            }

            Section {
                Label { Text("settings.promise_offline", bundle: .oust) } icon: { Image(systemName: "wifi.slash") }
                Label { Text("settings.promise_trash", bundle: .oust) } icon: { Image(systemName: "trash.square") }
                Label { Text("settings.promise_history", bundle: .oust) } icon: { Image(systemName: "clock") }
            } header: {
                Text("settings.promises", bundle: .oust)
            }
        }
    }
}
