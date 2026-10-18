import Darwin
import Foundation
import OustCore

/// Le volume qui reçoit les archives.
public struct ArchiveDestination: Sendable, Hashable {
    public let volumeURL: URL
    public let name: String
    /// `apfs`, `hfs`, `exfat`, `msdos`, `ntfs`, `smbfs`… tel que `statfs` le nomme.
    public let fileSystem: String
    public let available: Int64
    public let isReadOnly: Bool
    public let isLocal: Bool
    public let device: Int32

    public init(volumeURL: URL, name: String, fileSystem: String, available: Int64, isReadOnly: Bool,
                isLocal: Bool, device: Int32) {
        self.volumeURL = volumeURL
        self.name = name
        self.fileSystem = fileSystem
        self.available = available
        self.isReadOnly = isReadOnly
        self.isLocal = isLocal
        self.device = device
    }

    /// Lit ce que le système dit du volume qui contient `url`.
    public static func inspect(_ url: URL) -> ArchiveDestination? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let fileSystem = withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let mountPoint = withUnsafeBytes(of: &info.f_mntonname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        let volume = URL(fileURLWithPath: mountPoint, isDirectory: true)
        let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? volume.lastPathComponent
        let available = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
            .map(Int64.init) ?? Int64(info.f_bavail) * Int64(info.f_bsize)
        return ArchiveDestination(
            volumeURL: volume, name: name, fileSystem: fileSystem.lowercased(), available: available,
            isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0, isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0,
            device: status.st_dev
        )
    }

    /// Ce qu'on dit du système de fichiers avant d'archiver dessus.
    public var advice: FileSystemAdvice {
        switch fileSystem {
        case "apfs": .recommended
        case "hfs": .acceptable
        case "exfat": .warning(.exfat)
        case "msdos": .warning(.fat)
        case "smbfs", "afpfs", "nfs", "webdav": .warning(.network)
        default: .warning(.unknown)
        }
    }

    /// Les noms de fichier `._…` que macOS crée pour garder les attributs
    /// étendus sur un volume qui ne sait pas les stocker.
    public var storesAppleDouble: Bool {
        ["exfat", "msdos", "smbfs", "webdav"].contains(fileSystem)
    }
}

/// APFS conseillé, le reste fonctionne avec des réserves qu'on dit avant.
public enum FileSystemAdvice: Sendable, Hashable {
    case recommended
    case acceptable
    case warning(FileSystemWarning)
}

public enum FileSystemWarning: String, Sendable, Hashable {
    /// Ni permissions ni propriétaire ; les attributs étendus deviennent des
    /// fichiers `._` ; dates au centième de seconde.
    case exfat
    /// FAT32 : en plus, pas de fichier de 4 Go ou plus.
    case fat
    /// Un volume réseau : la vérification relit à travers le réseau, et une
    /// coupure laisse une copie inachevée.
    case network
    case unknown

    public var localizationKey: String { "archive.fs_warning.\(rawValue)" }
}

/// Ce qui interdit d'archiver vers ce volume.
public enum DestinationRefusal: Sendable, Hashable {
    case readOnly
    /// Archiver sur le disque qu'on veut libérer ne libère rien.
    case sameVolume
    case notEnoughSpace(needed: Int64, available: Int64)
    /// FAT32 refuse les fichiers de 4 Go et plus.
    case fileTooLarge(name: String)

    public var localizationKey: String {
        switch self {
        case .readOnly: "archive.refusal.readOnly"
        case .sameVolume: "archive.refusal.sameVolume"
        case .notEnoughSpace: "archive.refusal.notEnoughSpace"
        case .fileTooLarge: "archive.refusal.fileTooLarge"
        }
    }
}

extension ArchiveDestination {
    /// Les raisons de refuser ce volume pour ces projets, d'après des faits
    /// déjà mesurés : `logicalBytes` (ce qu'il faudra écrire, la taille logique et
    /// non allouée, car rien n'est compressé ni partagé sur le volume d'arrivée)
    /// et le plus gros fichier.
    public func refusals(sourceDevices: Set<Int32>, logicalBytes: Int64,
                         largestFile: (name: String, size: Int64)?) -> [DestinationRefusal] {
        var refusals: [DestinationRefusal] = []
        if isReadOnly { refusals.append(.readOnly) }
        if sourceDevices.contains(device) { refusals.append(.sameVolume) }
        // Une marge de 2 % : les blocs du volume d'arrivée arrondissent chaque fichier.
        let needed = logicalBytes + logicalBytes / 50
        if needed > available { refusals.append(.notEnoughSpace(needed: needed, available: available)) }
        if fileSystem == "msdos", let largestFile, largestFile.size >= 4 * 1024 * 1024 * 1024 {
            refusals.append(.fileTooLarge(name: largestFile.name))
        }
        return refusals
    }
}
