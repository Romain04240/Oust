import Foundation
import Testing
@testable import OustClean
import OustVolume

@Suite("Formater : les gardes")
struct DiskEraserTests {
    private func disk(isInternal: Bool = false, ejectable: Bool = true, whole: String = "disk4") -> DiskDetails {
        DiskDetails(format: "ExFAT", busProtocol: "USB", mediaName: "Clé", isInternal: isInternal, isEjectable: ejectable,
                    isRemovableMedia: false, isEncrypted: false, isWritable: true, isSolidState: true,
                    deviceIdentifier: "\(whole)s1", wholeDisk: whole, mountPoint: "/Volumes/CLE")
    }

    @Test("Un disque interne ou le disque de démarrage ne se formatent jamais")
    func refusesInternal() {
        #expect(DiskEraser.refusal(for: disk(isInternal: true), format: .exfat, name: "CLE", startupWholeDisk: "disk0") == .notExternal)
        #expect(DiskEraser.refusal(for: disk(ejectable: false), format: .exfat, name: "CLE", startupWholeDisk: "disk0") == .notExternal)
        #expect(DiskEraser.refusal(for: disk(whole: "disk0"), format: .exfat, name: "CLE", startupWholeDisk: "disk0") == .startupDisk)
        #expect(DiskEraser.refusal(for: disk(), format: .exfat, name: "CLE", startupWholeDisk: "disk0") == nil)
    }

