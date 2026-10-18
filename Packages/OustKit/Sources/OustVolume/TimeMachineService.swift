import Foundation
import OustCore
import OustHelperContract

/// Une sauvegarde terminée sur un disque Time Machine.
public struct TimeMachineBackup: Sendable, Hashable, Identifiable, Comparable {
    /// `AAAA-MM-JJ-HHMMSS`, tel que `tmutil` le donne et l'attend.
    public let timestamp: String
    public var id: String { timestamp }

    public init?(timestamp: String) {
        guard TimeMachineBackups.isValidTimestamp(timestamp) else { return nil }
        self.timestamp = timestamp
    }

    /// À l'heure du Mac, comme Time Machine nomme ses sauvegardes.
    public var date: Date? { TimeMachineBackups.date(of: timestamp) }

    public static func < (lhs: TimeMachineBackup, rhs: TimeMachineBackup) -> Bool {
        lhs.timestamp < rhs.timestamp
    }
}

/// Un disque Time Machine branché, tel qu'on vient de le lire.
public struct TimeMachineDestination: Sendable, Equatable, Identifiable {
    public let id: String
    /// Le nom que Time Machine lui donne (celui du volume).
    public let name: String
    public let mountPoint: String
    /// Du plus ancien au plus récent.
    public let backups: [TimeMachineBackup]
    /// Une sauvegarde est en cours, ou l'état ne se lit pas.
    public let isBackupRunning: Bool

    public init(id: String, name: String, mountPoint: String, backups: [TimeMachineBackup], isBackupRunning: Bool) {
        self.id = id
        self.name = name
        self.mountPoint = mountPoint
        self.backups = backups.sorted()
        self.isBackupRunning = isBackupRunning
    }

    /// La plus récente : jamais proposée.
    public var latest: TimeMachineBackup? { backups.last }
}

/// Ce que l'on sait des sauvegardes d'un volume, à l'instant.
public enum TimeMachineListing: Sendable, Equatable {
    /// Ce volume n'est pas une destination Time Machine locale de ce Mac.
    case notADestination
    /// C'en est une, mais la liste ne se lit pas : on n'affiche rien plutôt
    /// qu'une liste fausse (règle 3).
    case unreadable(mountPoint: String)
    case listed(TimeMachineDestination)
}

/// Pourquoi rien n'a été supprimé.
public enum BackupDeletionRefusal: Sendable, Equatable {
    /// Time Machine sauvegarde en ce moment (ou son état ne se lit pas).
    case backupRunning
    /// Le point de montage n'est plus celui d'une destination Time Machine.
    case unknownDestination
    /// L'invite administrateur a été refusée ou annulée.
    case cancelled
    /// Le démon n'a pas répondu à temps : il travaille peut-être encore.
    case timedOut
    case failed(message: String)
}

/// Ce que la suppression a donné, avant de relire la liste.
public struct BackupDeletionReply: Sendable, Equatable {
    public enum Path: Sendable, Equatable {
        case helper
        case administrator
    }

    public var path: Path?
    public var refusal: BackupDeletionRefusal?
    /// Ce que `tmutil` a dit, horodatage par horodatage, quand le démon l'a
    /// rapporté.
    public var messages: [String: String]

    public init(path: Path? = nil, refusal: BackupDeletionRefusal? = nil, messages: [String: String] = [:]) {
        self.path = path
        self.refusal = refusal
        self.messages = messages
    }
}

/// Les sauvegardes d'un disque Time Machine : les lire, en supprimer
/// (Romain, 18/10/2026).
///
/// La lecture ne demande rien. La suppression passe par le démon privilégié
/// s'il est installé et à jour, sinon par une invite administrateur ; elle
/// n'est appelée que par `BackupPruner` (OustClean, règle 1), qui revalide
/// avant et relit la liste après.
public enum TimeMachineService {

    static let tmutil = "/usr/bin/tmutil"

    /// Les destinations configurées dans Time Machine ; nil si illisible.
    static func destinations() async -> [TimeMachineBackups.Destination]? {
        let result = await Command.run(tmutil, ["destinationinfo", "-X"], timeout: 15)
        guard result.succeeded else { return nil }
        return TimeMachineBackups.destinations(inDestinationInfo: result.stdout)
    }

    /// Une sauvegarde est-elle en cours ? Illisible : oui (règle 3).
    public static func isBackupRunning() async -> Bool {
        let result = await Command.run(tmutil, ["status", "-X"], timeout: 15)
        guard result.succeeded else { return true }
        return TimeMachineBackups.isRunning(statusPlist: result.stdout) ?? true
    }

    /// Les sauvegardes terminées de la destination montée là ; nil si la
    /// liste ne se lit pas.
    public static func backups(at mountPoint: String) async -> [TimeMachineBackup]? {
        guard TimeMachineBackups.isPlausibleMountPoint(mountPoint) else { return nil }
        // Sans `-m`, qui monterait chaque sauvegarde pour en donner le chemin.
        let result = await Command.run(tmutil, ["listbackups", "-d", mountPoint], timeout: 120)
        guard result.succeeded else { return nil }
        return TimeMachineBackups.timestamps(inListing: result.output).compactMap(TimeMachineBackup.init(timestamp:))
    }

