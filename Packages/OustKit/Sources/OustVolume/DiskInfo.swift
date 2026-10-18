import AppKit
import Foundation
import OustCore

/// Ce que macOS dit d'un disque monté, en lecture seule (`diskutil info`).
public struct DiskDetails: Sendable, Equatable {
    /// « APFS », « ExFAT », « Mac OS étendu (journalisé) »…
    public var format: String
    /// « USB », « Thunderbolt », « Apple Fabric »…
    public var busProtocol: String?
    public var mediaName: String?
    public var isInternal: Bool
    public var isEjectable: Bool
    public var isRemovableMedia: Bool
    public var isEncrypted: Bool
    public var isWritable: Bool
    public var isSolidState: Bool?
    /// L'identifiant du volume (`disk4s2`).
    public var deviceIdentifier: String
    /// Le disque physique entier qui le porte (`disk4`) : pour un volume APFS,
    /// celui de son conteneur, pas le disque synthétisé.
    public var wholeDisk: String
    public var mountPoint: String

    public init(format: String, busProtocol: String?, mediaName: String?, isInternal: Bool, isEjectable: Bool,
                isRemovableMedia: Bool, isEncrypted: Bool, isWritable: Bool, isSolidState: Bool?,
                deviceIdentifier: String, wholeDisk: String, mountPoint: String) {
        self.format = format
        self.busProtocol = busProtocol
        self.mediaName = mediaName
        self.isInternal = isInternal
        self.isEjectable = isEjectable
        self.isRemovableMedia = isRemovableMedia
        self.isEncrypted = isEncrypted
        self.isWritable = isWritable
        self.isSolidState = isSolidState
        self.deviceIdentifier = deviceIdentifier
        self.wholeDisk = wholeDisk
        self.mountPoint = mountPoint
    }

    /// Un disque qu'on peut formater depuis Oust! : externe, éjectable ou
    /// amovible, inscriptible. Jamais un disque interne.
    public var isExternal: Bool { !isInternal && (isEjectable || isRemovableMedia) }
}

public enum DiskInfo {

    /// Les informations d'un volume monté, ou nil si `diskutil` ne répond pas.
    public static func details(of mount: URL) async -> DiskDetails? {
        guard let info = await plist(mount.path) else { return nil }
        var physical: String?
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]],
           let store = stores.first?["APFSPhysicalStore"] as? String,
           let storeInfo = await plist(store) {
            physical = storeInfo["ParentWholeDisk"] as? String
        }
        return parse(info, physicalWholeDisk: physical)
    }

    /// Lecture pure, pour les tests : `diskutil info -plist` déjà décodé.
    static func parse(_ info: [String: Any], physicalWholeDisk: String?) -> DiskDetails? {
        guard let device = info["DeviceIdentifier"] as? String,
              let whole = physicalWholeDisk ?? info["ParentWholeDisk"] as? String else { return nil }
        let media = (info["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return DiskDetails(
            format: info["FilesystemUserVisibleName"] as? String ?? info["FilesystemName"] as? String ?? "—",
            busProtocol: info["BusProtocol"] as? String,
            mediaName: media,
            isInternal: info["Internal"] as? Bool ?? true,
            isEjectable: info["Ejectable"] as? Bool ?? false,
            isRemovableMedia: info["RemovableMedia"] as? Bool ?? false,
            isEncrypted: (info["Encryption"] as? Bool ?? false) || (info["FileVault"] as? Bool ?? false),
            isWritable: info["WritableVolume"] as? Bool ?? info["Writable"] as? Bool ?? false,
            isSolidState: info["SolidState"] as? Bool,
            deviceIdentifier: device,
            wholeDisk: whole,
            mountPoint: info["MountPoint"] as? String ?? ""
        )
    }

    private static func plist(_ target: String) async -> [String: Any]? {
        let result = await Command.run("/usr/sbin/diskutil", ["info", "-plist", target], timeout: 10)
        guard result.succeeded,
              let object = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) else { return nil }
        return object as? [String: Any]
    }
}

// MARK: - Éjecter

extension VolumeService {
    /// Démonte et éjecte un disque. Rend le message de macOS en cas d'échec.
    @MainActor
    public static func eject(_ mount: URL) -> String? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: mount)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Nuages

/// Un service de nuage synchronisé sur ce Mac (iCloud Drive, File Providers).
public struct CloudProvider: Sendable, Hashable, Identifiable {
    public var id: String { root.path }
    public let name: String
    public let account: String?
    public let root: URL
}

