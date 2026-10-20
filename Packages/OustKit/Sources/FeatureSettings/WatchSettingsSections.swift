import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustWatch

/// Les réglages de la veille, onglet « Veille » des Réglages : alerte disque
/// bas, règles planifiées. Un nouveau réglage de veille vient dans son propre
/// fichier et se branche ici d'une ligne, après `rulesSection`.
/// La barre de menus et l'ouverture à la connexion sont dans « Général ».
struct WatchSettingsSections: View {
    @Bindable var model: AppModel
    @State private var previewing: RetentionFamily?

    private var watch: WatchModel { model.watch }

    var body: some View {
        alertSection
        MaintenanceSettingsSection(model: model)
        TrashedAppsSettingsSection(model: model)
        rulesSection
            .sheet(item: $previewing) { family in
                RetentionPreviewSheet(watch: watch, family: family)
            }
    }

    // MARK: Alerte disque bas

    private var alertSection: some View {
        Section {
            Toggle(isOn: Binding(get: { watch.settings.alertsLowDisk }, set: { watch.settings.alertsLowDisk = $0 })) {
                Text("settings.watch.alert", bundle: .oust)
                Text("settings.watch.alert_detail", bundle: .oust)
            }
            // Le seuil, son unité, et ce qu'il vaut aujourd'hui sur le disque de
            // démarrage : une seule rangée, la phrase dessous.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: thresholdLabel).monospacedDigit()
                    if let boot = watch.boot, let threshold = watch.thresholdBytes {
                        Text(verbatim: L10n.string("settings.watch.threshold_now", boot.name, Formatters.bytes(threshold),
                                                   Formatters.bytes(boot.capacity.availableForImportantUsage)))
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Picker(selection: thresholdIsPercent) {
                    Text("settings.watch.unit_percent", bundle: .oust).tag(true)
                    Text("settings.watch.unit_gigabytes", bundle: .oust).tag(false)
                } label: { Text("settings.watch.unit", bundle: .oust) }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                Stepper(value: thresholdValue, in: thresholdRange) { Text(verbatim: thresholdLabel) }
                    .labelsHidden()
            }
            .disabled(!watch.settings.alertsLowDisk)
            // Voir la pastille sans attendre que le disque se remplisse (Romain,
            // 18/10/2026) : les vrais chiffres, et rien ne bouge dans l'alerte.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.watch.try_title", bundle: .oust)
                    Text("settings.watch.try_detail", bundle: .oust)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { watch.showAlertPreview() } label: { Text("settings.watch.alert_preview", bundle: .oust) }
            }
            Toggle(isOn: Binding(get: { watch.settings.alsoNotifies }, set: { watch.settings.alsoNotifies = $0 })) {
                Text("settings.watch.also_notify", bundle: .oust)
                Text("settings.watch.also_notify_detail", bundle: .oust)
            }
            .disabled(!watch.settings.alertsLowDisk)
            if watch.settings.alsoNotifies { NotificationsDeniedRow(watch: watch) }
        } header: {
            Text("settings.watch.alert_section", bundle: .oust)
        } footer: {
            Text("settings.watch.alert_scope", bundle: .oust)
        }
    }

    private var thresholdIsPercent: Binding<Bool> {
        Binding(get: { watch.settings.threshold.isPercent }, set: { percent in
            guard percent != watch.settings.threshold.isPercent else { return }
            watch.settings.threshold = percent ? .percent(LowDiskThreshold.defaultPercent)
                : .gigabytes(LowDiskThreshold.defaultGigabytes)
        })
    }

    private var thresholdValue: Binding<Int> {
        Binding(get: { watch.settings.threshold.value }, set: { value in
            watch.settings.threshold = watch.settings.threshold.isPercent ? .percent(value) : .gigabytes(value)
        })
    }

    private var thresholdRange: ClosedRange<Int> {
        watch.settings.threshold.isPercent ? LowDiskThreshold.percentRange : LowDiskThreshold.gigabyteRange
    }

    private var thresholdLabel: String {
        let value = Formatters.count(watch.settings.threshold.value)
        return L10n.string(watch.settings.threshold.isPercent ? "settings.watch.threshold_percent"
                           : "settings.watch.threshold_gigabytes", value)
    }

    // MARK: Règles planifiées

    private var rulesSection: some View {
        Section {
            ForEach(RetentionFamily.allCases) { family in
                RetentionRow(watch: watch, family: family) { previewing = family }
            }
            if watch.settings.policies.contains(where: \.isEnabled) { NotificationsDeniedRow(watch: watch) }
        } header: {
            Text("settings.watch.rules_section", bundle: .oust)
        } footer: {
            Text("settings.watch.rules_footer", bundle: .oust)
        }
    }
}

/// macOS refuse les notifications d'Oust! : le dire, et mener au bon réglage.
private struct NotificationsDeniedRow: View {
    let watch: WatchModel

