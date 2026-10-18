import Foundation
import OustCore
import OustSafety
import OustVolume

/// Les formats que macOS sait créer seul. ext4 et NTFS demanderaient un outil
/// tiers (RULES.md, règle 12) : l'interface le dit au lieu de les promettre.
public enum EraseFormat: String, CaseIterable, Sendable, Identifiable {
    case apfs, macExtended, exfat, fat32

    public var id: String { rawValue }
    public var localizationKey: String { "erase.format.\(rawValue)" }

    /// La personnalité que `diskutil` attend.
    var personality: String {
        switch self {
        case .apfs: "APFS"
        case .macExtended: "JHFS+"
        case .exfat: "ExFAT"
        case .fat32: "MS-DOS FAT32"
        }
    }

    /// GUID pour les formats Mac ; MBR pour exFAT et FAT32, que lisent aussi les
    /// vieux PC, les téléviseurs et les appareils photo.
    var scheme: String {
        switch self {
        case .apfs, .macExtended: "GPT"
        case .exfat, .fat32: "MBR"
        }
    }

    /// La longueur maximale du nom du volume.
    public var maximumNameLength: Int {
        switch self {
        case .apfs, .macExtended: 255
        case .exfat, .fat32: 11
        }
    }

    /// Le nom tel que le format le gardera (FAT32 : majuscules).
    public func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return self == .fat32 ? trimmed.uppercased() : trimmed
    }
}

/// Pourquoi Oust! refuse de formater.
public enum EraseRefusal: Error, Sendable, Equatable {
    /// Disque interne, ou le disque de démarrage : jamais.
    case notExternal
    case startupDisk
    /// Une application y garde des fichiers ouverts.
    case inUse(names: [String])
    case invalidName
    /// Les tailles ne tiennent pas sur le disque, ou trop de partitions.
    case invalidPlan
    /// Le disque a changé depuis qu'on l'a montré (débranché, rebranché…).
    case changed
    case failed(message: String)

    public var localizationKey: String {
        switch self {
        case .notExternal: "erase.refusal.not_external"
        case .startupDisk: "erase.refusal.startup"
        case .inUse: "erase.refusal.in_use"
        case .invalidName: "erase.refusal.name"
        case .invalidPlan: "erase.refusal.plan"
        case .changed: "erase.refusal.changed"
        case .failed: "erase.refusal.failed"
        }
    }
}

/// Formater un disque externe : la seule suppression d'Oust! sans corbeille,
/// demandée par Romain le 18/10/2026 et entourée de gardes. Elle passe ici,
/// dans OustClean, comme toute suppression (RULES.md, règle 1), par la commande
/// de l'outil (règle 6) et sans élévation.
public enum DiskEraser {

    /// Les vérifications, sans rien toucher. `startupWholeDisk` : le disque
    /// physique qui porte le système.
    public static func refusal(for details: DiskDetails, format: EraseFormat, name: String,
                               startupWholeDisk: String?) -> EraseRefusal? {
        guard details.isExternal else { return .notExternal }
        guard details.wholeDisk != startupWholeDisk else { return .startupDisk }
        guard details.wholeDisk.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { return .changed }
        guard isValid(name: format.normalizedName(name), for: format) else { return .invalidName }
        return nil
    }

