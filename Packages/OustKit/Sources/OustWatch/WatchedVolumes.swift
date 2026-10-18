import Foundation

/// Les disques branchés que l'alerte surveille, en plus du disque de démarrage
/// (Romain, 18/10/2026).
///
/// Écartés, parce qu'ils crieraient sans raison ou feraient attendre : les
/// sauvegardes Time Machine (pleines par nature, macOS y fait la place), les
/// images disque en lecture seule (un `.dmg` d'installation monté est toujours
/// plein), les disques réseau (un `statfs` sur un partage endormi peut bloquer)
/// et les volumes du système.
public enum WatchedVolumes {

    /// Ce qu'on sait d'un volume monté, lu dans ses `URLResourceValues`.
    public struct Candidate: Sendable, Equatable {
        public var path: String
        public var isLocal: Bool
        public var isBrowsable: Bool
        public var isReadOnly: Bool
        public var isRootFileSystem: Bool

        public init(path: String, isLocal: Bool, isBrowsable: Bool, isReadOnly: Bool, isRootFileSystem: Bool) {
            self.path = path
            self.isLocal = isLocal
            self.isBrowsable = isBrowsable
            self.isReadOnly = isReadOnly
            self.isRootFileSystem = isRootFileSystem
        }
    }

    public static func accepts(_ volume: Candidate, timeMachine: Set<String>) -> Bool {
        let path = normalized(volume.path)
        guard volume.isLocal, volume.isBrowsable, !volume.isReadOnly, !volume.isRootFileSystem else { return false }
        guard path != "/", !path.hasPrefix("/System/Volumes") else { return false }
        return !timeMachine.contains(path)
    }

    /// Les points de montage des destinations Time Machine, d'après
    /// `tmutil destinationinfo -X`. Illisible : aucun (rien n'est écarté à tort,
    /// au pire une sauvegarde pleine prévient une fois).
    public static func timeMachineMountPoints(in plist: Data) -> Set<String> {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let destinations = object["Destinations"] as? [[String: Any]] else { return [] }
        return Set(destinations.compactMap { $0["MountPoint"] as? String }.map(normalized))
    }

    /// Ce que la barre de menus propose d'éjecter : jamais le disque de
    /// démarrage ni un disque interne fixe.
    public static func isEjectable(isBoot: Bool, isInternal: Bool, isRemovable: Bool) -> Bool {
        !isBoot && (isRemovable || !isInternal)
    }

    static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