    var body: some View {
        if watch.notifications == .denied {
            HStack {
                Image(systemName: "bell.slash").foregroundStyle(Palette.color(for: .review))
                Text("settings.watch.notifications_denied", bundle: .oust)
                Spacer()
                Button { watch.openNotificationSettings() } label: { Text("settings.watch.open_settings", bundle: .oust) }
            }
        }
    }
}

/// Une règle planifiée : une rangée, cochée ou non, avec ses passages et son
/// aperçu ; sa fréquence et l'âge minimal sur une seconde rangée, seulement
/// quand elle est cochée. Quatre rangées par règle faisaient la moitié de la
/// longueur des Réglages (Romain, 18/10/2026 : « trop long, ça défile »).
private struct RetentionRow: View {
    let watch: WatchModel
    let family: RetentionFamily
    let preview: () -> Void

    private var policy: RetentionPolicy { watch.settings.policy(family) }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.medium) {
            Image(systemName: family.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: L10n.string(family.localizationKey))
                Text(verbatim: L10n.string(family.detailKey))
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: status)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Spacing.small)
            // Toujours ouvert : on regarde ce qu'une règle prendrait avant de la cocher.
            Button(action: preview) { Text("settings.watch.preview", bundle: .oust) }
                .disabled(watch.runningFamily != nil)
            Toggle(isOn: Binding(get: { policy.isEnabled }, set: { watch.setEnabled($0, for: family) })) {
                Text(verbatim: L10n.string(family.localizationKey))
            }
            .labelsHidden()
            .toggleStyle(.switch)
        }
        if policy.isEnabled {
            HStack(spacing: Spacing.large) {
                Picker(selection: Binding(get: { policy.frequency }, set: { value in watch.update(family) { $0.frequency = value } })) {
                    ForEach(RetentionFrequency.allCases) { frequency in
                        Text(verbatim: L10n.string(frequency.localizationKey)).tag(frequency)
                    }
                } label: { Text("settings.watch.frequency", bundle: .oust) }
                    .fixedSize()
                Spacer()
                Picker(selection: Binding(get: { policy.minimumAgeDays }, set: { value in watch.update(family) { $0.minimumAgeDays = value } })) {
                    ForEach(RetentionPolicy.ageChoices, id: \.self) { days in
                        Text(verbatim: L10n.string("settings.watch.age_days", Formatters.count(days))).tag(days)
                    }
                } label: { Text("settings.watch.age", bundle: .oust) }
                    .fixedSize()
            }
            .padding(.leading, 22 + Spacing.medium)
        }
    }

    private var status: String {
        if watch.runningFamily == family { return L10n.string("settings.watch.running") }
        let last = watch.lastRun(family).map { L10n.string("settings.watch.last_run", Formatters.relative($0)) }
            ?? L10n.string("settings.watch.never")
        guard let next = watch.nextRun(family) else { return last }
        return last + " · " + L10n.string("settings.watch.next_run", Formatters.relative(next))
    }
}

/// Ce qu'une règle prendrait aujourd'hui, avant de la laisser faire seule :
/// la confiance passe par la clarté (SPEC §9.1).
private struct RetentionPreviewSheet: View {
    let watch: WatchModel
    let family: RetentionFamily
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CleanupItem]?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(verbatim: L10n.string("settings.watch.preview_title", L10n.string(family.localizationKey)))
                .font(Typography.headline)
            Text("settings.watch.preview_detail", bundle: .oust)
                .font(Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let items, items.isEmpty {
                    Label { Text("settings.watch.preview_empty", bundle: .oust) } icon: {
                        Image(systemName: "checkmark.circle").foregroundStyle(Palette.color(for: .safe))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let items {
                    List(items) { item in PreviewLine(item: item) }
                        .listStyle(.inset)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 260)
            HStack {
                if let items, !items.isEmpty {
                    let total = Formatters.bytes(items.reduce(0) { $0 + $1.sizes.freeable })
                    Text(verbatim: items.count == 1 ? L10n.string("watch.items_one", total)
                         : L10n.string("watch.items_other", Formatters.count(items.count), total))
                        .font(Typography.size)
                }
                Spacer()
                Button(role: .cancel) { dismiss() } label: { Text("common.cancel", bundle: .oust) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    guard let items else { return }
                    running = true
                    Task {
                        await watch.runNow(family, items: items)
                        dismiss()
                    }
                } label: {
                    if running { ProgressView().controlSize(.small) } else { Text("settings.watch.preview_run", bundle: .oust) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.eclatSolid)
                .disabled(items?.isEmpty != false || running || !watch.canRun)
            }
        }
        .padding(Spacing.xLarge)
        .frame(width: 560, height: 480)
        .task { items = await watch.preview(family) }
    }
}

private struct PreviewLine: View {
    let item: CleanupItem

    var body: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: Palette.symbol(for: item.safety)).foregroundStyle(Palette.color(for: item.safety))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title).lineLimit(1)
                Text(verbatim: item.detail ?? item.owner).font(Typography.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let last = item.lastActivity {
                Text(verbatim: Formatters.relative(last)).font(Typography.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: Formatters.bytes(item.sizes.freeable)).font(Typography.size)
                .frame(minWidth: 70, alignment: .trailing)
        }
    }
}
