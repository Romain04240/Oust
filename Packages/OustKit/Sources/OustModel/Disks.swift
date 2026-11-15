import AppKit
import Foundation
import OustClean
import OustCore
import OustSafety
import OustScan
import OustVolume

/// Ce qu'un nuage occupe sur ce Mac.
public struct CloudFootprint: Sendable, Identifiable {
    public var id: String { provider.id }
    public let provider: CloudProvider
    /// Ses fichiers sur ce disque, d'après l'arbre partagé ; nil tant qu'il n'est pas là.
    public let onThisMac: Int64?
    /// Ce qui s'évince sans rien perdre (« Fichiers du nuage gardés sur ce Mac »).
    public let evictable: Int64
}

public enum EjectOutcome: Sendable, Equatable {
    case ejected
    /// Ces applications y gardent des fichiers ouverts.
    case inUse([String])
    case failed(String)
}

/// Le panneau des disques : ce qu'il y a de branché, ce que les nuages gardent
/// ici, éjecter, lire, formater (demande de Romain, 18/10/2026).
extension AppModel {

    public func diskDetails(_ volume: VolumeDescriptor) async -> DiskDetails? {
        await DiskInfo.details(of: volume.mountURL)
    }

    public var cloudFootprints: [CloudFootprint] {
        let tree = disk.currentTree
        return CloudProviders.installed(home: home).map { provider in
            CloudFootprint(provider: provider, onThisMac: tree?.measurement(of: provider.root)?.sizes.allocated,
                           evictable: 0)
        }
    }

    /// Éjecte, ou dit qui en empêche : le Finder dit seulement « utilisé ».
    public func eject(_ volume: VolumeDescriptor) async -> EjectOutcome {
        let path = volume.mountURL.path
        let holders = await Task.detached(priority: .userInitiated) { OpenFiles.holders(under: path) }.value
        if !holders.isEmpty { return .inUse(Self.displayNames(holders)) }
        if let message = VolumeService.eject(volume.mountURL) { return .failed(message) }
        refreshVolumes()
        return .ejected
    }

    /// Formate le disque entier qui porte ce volume, après les gardes de
    /// `DiskEraser`. Nil quand c'est fait.
    public func erase(_ details: DiskDetails, format: EraseFormat, name: String) async -> EraseRefusal? {
        let startup = await DiskInfo.details(of: VolumeService.bootDataRoot)?.wholeDisk
        let refusal = await DiskEraser.erase(details, format: format, name: name, startupWholeDisk: startup)
        refreshVolumes()
        return refusal
    }

    /// L'arbre déjà analysé d'un volume, pour sa répartition : celui du disque de
    /// démarrage (l'analyse partagée), ou celui que l'Explorateur montre.
    public func analyzedTree(for volume: VolumeDescriptor) -> TreeNode? {
        if volume.isBoot { return disk.currentTree }
        return volumeIndexes[volume.id]?.root ?? (treeVolume?.id == volume.id ? tree : nil)
    }

    /// Quand ce disque a été analysé pour la dernière fois.
    public func analysisDate(for volume: VolumeDescriptor) -> Date? {
        if volume.isBoot { return disk.currentScanDate }
        return volumeIndexes[volume.id]?.scannedAt
    }

    /// Une analyse de ce disque est en cours.
    public func isAnalyzing(_ volume: VolumeDescriptor) -> Bool {
        if volume.isBoot { return disk.isRefreshing }
        return treeVolume?.id == volume.id && explorer.isRunning
    }

    /// Relit le disque : le disque de démarrage par son index partagé, un autre
    /// en entier, sans quitter la section où l'on est.
    public func reanalyze(_ volume: VolumeDescriptor) {
        if volume.isBoot { disk.refresh() } else { explore(volume, rescan: true) }
    }

    /// L'analyse gardée d'un autre disque, relue du disque à la première demande.
    @discardableResult
    public func storedAnalysis(for volume: VolumeDescriptor) async -> ScanIndex? {
        guard !volume.isBoot else { return nil }
        let options = Self.volumeScanOptions(for: volume, home: home)
        if let known = volumeIndexes[volume.id], known.canReuse(for: options) { return known }
        guard let store = Self.volumeStore(for: volume) else { return nil }
        let root = volume.scanRoot.standardizedFileURL.path
        guard let loaded = await Task.detached(priority: .userInitiated, operation: { store.load(rootPath: root) }).value,
              loaded.canReuse(for: options)
        else { return nil }
        volumeIndexes[volume.id] = loaded
        return loaded
    }

    /// Le dossier où garder l'arbre d'un disque : d'après l'UUID du volume, pas
    /// son chemin. Deux clés « SANS TITRE » se montent l'une après l'autre sur
    /// `/Volumes/SANS TITRE` : l'arbre de l'une ne doit jamais passer pour celui
    /// de l'autre. Sans UUID, rien n'est gardé.
    nonisolated static func volumeStore(for volume: VolumeDescriptor) -> TreeStore? {
        guard let uuid = try? volume.mountURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              !uuid.isEmpty, !uuid.contains("/") else { return nil }
        let base = TreeStore.standard().directory
        return TreeStore(directory: base.appendingPathComponent("Volumes/\(uuid)", isDirectory: true))
    }

    /// Les partitions d'aujourd'hui, pour montrer ce qu'un formatage effacerait.
    public func diskLayout(_ details: DiskDetails) async -> DiskLayout? {
        await DiskInfo.layout(of: details.wholeDisk)
    }

    /// Renomme le volume ; rien n'est effacé. Nil quand c'est fait.
    public func renameVolume(_ details: DiskDetails, to name: String) async -> String? {
        let failure = await DiskInfo.rename(details, to: name)
        refreshVolumes()
        return failure
    }

    /// Efface le disque entier et le repartitionne, après les gardes de `DiskEraser`.
    public func partitionDisk(_ details: DiskDetails, scheme: PartitionScheme, partitions: [PartitionSpec],
                              diskSize: Int64) async -> EraseRefusal? {
        let startup = await DiskInfo.details(of: VolumeService.bootDataRoot)?.wholeDisk
        let refusal = await DiskEraser.partition(details, scheme: scheme, partitions: partitions,
                                                 diskSize: diskSize, startupWholeDisk: startup)
        refreshVolumes()
        return refusal
    }

    /// Le nom de l'application plutôt que celui du processus (« Aperçu », pas « Preview »).
    static func displayNames(_ holders: [OpenFileHolder]) -> [String] {
        Array(Set(holders.map { NSRunningApplication(processIdentifier: $0.pid)?.localizedName ?? $0.name })).sorted()
    }
}
