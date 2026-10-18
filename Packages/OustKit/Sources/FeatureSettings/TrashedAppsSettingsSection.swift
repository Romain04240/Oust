import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Les restes d'une application qu'on met à la corbeille du Mac : les
/// proposer ou non (`TrashedAppsModel`).
struct TrashedAppsSettingsSection: View {
    let model: AppModel

    private var trashed: TrashedAppsModel { model.trashedApps }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { trashed.isEnabled }, set: { model.trashedApps.isEnabled = $0 })) {
                Text("settings.trashed.toggle", bundle: .oust)
                Text("settings.trashed.toggle_detail", bundle: .oust)
            }
            if trashed.isEnabled && model.fullDiskAccess == false {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(Palette.color(for: .review))
                    Text("settings.trashed.needs_access", bundle: .oust)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { FullDiskAccess.openSettings() } label: { Text("access.open", bundle: .oust) }
                }
            }
            if trashed.isEnabled && trashed.notifications == .denied {
                HStack {
                    Image(systemName: "bell.slash").foregroundStyle(Palette.color(for: .review))
                    Text("settings.watch.notifications_denied", bundle: .oust)
                    Spacer()
                    Button { trashed.openNotificationSettings() } label: {
                        Text("settings.watch.open_settings", bundle: .oust)
                    }
                }
            }
        } header: {
            Text("settings.trashed.section", bundle: .oust)
        } footer: {
            Text("settings.trashed.footer", bundle: .oust)
        }
        .task { await trashed.refreshPermission() }
    }
}
