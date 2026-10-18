import SwiftUI
import OustClean
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustVolume

/// « Garder les N dernières » sauvegardes d'un disque Time Machine (Romain,
/// 18/10/2026). On montre ce qui partira et ce qui restera, on dit qu'on ne
/// pourra plus revenir à ces dates, on redemande, puis `BackupPruner` relit
/// tout avant d'agir. La plus récente n'est jamais proposée, et N ne descend
/// pas sous 1.
///
/// Aucune taille par sauvegarde : elles partagent leurs fichiers, et ce que
/// chacune garde à elle seule ne se mesure pas sans la parcourir entière. On
/// annonce l'espace libre avant, et on le relit après (règle 9).
struct PruneBackupsSheet: View {
    let model: AppModel
    let target: BackupsTarget
    let onClose: () -> Void

    @State private var keep = BackupPruner.defaultKept
    @State private var confirming = false
    @State private var running = false
    @State private var report: BackupPruneReport?
    /// L'espace libre relu pendant qu'APFS rend la place, après coup.
    @State private var reclaimed: Int64?
    @State private var work: Task<Void, Never>?
    /// La liste relue à l'ouverture : le panneau a pu rester ouvert pendant
    /// qu'une sauvegarde se terminait.
    @State private var fresh: TimeMachineDestination?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var destination: TimeMachineDestination { fresh ?? target.destination }
    private var leaving: [TimeMachineBackup] { BackupPruner.plan(destination.backups, keeping: keep) }
    private var kept: [TimeMachineBackup] {
        let gone = Set(leaving)
        return destination.backups.filter { !gone.contains($0) }
    }
    private var refusal: BackupPruneRefusal? {
        BackupPruner.refusal(deleting: leaving, keeping: keep, in: destination)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            Label {
                Text(verbatim: L10n.string("backups.sheet_title", destination.name.isEmpty ? target.volume.name
                    : destination.name))
                    .font(Typography.headline)
            } icon: {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90").foregroundStyle(.orange)
            }
            if let report {
                outcome(report)
            } else {
                form
            }
        }
        .padding(Spacing.xLarge)
        .frame(width: 520)
        .interactiveDismissDisabled(running)
        .task {
            // N reste dans les bornes du pas à pas : jamais plus qu'il n'y a de sauvegardes.
            keep = min(keep, max(BackupPruner.minimumKept, destination.backups.count))
            if case .listed(let now) = await model.timeMachineListing(for: target.volume), now.id == target.destination.id {
                fresh = now
                keep = min(keep, max(BackupPruner.minimumKept, now.backups.count))
            }
        }
        .onDisappear { work?.cancel() }
        .confirmationDialog(Text(verbatim: confirmTitle), isPresented: $confirming, titleVisibility: .visible) {
            Button(role: .destructive) { prune() } label: { Text("backups.confirm_delete", bundle: .oust) }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .oust) }
        } message: {
            Text(verbatim: confirmMessage)
        }
    }

    // MARK: Le choix

    @ViewBuilder private var form: some View {
        Text(verbatim: TimeMachineSection.summary(destination.backups))
            .font(Typography.body.monospacedDigit())

        Stepper(value: $keep, in: BackupPruner.minimumKept...max(BackupPruner.minimumKept, destination.backups.count)) {
            Text(verbatim: keep == 1 ? L10n.string("backups.keep_one")
                 : L10n.string("backups.keep_many", Formatters.count(keep)))
                .font(Typography.body.weight(.semibold))
                .monospacedDigit()
        }
        .disabled(running)

        Text(verbatim: TimeMachineSection.leaving(leaving))
            .font(Typography.body)
            .monospacedDigit()

        lists

        Label {
            Text("backups.warning", bundle: .oust)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(Typography.caption)

        Text(verbatim: L10n.string("backups.space_before", Formatters.compactBytes(target.volume.capacity.available)))
            .font(Typography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text("backups.method", bundle: .oust)
            .font(Typography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if destination.isBackupRunning {
            Text("backups.running", bundle: .oust).font(Typography.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            if running {
                ProgressView().controlSize(.small)
                Text(verbatim: L10n.string("backups.working", Formatters.count(leaving.count)))
                    .font(Typography.caption)
            }
            Spacer()
            Button(role: .cancel) { onClose() } label: { Text("common.cancel", bundle: .oust) }
                .keyboardShortcut(.cancelAction)
                .disabled(running)
            Button(role: .destructive) { confirming = true } label: { Text(verbatim: deleteLabel) }
                .disabled(refusal != nil || running)
        }
    }

    /// Ce qui part, puis ce qui reste, la plus récente marquée.
    private var lists: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            column("backups.list_leaving", leaving, tint: .orange, symbol: "minus.circle.fill")
            column("backups.list_kept", kept, tint: Palette.vivid(for: .safe), symbol: "checkmark.circle.fill")
        }
        .frame(maxHeight: 220)
    }

    private func column(_ title: LocalizedStringKey, _ backups: [TimeMachineBackup], tint: Color,
                        symbol: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title, bundle: .oust).font(Typography.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.hair) {
                    // Les plus récentes d'abord, comme dans Time Machine.
                    ForEach(backups.reversed()) { backup in
                        HStack(spacing: Spacing.tight) {
                            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 10))
                            Text(verbatim: TimeMachineSection.moment(backup)).monospacedDigit().lineLimit(1)
                            if backup == destination.latest {
                                Text("backups.latest_tag", bundle: .oust).foregroundStyle(.secondary)
                            }
                        }
                        .font(Typography.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(Spacing.small)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }

    private var deleteLabel: String {
        leaving.count == 1 ? L10n.string("backups.delete_one")
            : L10n.string("backups.delete_many", Formatters.count(leaving.count))
    }

    private var confirmTitle: String {
        leaving.count == 1 ? L10n.string("backups.confirm_title_one")
            : L10n.string("backups.confirm_title_many", Formatters.count(leaving.count))
    }

    private var confirmMessage: String {
        guard let first = leaving.first, let last = leaving.last else { return "" }
        if leaving.count == 1 { return L10n.string("backups.confirm_message_one", TimeMachineSection.moment(first)) }
        return L10n.string("backups.confirm_message_many", TimeMachineSection.moment(first),
                           TimeMachineSection.moment(last))
    }

    // MARK: L'action

    private func prune() {
        let chosen = leaving
        let keep = keep
        running = true
        work = Task {
            let result = await model.pruneBackups(chosen, keeping: keep, on: destination)
            report = result
            running = false
            guard !result.deleted.isEmpty else { return }
            // APFS rend la place en arrière-plan : on relit l'espace libre
            // pendant trois minutes plutôt que d'annoncer un chiffre de l'instant.
            for await capacity in VolumeService.watchReclaim(of: target.volume.mountURL) {
                guard !Task.isCancelled else { break }
                reclaimed = capacity.available
            }
        }
    }

    // MARK: Le bilan

    @ViewBuilder private func outcome(_ report: BackupPruneReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if !report.deleted.isEmpty {
                Label {
                    Text(verbatim: report.deleted.count == 1 ? L10n.string("backups.done_one")
                         : L10n.string("backups.done_many", Formatters.count(report.deleted.count)))
                        .font(Typography.body.weight(.semibold))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.vivid(for: .safe))
                }
            }
            if !report.failed.isEmpty, report.refusal != .backupRunning, report.refusal != .timedOut {
                Text(verbatim: L10n.string("backups.failed_count", Formatters.count(report.failed.count)))
                    .font(Typography.caption).foregroundStyle(.red)
            }
            if !report.vanished.isEmpty {
                Text(verbatim: L10n.string("backups.vanished_count", Formatters.count(report.vanished.count)))
                    .font(Typography.caption).foregroundStyle(.secondary)
            }
            if let refusal = report.refusal {
                Text(verbatim: Self.message(for: refusal))
                    .font(Typography.caption)
                    .foregroundStyle(report.deleted.isEmpty ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !report.deleted.isEmpty, let before = report.availableBefore {
                let now = reclaimed ?? report.availableAfter ?? before
                Text(verbatim: L10n.string("backups.space_after", Formatters.compactBytes(before),
                                           Formatters.compactBytes(now)))
                    .font(Typography.body.monospacedDigit())
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text("backups.reclaiming", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button { onClose() } label: { Text("report.done", bundle: .oust) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    static func message(for refusal: BackupPruneRefusal) -> String {
        if case .failed(let message) = refusal { return L10n.string(refusal.localizationKey, message) }
        return L10n.string(refusal.localizationKey)
    }
}
