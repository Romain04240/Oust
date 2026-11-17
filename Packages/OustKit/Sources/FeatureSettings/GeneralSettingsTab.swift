import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustWatch

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
                Picker(selection: Binding(get: { watch.menuBarContents }, set: { watch.menuBarContents = $0 })) {
                    ForEach(MenuBarContents.allCases) { mode in
                        Text(LocalizedStringKey(mode.localizationKey), bundle: .oust).tag(mode)
                    }
                } label: {
                    Text("settings.general.menubar_contents", bundle: .oust)
                }
                .disabled(!watch.showsMenuBar)
                Group {
                    Toggle(isOn: Binding(get: { watch.menuBarUsesDriveIcon }, set: { watch.menuBarUsesDriveIcon = $0 })) {
                        Text("settings.general.icon_drive", bundle: .oust)
                    }
                    if !watch.menuBarUsesDriveIcon {
                        LabeledContent {
                            MenuBarIconPicker(colored: Binding(get: { watch.menuBarIconInColor },
                                                               set: { watch.menuBarIconInColor = $0 }))
                        } label: {
                            Text("settings.general.icon", bundle: .oust)
                            Text("settings.general.icon_detail", bundle: .oust)
                        }
                    }
                }
                .disabled(!watch.showsMenuBar || !watch.menuBarContents.showsStorage)
            } header: {
                Text("settings.general.menubar", bundle: .oust)
            }

            Section {
                Text("updates.privacy", bundle: .oust)
                    .font(.caption)
                HStack {
                    Text(verbatim: L10n.string("updates.installed", model.updates.currentVersion))
                    Spacer()
                    if model.updates.busy { ProgressView().controlSize(.small) }
                    Button { Task { await model.updates.check() } } label: { Text("updates.check", bundle: .oust) }
                        .disabled(model.updates.busy)
                }
                if let message = model.updates.message {
                    Text(verbatim: message).font(.caption).textSelection(.enabled)
                }
                if model.updates.release != nil {
                    if model.updates.installer != nil {
                        Button { model.updates.openInstaller() } label: { Text("updates.open_installer", bundle: .oust) }
                    } else {
                        Button { Task { await model.updates.download() } } label: { Text("updates.download", bundle: .oust) }
                            .disabled(model.updates.busy)
                    }
                }
            } header: { Text("updates.title", bundle: .oust) }

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
