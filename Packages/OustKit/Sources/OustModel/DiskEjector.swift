import AppKit
import Foundation
import OustCore
import OustWatch

/// Éjecter un disque depuis la barre de menus (Romain, 18/10/2026).
///
/// Par `NSWorkspace`, comme le Finder : macOS refuse si un fichier y est
/// ouvert, et on rend son message tel quel. Rien n'est supprimé ni forcé.
public enum DiskEjector {

    /// Ce qu'on peut éjecter : tout sauf le disque de démarrage et les disques
    /// internes fixes.
    public static func canEject(_ volume: VolumeDescriptor) -> Bool {
        WatchedVolumes.isEjectable(isBoot: volume.isBoot, isInternal: volume.isInternal,
                                   isRemovable: volume.isRemovable)
    }

    /// Éjecte, hors du fil principal : un disque lent à se démonter ne fige pas
    /// le panneau. Rend le message de macOS en cas de refus, `nil` sinon.
    public static func eject(_ volume: VolumeDescriptor) async -> String? {
        let url = volume.mountURL
        return await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
    }
}
