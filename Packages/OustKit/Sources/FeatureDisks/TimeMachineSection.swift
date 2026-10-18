import SwiftUI
import OustClean
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustVolume

/// Le disque de sauvegarde, et les sauvegardes qu'on peut en retirer.
struct BackupsTarget: Identifiable {
    var id: String { destination.id }
    let volume: VolumeDescriptor
    let destination: TimeMachineDestination
}

/// Dans le panneau d'un disque Time Machine : combien de sauvegardes, de quand
/// à quand, et « Garder les 3 dernières… » (Romain, 18/10/2026 : « le disque me
/// dit qu'il n'y a presque plus d'espace, mais c'est parce qu'il y a plusieurs
/// versions »).
///
/// Ici, et non dans la corbeille : une sauvegarde n'est pas un élément de
/// l'analyse, elle vit sur ce disque, et c'est en ouvrant ce disque qu'on se
/// demande pourquoi il est plein. Rien ne s'affiche pour un autre disque.
///
/// La liste est lue par le panneau, dans la tâche qui lit déjà le disque : posée
/// ici sur une vue encore vide, la tâche ne partait jamais, et la section ne
/// paraissait pas (18/10/2026, sur le disque de Romain).
struct TimeMachineSection: View {
    let volume: VolumeDescriptor
    let listing: TimeMachineListing
    let onPrune: (BackupsTarget) -> Void

    var body: some View {
        switch listing {
        case .listed(let destination):
            Divider()
            content(destination)
        case .unreadable:
            Divider()
            VStack(alignment: .leading, spacing: Spacing.small) {
                title
                Text("backups.unreadable", bundle: .oust)
                    .font(Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .notADestination:
            EmptyView()
        }
    }

    private var title: some View {
        Label {
            Text("backups.title", bundle: .oust).font(Typography.headline)
        } icon: {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        }
    }

    private func content(_ destination: TimeMachineDestination) -> some View {
        let removable = BackupPruner.plan(destination.backups, keeping: BackupPruner.defaultKept)
        return VStack(alignment: .leading, spacing: Spacing.small) {
            title
            Text(verbatim: Self.summary(destination.backups))
                .font(Typography.body.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
            if destination.isBackupRunning {
                Text("backups.running", bundle: .oust).font(Typography.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if destination.backups.count <= BackupPruner.minimumKept {
                    Text("backups.only_latest", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if destination.backups.count > BackupPruner.minimumKept {
                    Button { onPrune(BackupsTarget(volume: volume, destination: destination)) } label: {
                        Text(verbatim: L10n.string("backups.keep_button", Formatters.count(BackupPruner.defaultKept)))
                    }
                    .help(Text(verbatim: removable.isEmpty ? L10n.string("backups.leaving_none")
                        : Self.leaving(removable)))
                }
            }
        }
    }

    // MARK: Phrases

    /// « 14 sauvegardes, du 3 mars 2025 au 18 oct. 2026 ».
    static func summary(_ backups: [TimeMachineBackup]) -> String {
        guard let first = backups.first, let last = backups.last else { return L10n.string("backups.summary_none") }
        if backups.count == 1 { return L10n.string("backups.summary_one", day(first)) }
        return L10n.string("backups.summary_many", Formatters.count(backups.count), day(first), day(last))
    }

    /// « Partiront : 11 sauvegardes, du … au … ».
    static func leaving(_ backups: [TimeMachineBackup]) -> String {
        guard let first = backups.first, let last = backups.last else { return L10n.string("backups.leaving_none") }
        if backups.count == 1 { return L10n.string("backups.leaving_one", moment(first)) }
        return L10n.string("backups.leaving_many", Formatters.count(backups.count), moment(first), moment(last))
    }

    /// Le jour, pour le résumé du panneau.
    static func day(_ backup: TimeMachineBackup) -> String {
        backup.date?.formatted(.dateTime.day().month(.abbreviated).year()) ?? backup.timestamp
    }

    /// Le jour et l'heure, comme dans l'Historique : plusieurs sauvegardes par
    /// jour se distinguent à l'heure.
    static func moment(_ backup: TimeMachineBackup) -> String {
        backup.date.map(Formatters.timestamp) ?? backup.timestamp
    }
}