    public static func isValid(name: String, for format: EraseFormat) -> Bool {
        guard !name.isEmpty, name.count <= format.maximumNameLength else { return false }
        // Rien qui puisse passer pour une option de diskutil ou un chemin.
        guard !name.hasPrefix("-"), !name.contains("/"), !name.contains(":") else { return false }
        if format == .fat32 || format == .exfat {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-"))
            return name.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
        }
        return name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// Les arguments de `diskutil`, fixés ici et nulle part ailleurs.
    static func arguments(wholeDisk: String, format: EraseFormat, name: String) -> [String] {
        ["eraseDisk", format.personality, format.normalizedName(name), format.scheme, "/dev/\(wholeDisk)"]
    }

    /// Ce qui garde un fichier ouvert sur l'un des volumes du disque entier, et
    /// pas seulement sur celui qu'on a cliqué : tout le disque sera effacé.
    static func busyApplications(on details: DiskDetails) async -> [String]? {
        var points = Set(await DiskInfo.layout(of: details.wholeDisk)?.mountPoints ?? [])
        points.insert(details.mountPoint)
        let holders = points.filter { !$0.isEmpty }.flatMap { OpenFiles.holders(under: $0) }
        return holders.isEmpty ? nil : Array(Set(holders.map(\.name))).sorted()
    }

    /// Revalide juste avant d'agir (le disque est toujours celui qu'on a montré,
    /// personne n'y garde de fichier ouvert), puis efface le disque entier.
    public static func erase(_ shown: DiskDetails, format: EraseFormat, name: String,
                             startupWholeDisk: String?) async -> EraseRefusal? {
        if let refusal = refusal(for: shown, format: format, name: name, startupWholeDisk: startupWholeDisk) {
            return refusal
        }
        guard let now = await DiskInfo.details(of: URL(fileURLWithPath: shown.mountPoint)),
              now.wholeDisk == shown.wholeDisk, now.deviceIdentifier == shown.deviceIdentifier else { return .changed }
        if let busy = await busyApplications(on: now) { return .inUse(names: busy) }
        let result = await Command.run("/usr/sbin/diskutil",
                                       arguments(wholeDisk: now.wholeDisk, format: format, name: name), timeout: 900)
        guard result.succeeded else {
            let message = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
            return .failed(message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

// MARK: - Partitions

/// Le schéma de partitionnement : GUID pour les Mac, MBR pour les vieux PC,
/// les téléviseurs et les appareils photo.
public enum PartitionScheme: String, CaseIterable, Sendable, Identifiable {
    case gpt, mbr
    public var id: String { rawValue }
    public var localizationKey: String { "partition.scheme.\(rawValue)" }
    var diskutilName: String { self == .gpt ? "GPT" : "MBR" }

    /// MBR ne connaît que quatre partitions principales.
    public var maximumPartitions: Int { self == .gpt ? DiskEraser.maximumPartitions : 4 }

    /// Les formats que le schéma accepte : APFS veut une table GUID.
    public var formats: [EraseFormat] { self == .gpt ? EraseFormat.allCases : [.macExtended, .exfat, .fat32] }
}

/// Une partition à créer.
public struct PartitionSpec: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var format: EraseFormat
    /// En octets ; nil : tout ce qui reste (la dernière seulement).
    public var size: Int64?

    public init(id: UUID = UUID(), name: String, format: EraseFormat, size: Int64?) {
        self.id = id
        self.name = name
        self.format = format
        self.size = size
    }
}

extension DiskEraser {
    /// Au plus huit partitions : au-delà, Utilitaire de disque.
    public static let maximumPartitions = 8
    /// La plus petite partition qui ait un sens, selon le disque : 1 Go sur un
    /// grand disque, un seizième d'une petite clé, jamais moins de 32 Mo (le
    /// plancher de FAT32). Fixée à 1 Go, elle refusait tout plan sur une clé de
    /// 419 Mo (« les tailles dépassent le disque de 581 Mo », 18/10/2026).
    public static func minimumPartitionSize(forDisk size: Int64) -> Int64 {
        min(1_000_000_000, max(32_000_000, size / 16))
    }

    /// Ce qui ne va pas dans un plan de partitions, sans rien toucher.
    public static func refusal(for details: DiskDetails, scheme: PartitionScheme, partitions: [PartitionSpec],
                               diskSize: Int64, startupWholeDisk: String?) -> EraseRefusal? {
        guard details.isExternal else { return .notExternal }
        guard details.wholeDisk != startupWholeDisk else { return .startupDisk }
        guard details.wholeDisk.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { return .changed }
        guard !partitions.isEmpty, partitions.count <= scheme.maximumPartitions,
              partitions.allSatisfy({ scheme.formats.contains($0.format) }) else { return .invalidPlan }
        guard partitions.allSatisfy({ isValid(name: $0.format.normalizedName($0.name), for: $0.format) }) else {
            return .invalidName
        }
        // Une seule partition « le reste », et en dernier.
        guard partitions.dropLast().allSatisfy({ $0.size != nil }) else { return .invalidPlan }
        let fixed = partitions.compactMap(\.size)
        let minimum = minimumPartitionSize(forDisk: diskSize)
        guard fixed.allSatisfy({ $0 >= minimum }) else { return .invalidPlan }
        let reserved = partitions.last?.size == nil ? minimum : 0
        guard fixed.reduce(0, +) + reserved <= diskSize else { return .invalidPlan }
        return nil
    }

    /// Les arguments de `diskutil partitionDisk`, fixés ici et nulle part ailleurs.
    static func partitionArguments(wholeDisk: String, scheme: PartitionScheme, partitions: [PartitionSpec]) -> [String] {
        var arguments = ["partitionDisk", "/dev/\(wholeDisk)", String(partitions.count), scheme.diskutilName]
        for partition in partitions {
            let size = partition.size.map { "\(max(1, $0 / 1_000_000))M" } ?? "R"
            arguments += [partition.format.personality, partition.format.normalizedName(partition.name), size]
        }
        return arguments
    }

    /// Efface le disque entier et le repartitionne, après les mêmes gardes que
    /// le formatage : revalidé juste avant d'agir, rien d'ouvert dessus.
    public static func partition(_ shown: DiskDetails, scheme: PartitionScheme, partitions: [PartitionSpec],
                                 diskSize: Int64, startupWholeDisk: String?) async -> EraseRefusal? {
        if let refusal = refusal(for: shown, scheme: scheme, partitions: partitions, diskSize: diskSize,
                                 startupWholeDisk: startupWholeDisk) {
            return refusal
        }
        guard let now = await DiskInfo.details(of: URL(fileURLWithPath: shown.mountPoint)),
              now.wholeDisk == shown.wholeDisk, now.deviceIdentifier == shown.deviceIdentifier else { return .changed }
        if let busy = await busyApplications(on: now) { return .inUse(names: busy) }
        let result = await Command.run("/usr/sbin/diskutil",
                                       partitionArguments(wholeDisk: now.wholeDisk, scheme: scheme, partitions: partitions),
                                       timeout: 1_800)
        guard result.succeeded else {
            let message = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
            return .failed(message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