    @Test("Un identifiant de disque inattendu n'entre jamais dans la commande")
    func refusesOddIdentifiers() {
        #expect(DiskEraser.refusal(for: disk(whole: "disk4; rm -rf ~"), format: .apfs, name: "Sauvegardes",
                                   startupWholeDisk: "disk0") == .changed)
        #expect(DiskEraser.refusal(for: disk(whole: "disk4s2"), format: .apfs, name: "Sauvegardes",
                                   startupWholeDisk: "disk0") == .changed)
    }

    @Test("Les noms suivent les limites du format", arguments: [
        (EraseFormat.fat32, "PHOTOS 2026", true), (.fat32, "beaucoup trop long", false), (.exfat, "Clé", false),
        (.exfat, "-rf", false), (.apfs, "Sauvegardes de Romain", true), (.apfs, "a/b", false), (.apfs, "", false),
    ])
    func names(format: EraseFormat, name: String, valid: Bool) {
        #expect(DiskEraser.isValid(name: format.normalizedName(name), for: format) == valid)
    }

    @Test("Les arguments de diskutil sont fixés : format, nom, schéma, disque entier")
    func arguments() {
        #expect(DiskEraser.arguments(wholeDisk: "disk4", format: .fat32, name: "photos") ==
                ["eraseDisk", "MS-DOS FAT32", "PHOTOS", "MBR", "/dev/disk4"])
        #expect(DiskEraser.arguments(wholeDisk: "disk5", format: .apfs, name: "Archives") ==
                ["eraseDisk", "APFS", "Archives", "GPT", "/dev/disk5"])
    }

    // MARK: Partitions

    private let terabyte: Int64 = 2_000_000_000_000

    private func plan(_ sizes: [Int64?], formats: [EraseFormat]? = nil) -> [PartitionSpec] {
        sizes.enumerated().map { index, size in
            PartitionSpec(name: "PART\(index + 1)", format: formats?[index] ?? .exfat, size: size)
        }
    }

    @Test("Un plan de partitions tient sur le disque, la dernière prend le reste")
    func validPlans() {
        #expect(DiskEraser.refusal(for: disk(), scheme: .gpt, partitions: plan([nil]), diskSize: terabyte,
                                   startupWholeDisk: "disk0") == nil)
        #expect(DiskEraser.refusal(for: disk(), scheme: .gpt, partitions: plan([500_000_000_000, nil]), diskSize: terabyte,
                                   startupWholeDisk: "disk0") == nil)
    }

    @Test("Un plan qui déborde, une partition minuscule ou un « reste » au milieu sont refusés")
    func invalidPlans() {
        let refusals = [
            plan([]),
            plan([2_500_000_000_000, nil]),
            plan([1_999_500_000_000, nil]),
            plan([100_000_000, nil]),
            plan([nil, 500_000_000_000]),
            plan(Array(repeating: 10_000_000_000, count: 8) + [nil]),
        ].map { DiskEraser.refusal(for: disk(), scheme: .gpt, partitions: $0, diskSize: terabyte, startupWholeDisk: "disk0") }
        #expect(refusals.allSatisfy { $0 == .invalidPlan })
    }

    @Test("MBR : quatre partitions au plus, et jamais APFS")
    func mbrLimits() {
        #expect(DiskEraser.refusal(for: disk(), scheme: .mbr, partitions: plan([10_000_000_000, 10_000_000_000,
                                                                               10_000_000_000, 10_000_000_000, nil]),
                                   diskSize: terabyte, startupWholeDisk: "disk0") == .invalidPlan)
        #expect(DiskEraser.refusal(for: disk(), scheme: .mbr, partitions: plan([nil], formats: [.apfs]),
                                   diskSize: terabyte, startupWholeDisk: "disk0") == .invalidPlan)
        #expect(DiskEraser.refusal(for: disk(), scheme: .gpt, partitions: plan([nil], formats: [.apfs]),
                                   diskSize: terabyte, startupWholeDisk: "disk0") == nil)
    }

    @Test("Les gardes du formatage valent aussi pour les partitions")
    func partitionGuards() {
        #expect(DiskEraser.refusal(for: disk(isInternal: true), scheme: .gpt, partitions: plan([nil]), diskSize: terabyte,
                                   startupWholeDisk: "disk0") == .notExternal)
        #expect(DiskEraser.refusal(for: disk(whole: "disk0"), scheme: .gpt, partitions: plan([nil]), diskSize: terabyte,
                                   startupWholeDisk: "disk0") == .startupDisk)
        #expect(DiskEraser.refusal(for: disk(whole: "disk4 disk0"), scheme: .gpt, partitions: plan([nil]),
                                   diskSize: terabyte, startupWholeDisk: "disk0") == .changed)
        let longName = [PartitionSpec(name: "beaucoup trop long", format: .fat32, size: nil)]
        #expect(DiskEraser.refusal(for: disk(), scheme: .mbr, partitions: longName, diskSize: terabyte,
                                   startupWholeDisk: "disk0") == .invalidName)
    }

    @Test("Les arguments de partitionDisk : schéma, puis format, nom et taille de chaque partition")
    func partitionArguments() {
        let partitions = [
            PartitionSpec(name: "Mac", format: .apfs, size: 500_000_000_000),
            PartitionSpec(name: "photos", format: .fat32, size: nil),
        ]
        #expect(DiskEraser.partitionArguments(wholeDisk: "disk4", scheme: .gpt, partitions: partitions) ==
                ["partitionDisk", "/dev/disk4", "2", "GPT", "APFS", "Mac", "500000M", "MS-DOS FAT32", "PHOTOS", "R"])
    }

    @Test("Sur une petite clé, des partitions de quelques dizaines de Mo restent possibles")
    func smallDisks() {
        let key: Int64 = 419_000_000
        #expect(DiskEraser.minimumPartitionSize(forDisk: key) == 32_000_000)
        #expect(DiskEraser.minimumPartitionSize(forDisk: terabyte) == 1_000_000_000)
        #expect(DiskEraser.refusal(for: disk(), scheme: .gpt, partitions: plan([nil]), diskSize: key,
                                   startupWholeDisk: "disk0") == nil)
        #expect(DiskEraser.refusal(for: disk(), scheme: .gpt, partitions: plan([200_000_000, nil]), diskSize: key,
                                   startupWholeDisk: "disk0") == nil)
        #expect(DiskEraser.refusal(for: disk(), scheme: .gpt, partitions: plan([10_000_000, nil]), diskSize: key,
                                   startupWholeDisk: "disk0") == .invalidPlan)
        #expect(DiskEraser.refusal(for: disk(), scheme: .gpt, partitions: plan([400_000_000, nil]), diskSize: key,
                                   startupWholeDisk: "disk0") == .invalidPlan)
    }
}
