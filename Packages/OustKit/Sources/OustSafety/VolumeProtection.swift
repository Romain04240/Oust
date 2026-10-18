import Darwin
import Foundation

/// Ce qu'un disque porte et qu'Oust! ne touche jamais, où qu'il soit : les
/// dossiers que macOS tient à la racine de chaque volume, les sauvegardes
/// Time Machine, les photothèques, et, hors du disque de démarrage, les
/// machines virtuelles (demande de Romain, 18/10/2026 : analyser un disque
/// externe comme le disque principal, sans jamais y proposer ces éléments).
///
/// Partagé par la garde de chemins (`PathGuard`), qui refuse, et par les
/// chercheurs, qui ne descendent pas dedans et disent pourquoi.
public enum VolumeProtection {

    /// Les dossiers de service d'un volume : index Spotlight, journal FSEvents,
    /// versions des documents, fichiers temporaires, anciennes sauvegardes
    /// locales. Les supprimer casserait la recherche ou les versions, et
    /// n'apprendrait rien à l'utilisateur.
    public static let serviceFolders: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", ".MobileBackups",
        ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware",
    ]

    /// Le dossier des sauvegardes Time Machine sur un disque HFS+.
    public static let timeMachineFolder = "Backups.backupdb"

    /// Les sauvegardes Time Machine vers un disque réseau ou un disque partagé :
    /// toujours un paquet `.backupbundle` (macOS 11 et suivants), ou un
    /// `.sparsebundle` qui porte la marque de Time Machine (avant).
    public static let timeMachineBundleExtension = "backupbundle"

    /// Les marques qu'un `.sparsebundle` de Time Machine porte à sa racine.
    static let timeMachineSparseMarkers = [
        "com.apple.TimeMachine.MachineID.plist", "com.apple.TimeMachine.MachineID.bckup",
    ]

    /// Sur un volume APFS de destination, Time Machine nomme chaque sauvegarde
    /// d'après sa date : `2026-10-18-101500.backup`, `.previous`, `.inprogress`,
    /// `.interrupted`.
    static let timeMachineBackupSuffixes = [".backup", ".previous", ".inprogress", ".interrupted"]

    /// Les machines virtuelles : paquets (UTM, Parallels, VMware Fusion,
    /// VirtualBuddy) et images de disques nues (VirtualBox, QEMU, Hyper-V).
    public static let virtualMachinePackages: Set<String> = ["utm", "pvm", "vmwarevm", "vbvm", "macvm"]
    public static let virtualMachineDisks: Set<String> = ["vdi", "vmdk", "vhd", "vhdx", "qcow2", "hdd"]

    /// Ce qui ne vaut que sur le disque de démarrage : une machine virtuelle y
    /// est « à examiner » (règle `vm.image`), partout ailleurs elle est rangée.
    public static func isVirtualMachine(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return virtualMachinePackages.contains(ext) || virtualMachineDisks.contains(ext)
    }

    public static func isPhotoLibrary(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "photoslibrary"
    }

    /// Une sauvegarde Time Machine, d'après son seul nom (le dossier HFS+, un
    /// paquet `.backupbundle`, une sauvegarde datée d'un volume APFS).
    public static func isTimeMachineName(_ name: String) -> Bool {
        if name == timeMachineFolder { return true }
        if (name as NSString).pathExtension.lowercased() == timeMachineBundleExtension { return true }
        return isDatedBackup(name)
    }

    /// `2026-10-18-101500.previous` : la date exacte, pas un nom qui commence
    /// par un chiffre (« 2024 Photos.backup » est un dossier de l'utilisateur).
    static func isDatedBackup(_ name: String) -> Bool {
        guard let suffix = timeMachineBackupSuffixes.first(where: { name.hasSuffix($0) }) else { return false }
        let stem = Array(name.dropLast(suffix.count))
        guard stem.count == 17 else { return false }
        return stem.enumerated().allSatisfy { index, character in
            [4, 7, 10].contains(index) ? character == "-" : character.isASCII && character.isNumber
        }
    }

    /// Un `.sparsebundle` que Time Machine a créé : il porte ses marques.
    public static func isTimeMachineSparseBundle(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "sparsebundle" else { return false }
        return timeMachineSparseMarkers.contains { marker in
            var info = stat()
            return lstat(url.appendingPathComponent(marker).path, &info) == 0
        }
    }

    /// Un volume entier tenu par Time Machine, d'après ce qu'il porte à sa
    /// racine : des sauvegardes datées (APFS). Un disque HFS+ peut garder
    /// `Backups.backupdb` à côté d'autres dossiers : seul ce dossier est
    /// protégé. `tmutil destinationinfo` le dit aussi, quand le disque est
    /// connu de ce Mac.
    public static func looksLikeTimeMachineVolume(_ root: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.contains(where: isDatedBackup)
    }

    /// Le dossier de la corbeille du Mac à la racine d'un autre volume, et
    /// celui de l'utilisateur dedans (`.Trashes/<uid>`).
    public static let volumeTrashFolder = ".Trashes"

    public static func userTrash(on root: URL, userID: uid_t = getuid()) -> URL {
        root.appendingPathComponent(volumeTrashFolder, isDirectory: true)
            .appendingPathComponent(String(userID), isDirectory: true)
    }

    /// Les systèmes de fichiers de macOS. Sur les autres, macOS range les
    /// métadonnées dans des fichiers `._*` (AppleDouble) à côté de chaque fichier.
    public static func isAppleFileSystem(_ type: String) -> Bool {
        ["apfs", "hfs"].contains(type.lowercased())
    }
}
