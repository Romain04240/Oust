import Foundation
import OustHelperContract

/// Ce dont le démon a besoin du système pour les sauvegardes d'un disque Time
/// Machine : lire les destinations, l'état, la liste ; supprimer. Rien d'autre.
///
/// Un protocole pour que les tests remplacent `tmutil` par un faux qui note ce
/// qu'on lui demande : aucun test ne supprime de vraie sauvegarde.
public protocol BackupTool: Sendable {
    /// La sortie de `tmutil destinationinfo -X`, ou nil si elle a échoué.
    func destinationInfo() -> Data?

    /// La sortie de `tmutil status -X`, ou nil si elle a échoué.
    func status() -> Data?

    /// La sortie de `tmutil listbackups -d <point de montage>`, ou nil si elle
    /// a échoué.
    func listBackups(mountPoint: String) -> String?

    /// Supprime la sauvegarde de cet horodatage : nil si `tmutil` a confirmé,
    /// sinon ce qu'il a dit.
    func deleteBackup(mountPoint: String, timestamp: String) -> String?
}

/// `tmutil`, le vrai, avec des arguments fixes.
public struct SystemBackupTool: BackupTool {

    public init() {}

    public func destinationInfo() -> Data? {
        let result = SystemSnapshotTool.run(["destinationinfo", "-X"], timeout: 30)
        return result.status == 0 ? Data(result.output.utf8) : nil
    }

    public func status() -> Data? {
        let result = SystemSnapshotTool.run(["status", "-X"], timeout: 30)
        return result.status == 0 ? Data(result.output.utf8) : nil
    }

    public func listBackups(mountPoint: String) -> String? {
        guard TimeMachineBackups.isPlausibleMountPoint(mountPoint) else { return nil }
        // Sans `-m` : `-m` monterait chaque sauvegarde pour en donner le chemin.
        let result = SystemSnapshotTool.run(["listbackups", "-d", mountPoint], timeout: 120)
        return result.status == 0 ? result.output : nil
    }

    public func deleteBackup(mountPoint: String, timestamp: String) -> String? {
        // Revérifié au plus près de l'exécution : quel que soit le chemin
        // par lequel on arrive ici, aucune autre forme n'atteint `tmutil`.
        guard TimeMachineBackups.isPlausibleMountPoint(mountPoint) else { return "unknown destination" }
        guard TimeMachineBackups.isValidTimestamp(timestamp) else { return "malformed" }
        // Une sauvegarde APFS part en quelques secondes ; une sauvegarde HFS+,
        // faite de millions de liens physiques, peut prendre bien plus.
        let result = SystemSnapshotTool.run(["delete", "-d", mountPoint, "-t", timestamp], timeout: 3_600)
        if result.status == 0 { return nil }
        let said = (result.errorOutput.isEmpty ? result.output : result.errorOutput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "tmutil \(result.status)" : String(said.prefix(300))
    }
}