public enum CloudProviders {
    /// Les noms des File Providers courants, d'après le début de leur dossier
    /// (`GoogleDrive-moi@exemple.fr`). Un inconnu garde son nom de dossier.
    static let knownNames: [String: String] = [
        "GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box",
        "pCloudDrive": "pCloud", "SynologyDrive": "Synology Drive", "Nextcloud": "Nextcloud",
    ]

    /// Ce qui est synchronisé sur ce Mac. Rien n'est demandé aux serveurs : le
    /// quota en ligne exigerait le réseau (RULES.md, règle 11).
    public static func installed(home: URL) -> [CloudProvider] {
        var providers: [CloudProvider] = []
        let fileManager = FileManager.default
        let iCloud = home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        if fileManager.fileExists(atPath: iCloud.appendingPathComponent("com~apple~CloudDocs").path) {
            providers.append(CloudProvider(name: "iCloud Drive", account: nil, root: iCloud))
        }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let folders = (try? fileManager.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            providers.append(provider(folder))
        }
        return providers
    }

    static func provider(_ folder: URL) -> CloudProvider {
        let name = folder.lastPathComponent
        let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
        let service = knownNames[parts[0]] ?? parts[0]
        return CloudProvider(name: service, account: parts.count > 1 ? parts[1] : nil, root: folder)
    }
}

// MARK: - Partitions et nom

/// Une partition telle qu'elle est aujourd'hui sur un disque (`diskutil list`).
public struct PartitionInfo: Sendable, Hashable, Identifiable {
    public var id: String { identifier }
    public let identifier: String
    public let name: String?
    public let size: Int64
    /// « Apple_APFS », « Microsoft Basic Data », « EFI »…
    public let content: String
}

/// Un disque entier : sa taille, ses partitions d'aujourd'hui et tout ce qui
/// en est monté (volumes APFS du conteneur synthétisé compris).
public struct DiskLayout: Sendable, Hashable {
    public let size: Int64
    public let partitions: [PartitionInfo]
    public let mountPoints: [String]

    public init(size: Int64, partitions: [PartitionInfo], mountPoints: [String]) {
        self.size = size
        self.partitions = partitions
        self.mountPoints = mountPoints
    }
}

extension DiskInfo {

    /// Le disque entier, pour montrer ce qui sera effacé et répartir la place.
    public static func layout(of wholeDisk: String) async -> DiskLayout? {
        let result = await Command.run("/usr/sbin/diskutil", ["list", "-plist", wholeDisk], timeout: 10)
        guard result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]], let disk = disks.first else { return nil }
        return DiskLayout(size: (disk["Size"] as? NSNumber)?.int64Value ?? 0, partitions: parsePartitions(disk),
                          mountPoints: mountPoints(in: disks))
    }

    /// Chaque point de montage, à toute profondeur : un disque APFS range ses
    /// volumes dans le conteneur synthétisé, pas dans ses partitions.
    static func mountPoints(in object: Any) -> [String] {
        var found: [String] = []
        var stack: [Any] = [object]
        while let next = stack.popLast() {
            if let dictionary = next as? [String: Any] {
                if let point = dictionary["MountPoint"] as? String, !point.isEmpty { found.append(point) }
                stack.append(contentsOf: dictionary.values)
            } else if let array = next as? [Any] {
                stack.append(contentsOf: array)
            }
        }
        return Array(Set(found)).sorted()
    }

    static func parsePartitions(_ disk: [String: Any]) -> [PartitionInfo] {
        (disk["Partitions"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let identifier = entry["DeviceIdentifier"] as? String else { return nil }
            let content = entry["Content"] as? String ?? ""
            // La partition EFI, que macOS gère seul, n'apprend rien à personne.
            if content == "EFI" { return nil }
            let size = (entry["Size"] as? NSNumber)?.int64Value ?? 0
            let name = (entry["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return PartitionInfo(identifier: identifier, name: name, size: size, content: content)
        }
    }

    /// Renomme un volume (rien n'est effacé). Rend le message de macOS en cas d'échec.
    public static func rename(_ details: DiskDetails, to name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard isValidVolumeName(trimmed, format: details.format) else { return "invalid" }
        let result = await Command.run("/usr/sbin/diskutil", ["rename", details.deviceIdentifier, trimmed], timeout: 30)
        guard result.succeeded else {
            let message = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Les noms que chaque système de fichiers accepte : 11 caractères simples
    /// pour FAT et exFAT, 255 ailleurs ; rien qui passe pour une option ou un chemin.
    public static func isValidVolumeName(_ name: String, format: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("/"), !name.contains(":") else { return false }
        let lowered = format.lowercased()
        if lowered.contains("fat") || lowered.contains("ms-dos") {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-"))
            return name.count <= 11 && name.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
        }
        return name.count <= 255 && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
