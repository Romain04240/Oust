import Darwin
import Foundation
import Testing
@testable import OustSafety

/// Ce qu'un autre disque porte et que la garde refuse, quoi qu'en dise une
/// règle ou l'Explorateur (demande de Romain, 18/10/2026).
@Suite("La garde de chemins sur un autre disque")
struct VolumeGuardTests {

    @Test("Ce qui est sous /Volumes : racine, Applications, corbeille elle-même, service, Time Machine", arguments: [
        "/Volumes/Romain", "/Volumes/Romain/Applications", "/Volumes/Romain/.Trashes", "/Volumes/Romain/.Trashes/501",
        "/Volumes/Romain/.Spotlight-V100/Store-V2", "/Volumes/Romain/.fseventsd/0000", "/Volumes/Romain/.TemporaryItems",
        "/Volumes/Romain/.DocumentRevisions-V100/x", "/Volumes/Romain/Backups.backupdb/Mac/Latest",
        "/Volumes/NAS/Mac.backupbundle/bands/0", "/Volumes/TM/2026-10-18-101500.previous/Users",
        "/Volumes/.timemachine/ABCD/2026-10-18-101500.backup/x", "/Volumes/Romain/Archives/Famille.photoslibrary",
        "/Volumes/Romain/Archives/Famille.photoslibrary/originals/A/IMG.heic", "/Volumes/Romain/VM/Windows.utm",
        "/Volumes/Romain/VM/linux.vmdk", "/Volumes/Romain/VM/Parallels/Win.pvm/disk.hdd",
    ])
    func refuses(path: String) {
        #expect(PathGuard(home: URL(fileURLWithPath: "/Home/test")).allows(URL(fileURLWithPath: path)) == false)
    }

    @Test("Ce qu'on propose sur un disque", arguments: [
        "/Volumes/Romain/.Trashes/501/vieux film.mov", "/Volumes/Romain/Dev/site/node_modules",
        "/Volumes/Romain/Applications/Outil.app", "/Volumes/Romain/Photos 2019/._plage.jpg",
        "/Volumes/Romain/Photos 2019/.DS_Store", "/Volumes/Romain/2024 Photos.backup",
        "/Volumes/Romain/Montage/Resolve/CacheClip",
    ])
    func allows(path: String) {
        #expect(PathGuard(home: URL(fileURLWithPath: "/Home/test")).allows(URL(fileURLWithPath: path)))
    }

    @Test("Une machine virtuelle est à examiner sur le disque de démarrage, protégée ailleurs")
    func virtualMachines() throws {
        let scratch = try Scratch()
        let volume = scratch.root.appendingPathComponent("Disque")
        let home = scratch.root.appendingPathComponent("Maison")
        let guardian = PathGuard(home: home, otherVolumeRoots: [volume])
        #expect(guardian.allows(home.appendingPathComponent("Virtual Machines/Windows.utm")))
        #expect(!guardian.allows(volume.appendingPathComponent("VM/Windows.utm")))
        #expect(!guardian.allows(volume))
        #expect(!guardian.allows(volume.appendingPathComponent("Applications")))
        #expect(!guardian.allows(volume.appendingPathComponent(".Trashes/\(getuid())")))
        #expect(guardian.allows(volume.appendingPathComponent(".Trashes/\(getuid())/a.mov")))
        // Déjà jetées : la corbeille se vide, même avec une machine virtuelle ou
        // une photothèque dedans ; jamais avec une sauvegarde Time Machine.
        #expect(guardian.allows(volume.appendingPathComponent(".Trashes/\(getuid())/Windows.utm")))
        #expect(guardian.allows(volume.appendingPathComponent(".Trashes/\(getuid())/Vieille.photoslibrary")))
        #expect(guardian.allows(home.appendingPathComponent(".Trash/Vieille.photoslibrary")))
        #expect(!guardian.allows(volume.appendingPathComponent(".Trashes/\(getuid())/Backups.backupdb")))
    }

    @Test("Un .sparsebundle de Time Machine est refusé à ses marques ; un autre, non")
    func sparseBundles() throws {
        let scratch = try Scratch()
        try scratch.write("Mac.sparsebundle/com.apple.TimeMachine.MachineID.plist")
        try scratch.write("Mac.sparsebundle/bands/0")
        try scratch.write("Projet.sparsebundle/bands/0")
        let guardian = PathGuard(home: scratch.root.appendingPathComponent("Maison"))
        #expect(!guardian.allows(scratch.root.appendingPathComponent("Mac.sparsebundle")))
        #expect(!guardian.allows(scratch.root.appendingPathComponent("Mac.sparsebundle/bands/0")))
        #expect(guardian.allows(scratch.root.appendingPathComponent("Projet.sparsebundle")))
    }

    @Test("Un point de montage n'est jamais supprimé, où qu'il soit")
    func mountPoints() {
        #expect(PathGuard.isMountPoint("/System/Volumes/Data"))
        #expect(!PathGuard.isMountPoint("/System/Volumes/Data/private"))
        #expect(!PathGuard.isMountPoint("/n/existe/pas"))
    }

    @Test("Les sauvegardes datées de Time Machine, et elles seules", arguments: [
        ("2026-10-18-101500.previous", true), ("2026-10-18-101500.inprogress", true),
        ("2026-10-18-101500.backup", true), ("Backups.backupdb", true), ("Mac.backupbundle", true),
        ("2024 Photos.backup", false), ("2026-10-18.previous", false), ("notes.inprogress", false),
    ])
    func timeMachineNames(name: String, expected: Bool) {
        #expect(VolumeProtection.isTimeMachineName(name) == expected)
    }

    @Test("Un volume APFS de Time Machine se reconnaît à ses sauvegardes datées")
    func timeMachineVolume() throws {
        let scratch = try Scratch()
        try scratch.write("Sauvegarde/2026-10-18-101500.previous/x")
        try scratch.write("Données/2026 Projets/x")
        #expect(VolumeProtection.looksLikeTimeMachineVolume(scratch.root.appendingPathComponent("Sauvegarde")))
        #expect(!VolumeProtection.looksLikeTimeMachineVolume(scratch.root.appendingPathComponent("Données")))
    }
}
