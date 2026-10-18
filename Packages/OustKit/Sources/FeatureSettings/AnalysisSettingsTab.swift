import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Analyse : où chercher, et avec quelle prudence.
struct AnalysisSettingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsForm {
            Section {
                ForEach(model.preferences.projectRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        Text(verbatim: root.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            model.preferences.projectRoots.removeAll { $0 == root }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .help(Text("settings.analysis.remove_root", bundle: .oust))
                            .accessibilityLabel(Text("settings.analysis.remove_root", bundle: .oust))
                    }
                }
                Button { addRoot() } label: {
                    Label { Text("settings.add_root", bundle: .oust) } icon: { Image(systemName: "plus") }
                }
            } header: {
                Text("settings.roots", bundle: .oust)
            } footer: {
                Text("settings.roots_footer", bundle: .oust)
            }

            Section {
                Stepper(value: $model.preferences.recencyDays, in: 1...60) {
                    Text(verbatim: L10n.string("settings.recency", Formatters.count(model.preferences.recencyDays)))
                    Text("settings.analysis.recency_detail", bundle: .oust)
                }
            } header: {
                Text("settings.analysis.caution", bundle: .oust)
            }

            Section {
                Stepper(value: $model.preferences.historyRetentionDays, in: 7...365, step: 7) {
                    Text(verbatim: L10n.string("settings.retention", Formatters.count(model.preferences.historyRetentionDays)))
                    Text("settings.analysis.retention_detail", bundle: .oust)
                }
                Stepper(value: $model.preferences.duplicateMinimumMegabytes, in: 1...1000) {
                    Text(verbatim: L10n.string("settings.duplicate_minimum", Formatters.count(model.preferences.duplicateMinimumMegabytes)))
                    Text("settings.analysis.duplicate_minimum_detail", bundle: .oust)
                }
                Stepper(value: $model.preferences.compressionAgeMonths, in: 1...36) {
                    Text(verbatim: L10n.string("settings.compression_age", Formatters.count(model.preferences.compressionAgeMonths)))
                    Text("settings.analysis.compression_age_detail", bundle: .oust)
                }
            } header: {
                Text("settings.analysis.offers", bundle: .oust)
            }
        }
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !model.preferences.projectRoots.contains(url) {
                model.preferences.projectRoots.append(url)
            }
        }
    }
}
