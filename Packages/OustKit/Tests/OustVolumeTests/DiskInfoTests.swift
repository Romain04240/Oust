import Foundation
import Testing
@testable import OustVolume

@Suite("Ce que dit diskutil, et les nuages")
struct DiskInfoTests {
    @Test("Un volume APFS externe se rattache à son disque physique, pas au disque synthétisé")
    func parsesExternalAPFS() throws {
        let info: [String: Any] = [
            "DeviceIdentifier": "disk5s1", "ParentWholeDisk": "disk5", "FilesystemUserVisibleName": "APFS",
            "BusProtocol": "USB", "Internal": false, "Ejectable": true, "RemovableMedia": false,
            "Encryption": false, "WritableVolume": true, "MountPoint": "/Volumes/Archives", "MediaName": "Samsung T7",
        ]
        let details = try #require(DiskInfo.parse(info, physicalWholeDisk: "disk4"))
        #expect(details.wholeDisk == "disk4")
        #expect(details.isExternal)
        #expect(details.mediaName == "Samsung T7")
    }

    @Test("Sans indication, un disque est tenu pour interne : on ne propose pas de le formater")
    func defaultsToInternal() throws {
        let details = try #require(DiskInfo.parse(["DeviceIdentifier": "disk9s1", "ParentWholeDisk": "disk9"],
                                                  physicalWholeDisk: nil))
        #expect(!details.isExternal)
    }

    @Test("Le nom d'un File Provider vient de son dossier")
    func providerNames() {
        let drive = CloudProviders.provider(URL(fileURLWithPath: "/tmp/CloudStorage/GoogleDrive-romain@exemple.fr"))
        #expect(drive.name == "Google Drive")
        #expect(drive.account == "romain@exemple.fr")
        let dropbox = CloudProviders.provider(URL(fileURLWithPath: "/tmp/CloudStorage/Dropbox"))
        #expect(dropbox.name == "Dropbox")
        #expect(dropbox.account == nil)
    }

    @Test("Les partitions d'un disque, sans la partition EFI")
    func partitions() {
        let disk: [String: Any] = ["DeviceIdentifier": "disk7", "Size": 2_000_398_934_016, "Partitions": [
            ["DeviceIdentifier": "disk7s1", "Content": "EFI", "Size": 209_715_200, "VolumeName": "EFI"],
            ["DeviceIdentifier": "disk7s2", "Content": "Microsoft Basic Data", "Size": 2_000_189_177_856,
             "VolumeName": "Romain", "MountPoint": "/Volumes/Romain"],
        ]]
        let partitions = DiskInfo.parsePartitions(disk)
        #expect(partitions.map(\.identifier) == ["disk7s2"])
        #expect(partitions.first?.name == "Romain")
        #expect(partitions.first?.content == "Microsoft Basic Data")
    }

    @Test("Les volumes d'un conteneur APFS comptent parmi les points de montage du disque")
    func mountPoints() {
        let disks: [[String: Any]] = [
            ["DeviceIdentifier": "disk4", "Partitions": [["DeviceIdentifier": "disk4s2", "Content": "Apple_APFS"]]],
            ["DeviceIdentifier": "disk5", "APFSVolumes": [
                ["DeviceIdentifier": "disk5s1", "MountPoint": "/Volumes/Archives"],
                ["DeviceIdentifier": "disk5s2", "MountPoint": "/Volumes/Photos"],
                ["DeviceIdentifier": "disk5s3"],
            ]],
        ]
        #expect(DiskInfo.mountPoints(in: disks) == ["/Volumes/Archives", "/Volumes/Photos"])
    }

    @Test("Un nouveau nom suit les limites de son format", arguments: [
        ("Romain", "ExFAT", true), ("Un nom bien trop long", "ExFAT", false), ("Clé", "MS-DOS (FAT32)", false),
        ("Sauvegardes de Romain", "APFS", true), ("-rf", "APFS", false), ("a:b", "Mac OS étendu (journalisé)", false),
        ("", "APFS", false),
    ])
    func volumeNames(name: String, format: String, valid: Bool) {
        #expect(DiskInfo.isValidVolumeName(name, format: format) == valid)
    }
}