    /// Ce volume est-il un disque Time Machine, et que contient-il ?
    public static func listing(of volume: URL) async -> TimeMachineListing {
        guard let destinations = await destinations() else { return .notADestination }
        let path = TimeMachineBackups.normalized(volume.path)
        guard let destination = destinations.first(where: { $0.isEligible && $0.mountPoint == path }) else {
            return .notADestination
        }
        async let running = isBackupRunning()
        guard let backups = await backups(at: path) else { return .unreadable(mountPoint: path) }
        return .listed(TimeMachineDestination(id: destination.id, name: destination.name, mountPoint: path,
                                              backups: backups, isBackupRunning: await running))
    }

    // MARK: Suppression

    /// Supprime ces sauvegardes : par le démon s'il est installé et à jour,
    /// sinon après une invite administrateur.
    ///
    /// Ce qui a vraiment disparu ne se lit pas ici mais dans la liste relue
    /// après coup, par `BackupPruner` : `tmutil` qui rend 0 n'est pas une
    /// preuve, et l'invite ne dit rien horodatage par horodatage.
    public static func deleteBackups(_ timestamps: [String], at mountPoint: String) async -> BackupDeletionReply {
        await deleteBackups(timestamps, at: mountPoint, helper: { chunk, timeout in
            await PrivilegedHelper.deleteBackups(chunk, destination: mountPoint, timeout: timeout)
        }, administrator: { chunk in
            await runAsAdministrator(chunk, at: mountPoint)
        })
    }

    /// Le cœur, avec le démon et l'invite remplaçables : c'est ce que les
    /// tests exercent.
    static func deleteBackups(
        _ timestamps: [String], at mountPoint: String,
        helper: ([String], TimeInterval) async -> PrivilegedHelper.Call<BackupDeletionResponse>,
        administrator: ([String]) async -> BackupDeletionRefusal?
    ) async -> BackupDeletionReply {
        guard TimeMachineBackups.isPlausibleMountPoint(mountPoint) else {
            return BackupDeletionReply(refusal: .unknownDestination)
        }
        let valid = timestamps.filter(TimeMachineBackups.isValidTimestamp)
        guard !valid.isEmpty, valid.count == timestamps.count else {
            return BackupDeletionReply(refusal: .failed(message: "malformed"))
        }
        var reply = BackupDeletionReply()
        var start = 0
        while start < valid.count {
            let chunk = Array(valid[start..<min(valid.count, start + TimeMachineBackups.maximumPerRequest)])
            start += chunk.count
            // Une sauvegarde APFS part en quelques secondes ; on laisse large.
            let timeout = min(4 * 3_600, 600 + 120 * TimeInterval(chunk.count))
            switch await helper(chunk, timeout) {
            case .answered(let response):
                switch response.refusal {
                case nil:
                    reply.path = .helper
                    for result in response.results where result.outcome != .deleted {
                        reply.messages[result.timestamp] = result.message ?? result.outcome.rawValue
                    }
                    if response.results.contains(where: { $0.outcome == .backupRunning }) {
                        reply.refusal = .backupRunning
                        return reply
                    }
                    continue
                case .backupRunning?:
                    reply.refusal = .backupRunning
                    return reply
                case .unknownDestination?:
                    reply.refusal = .unknownDestination
                    return reply
                // Rien n'a été fait : une autre version de contrat, ou une
                // liste que le démon n'a pas pu lire (il n'a peut-être pas
                // l'Accès complet au disque, que `tmutil` exige). L'invite,
                // lancée depuis Oust!, prend le relais.
                case .contractMismatch?, .listingFailed?, .empty?, .tooMany?:
                    break
                }
            case .timedOut:
                reply.refusal = .timedOut
                return reply
            case .unreachable:
                break
            }
            reply.path = .administrator
            if let refusal = await administrator(chunk) {
                reply.refusal = refusal
                return reply
            }
        }
        return reply
    }

    /// Les arguments d'`osascript` pour supprimer ces sauvegardes en
    /// administrateur.
    ///
    /// Construits ici, et testés, parce qu'ils partent en root (règle 7). Le
    /// point de montage n'entre jamais dans le texte du script : il arrive en
    /// argument (`item 1 of argv`) et passe par `quoted form of`, qui le
    /// protège du shell quel que soit son nom. Les horodatages, eux, ont été
    /// validés chiffre par chiffre et s'écrivent tels quels. Nil si un seul
    /// argument n'a pas la forme attendue : rien ne part.
    static func administratorArguments(for timestamps: [String], at mountPoint: String) -> [String]? {
        guard TimeMachineBackups.isPlausibleMountPoint(mountPoint), !timestamps.isEmpty,
              timestamps.count <= TimeMachineBackups.maximumPerRequest,
              timestamps.allSatisfy(TimeMachineBackups.isValidTimestamp) else { return nil }
        let flags = timestamps.map { " -t \($0)" }.joined()
        let command = "\"\(tmutil) delete -d \" & quoted form of (item 1 of argv) & \"\(flags)\""
        return ["-e", "on run argv",
                "-e", "do shell script \(command) with administrator privileges",
                "-e", "end run",
                mountPoint]
    }

    static func runAsAdministrator(_ timestamps: [String], at mountPoint: String) async -> BackupDeletionRefusal? {
        guard let arguments = administratorArguments(for: timestamps, at: mountPoint) else {
            return .failed(message: "malformed")
        }
        // La saisie du mot de passe compte dans le délai ; une sauvegarde HFS+
        // peut demander longtemps.
        let result = await Command.run("/usr/bin/osascript", arguments, timeout: 7_200)
        if result.succeeded { return nil }
        let said = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        // -128 : « User canceled. », l'invite fermée sans mot de passe.
        if said.contains("-128") { return .cancelled }
        return .failed(message: said.isEmpty ? "osascript \(result.status)" : String(said.prefix(300)))
    }
}
