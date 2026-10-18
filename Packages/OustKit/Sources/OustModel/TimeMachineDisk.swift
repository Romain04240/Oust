import Foundation
import OustClean
import OustCore
import OustLocalization
import OustVolume

/// Les sauvegardes d'un disque Time Machine, vues du panneau du disque
/// (Romain, 18/10/2026). Sans état ici : le panneau relit la liste à chaque
/// ouverture, et `BackupPruner` la relit encore juste avant d'agir.
extension AppModel {

    /// Ce volume est-il un disque Time Machine, et que contient-il ?
    public func timeMachineListing(for volume: VolumeDescriptor) async -> TimeMachineListing {
        guard !volume.isBoot else { return .notADestination }
        return await TimeMachineService.listing(of: volume.mountURL)
    }

    /// Supprime ces sauvegardes après les gardes de `BackupPruner`, journalise
    /// chacune, puis relit l'espace des disques.
    public func pruneBackups(_ chosen: [TimeMachineBackup], keeping keep: Int,
                             on destination: TimeMachineDestination) async -> BackupPruneReport {
        let report = await BackupPruner.prune(chosen, keeping: keep, shown: destination, history: history,
                                              title: { $0.date.map(Formatters.timestamp) ?? $0.timestamp })
        await refreshVolumesInBackground()
        return report
    }
}
