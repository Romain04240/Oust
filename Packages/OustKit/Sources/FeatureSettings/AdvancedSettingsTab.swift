import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Avancé : ce que macOS doit accorder à Oust!, et ce qu'on peut lui retirer.
struct AdvancedSettingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsForm {
            Section {
                HStack {
                    Image(systemName: model.fullDiskAccess == true ? "checkmark.shield.fill" : "lock.shield")
                        .foregroundStyle(model.fullDiskAccess == true ? Palette.color(for: .safe) : Palette.color(for: .review))
                    Text(model.fullDiskAccess == true ? "settings.access_granted" : "settings.access_missing", bundle: .oust)
                    Spacer()
                    Button { FullDiskAccess.openSettings() } label: { Text("access.open", bundle: .oust) }
                    Button { FullDiskAccess.relaunch() } label: { Text("access.relaunch", bundle: .oust) }
                }
            } header: {
                Text("settings.access", bundle: .oust)
            } footer: {
                Text("access.detail", bundle: .oust)
            }

            // Le démon privilégié, à installer ou non (docs/adr/0001).
            PrivilegedHelperSection()
                .disabled(model.cleaning == .running)
        }
    }
}
