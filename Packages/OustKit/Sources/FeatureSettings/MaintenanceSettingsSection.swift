import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustWatch

/// L'entretien planifié (Romain, 18/10/2026) : sa fréquence, où il se montre
/// (pastille, notification), son dernier passage, et de quoi l'essayer.
///
/// Un fichier à lui, branché d'une ligne dans `WatchSettingsSections` : les
/// Réglages se réorganisent pendant ce temps-là.
struct MaintenanceSettingsSection: View {
    let model: AppModel
    @State private var trying = false

    private var maintenance: MaintenanceModel { model.watch.maintenance }
    private var settings: MaintenanceSettings { maintenance.settings }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.isEnabled }, set: { maintenance.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Label { Text("settings.maintenance.enabled", bundle: .oust) } icon: { Image(systemName: "sparkles") }
                    Text("settings.maintenance.enabled_detail", bundle: .oust)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker(selection: Binding(get: { settings.frequency }, set: { maintenance.settings.frequency = $0 })) {
                ForEach(RetentionFrequency.allCases) { frequency in
                    Text(verbatim: L10n.string(frequency.localizationKey)).tag(frequency)
                }
            } label: { Text("settings.watch.frequency", bundle: .oust) }
                .disabled(!settings.isEnabled)
            Toggle(isOn: Binding(get: { settings.showsCapsule }, set: { maintenance.settings.showsCapsule = $0 })) {
                Text("settings.maintenance.capsule", bundle: .oust)
            }
            .disabled(!settings.isEnabled)
            Toggle(isOn: Binding(get: { settings.notifies }, set: { maintenance.settings.notifies = $0 })) {
                Text("settings.watch.also_notify", bundle: .oust)
            }
            .disabled(!settings.isEnabled)
            if settings.notifies, model.watch.notifications == .denied {
                HStack {
                    Image(systemName: "bell.slash").foregroundStyle(Palette.color(for: .review))
                    Text("settings.watch.notifications_denied", bundle: .oust)
                    Spacer()
                    Button { model.watch.openNotificationSettings() } label: { Text("settings.watch.open_settings", bundle: .oust) }
                }
            }
            HStack {
                Text(verbatim: status).font(Typography.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if maintenance.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await maintenance.runNow() } } label: { Text("settings.maintenance.run_now", bundle: .oust) }
                        .disabled(!maintenance.canRun)
                }
            }
            // Voir la pastille sans attendre une semaine, comme « Essayer l'alerte ».
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.maintenance.try_title", bundle: .oust)
                    Text("settings.maintenance.try_detail", bundle: .oust)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    trying = true
                    Task {
                        await maintenance.showPreview()
                        trying = false
                    }
                } label: { Text("settings.watch.alert_preview", bundle: .oust) }
                    .disabled(trying || maintenance.isRunning)
            }
        } header: {
            Text("settings.maintenance.section", bundle: .oust)
        } footer: {
            Text(verbatim: L10n.string("settings.maintenance.footer", Formatters.count(model.preferences.recencyDays)))
        }
    }

    /// « Dernier entretien il y a 2 jours : 12 Go à récupérer · prochain dans 5 jours ».
    private var status: String {
        if maintenance.isRunning { return L10n.string("settings.maintenance.running") }
        let state = maintenance.state
        var line: String
        if let last = state.lastRun {
            let found = (state.lastTotal ?? 0) > 0
                ? L10n.string("settings.maintenance.found", Formatters.bytes(state.lastTotal ?? 0))
                : L10n.string("settings.maintenance.found_nothing")
            line = L10n.string("settings.maintenance.last_run", Formatters.relative(last), found)
        } else {
            line = L10n.string("settings.maintenance.never")
        }
        if let next = maintenance.nextRun {
            line += " · " + L10n.string("settings.watch.next_run", Formatters.relative(next))
        }
        return line
    }
}
