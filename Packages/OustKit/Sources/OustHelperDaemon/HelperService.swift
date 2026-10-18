import Foundation
import OSLog
import OustHelperContract
import Synchronization

/// `oust-helper` — le démon privilégié d'Oust! (docs/adr/0001).
///
/// Ce qu'il fait, dans son intégralité :
///
/// 1. il n'accepte que des messages d'Oust!, signé par son équipe ;
/// 2. il supprime des snapshots Time Machine locaux désignés par leur date,
///    après avoir revalidé chaque date et vérifié qu'un snapshot
///    `com.apple.TimeMachine.<date>.local` existe bien ;
/// 3. il supprime des sauvegardes d'un disque Time Machine branché, désignées
///    par leur horodatage, après avoir relu la destination, l'état de Time
///    Machine et la liste des sauvegardes ; jamais la plus récente ;
/// 4. il dit sa version.
///
/// Ce qu'il ne fait pas : aucune commande reçue de l'extérieur, aucun chemin
/// sinon le point de montage d'une destination que `tmutil` lui confirme,
/// aucun accès réseau, aucune lecture ni écriture de fichier, aucun état
/// conservé d'une demande à l'autre. Il ne touche jamais aux snapshots de mise
/// à jour du système (`com.apple.os.update-…`).
public final class HelperService: NSObject, NSXPCListenerDelegate, OustHelperProtocol, Sendable {

    private let tool: any SnapshotTool
    private let backups: any BackupTool
    private let clientRequirement: String
    private let version: String
    /// Une demande à la fois : deux `tmutil` simultanés sur les mêmes
    /// snapshots se répondraient des erreurs l'un à l'autre.
    private let serial = Mutex(())
    private let activity: IdleMonitor?

    /// `clientRequirement` n'est remplacé que par les tests, pour vérifier que
    /// le mécanisme accepte bien ce qu'il doit accepter.
    public init(tool: any SnapshotTool,
                backups: any BackupTool = SystemBackupTool(),
                clientRequirement: String = HelperContract.clientRequirement,
                version: String = "0",
                activity: IdleMonitor? = nil) {
        self.tool = tool
        self.backups = backups
        self.clientRequirement = clientRequirement
        self.version = version
        self.activity = activity
    }

    // MARK: Connexions

    public func listener(_ listener: NSXPCListener,
                         shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Sans elle, n'importe quel processus local pourrait parler à un démon
        // root. Le système la vérifie à chaque message, sur le jeton d'audit de
        // l'appelant et non sur un PID qu'on peut réutiliser : un message qui
        // n'y satisfait pas invalide la connexion avant d'atteindre ce code.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = HelperInterface.make()
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: Verbes

    public func deleteLocalSnapshots(_ dates: [String], contractVersion: Int,
                                     withReply reply: @escaping @Sendable (NSDictionary) -> Void) {
        activity?.begin()
        defer { activity?.end() }
        let response = serial.withLock { _ in
            Self.handle(dates, contractVersion: contractVersion, tool: tool)
        }
        Self.log.notice("""
            snapshots : \(dates.count, privacy: .public) demandés, \
            \(response.results.filter { $0.outcome == .deleted }.count, privacy: .public) supprimés, \
            refus : \(response.refusal?.rawValue ?? "aucun", privacy: .public)
            """)
        reply(response.dictionary)
    }

    public func deleteBackups(_ timestamps: [String], destination: String, contractVersion: Int,
                              withReply reply: @escaping @Sendable (NSDictionary) -> Void) {
        activity?.begin()
        defer { activity?.end() }
        let response = serial.withLock { _ in
            Self.handleBackups(timestamps, destination: destination, contractVersion: contractVersion, tool: backups)
        }
        Self.log.notice("""
            sauvegardes : \(timestamps.count, privacy: .public) demandées, \
            \(response.deleted.count, privacy: .public) supprimées, \
            refus : \(response.refusal?.rawValue ?? "aucun", privacy: .public)
            """)
        reply(response.dictionary)
    }

    public func readStatus(withReply reply: @escaping @Sendable (NSDictionary) -> Void) {
        activity?.begin()
        defer { activity?.end() }
        reply(HelperStatus(helperVersion: version).dictionary)
    }

    // MARK: Décision

    /// Ce que le démon fait d'une demande, sans XPC autour : c'est ce que les
    /// tests exercent.
    ///
    /// L'ordre compte. Une demande d'une autre version de contrat, vide ou
    /// démesurée est refusée avant même de lister les snapshots. Ensuite,
    /// chaque date doit avoir la forme exacte **et** désigner un snapshot Time
    /// Machine présent : `tmutil` ne reçoit jamais que des dates qui ont passé
    /// les deux.
    static func handle(_ dates: [String], contractVersion: Int, tool: any SnapshotTool) -> DeletionResponse {
        guard contractVersion == HelperContract.version else { return .refused(.contractMismatch) }
        guard !dates.isEmpty else { return .refused(.empty) }
        guard dates.count <= HelperContract.maximumSnapshotsPerRequest else { return .refused(.tooMany) }
        guard let listing = tool.listLocalSnapshots() else { return .refused(.listingFailed) }
        let listed = SnapshotDates.timeMachineDates(inListing: listing)

        var results: [DeletionResponse.Result] = []
        var seen = Set<String>()
        for date in dates where seen.insert(date).inserted {
            guard SnapshotDates.isValid(date) else {
                results.append(.init(date: date, outcome: .malformed))
                continue
            }
            guard listed.contains(date) else {
                results.append(.init(date: date, outcome: .notListed))
                continue
            }
            if let failure = tool.deleteLocalSnapshot(date: date) {
                results.append(.init(date: date, outcome: .failed, message: failure))
            } else {
                results.append(.init(date: date, outcome: .deleted))
            }
        }

        // `tmutil` qui rend 0 n'est cru que si le snapshot a disparu de la
        // liste : on n'annonce pas libéré ce qui est encore là (règle 9).
        if results.contains(where: { $0.outcome == .deleted }), let after = tool.listLocalSnapshots() {
            let remaining = SnapshotDates.timeMachineDates(inListing: after)
            results = results.map { result in
                guard result.outcome == .deleted, remaining.contains(result.date) else { return result }
                return .init(date: result.date, outcome: .failed, message: "still listed")
            }
        }
        return DeletionResponse(results: results)
    }

    /// Ce que le démon fait d'une demande de suppression de sauvegardes, sans
    /// XPC autour.
    ///
    /// L'ordre compte, comme pour les snapshots. D'abord ce qui ne demande rien
    /// au système (contrat, taille, forme du point de montage), puis ce que le
    /// système dit à l'instant : la destination est une destination locale
    /// montée, Time Machine ne sauvegarde pas, la liste se lit. Ensuite chaque
    /// horodatage doit avoir la forme exacte, être listé et ne pas être le plus
    /// récent. L'état est relu avant chaque suppression : une sauvegarde qui
    /// démarre entre deux arrête tout, et le reste est laissé.
    static func handleBackups(_ timestamps: [String], destination: String, contractVersion: Int,
                              tool: any BackupTool) -> BackupDeletionResponse {
        guard contractVersion == HelperContract.version else { return .refused(.contractMismatch) }
        guard !timestamps.isEmpty else { return .refused(.empty) }
        guard timestamps.count <= TimeMachineBackups.maximumPerRequest else { return .refused(.tooMany) }
        guard TimeMachineBackups.isPlausibleMountPoint(destination) else { return .refused(.unknownDestination) }
        guard let info = tool.destinationInfo(),
              let mounts = TimeMachineBackups.eligibleMountPoints(inDestinationInfo: info) else {
            return .refused(.listingFailed)
        }
        guard mounts.contains(destination) else { return .refused(.unknownDestination) }
        // Un état illisible compte comme une sauvegarde en cours (règle 3).
        func isRunning() -> Bool { tool.status().flatMap(TimeMachineBackups.isRunning(statusPlist:)) ?? true }
        guard !isRunning() else { return .refused(.backupRunning) }
        guard let listing = tool.listBackups(mountPoint: destination) else { return .refused(.listingFailed) }
        let listed = Set(TimeMachineBackups.timestamps(inListing: listing))
        let latest = TimeMachineBackups.latest(of: Array(listed))

        var results: [BackupDeletionResponse.Result] = []
        var seen = Set<String>()
        var interrupted = false
        for timestamp in timestamps where seen.insert(timestamp).inserted {
            guard TimeMachineBackups.isValidTimestamp(timestamp) else {
                results.append(.init(timestamp: timestamp, outcome: .malformed))
                continue
            }
            guard listed.contains(timestamp) else {
                results.append(.init(timestamp: timestamp, outcome: .notListed))
                continue
            }
            guard timestamp != latest else {
                results.append(.init(timestamp: timestamp, outcome: .latest))
                continue
            }
            if interrupted || isRunning() {
                interrupted = true
                results.append(.init(timestamp: timestamp, outcome: .backupRunning))
                continue
            }
            if let failure = tool.deleteBackup(mountPoint: destination, timestamp: timestamp) {
                results.append(.init(timestamp: timestamp, outcome: .failed, message: failure))
            } else {
                results.append(.init(timestamp: timestamp, outcome: .deleted))
            }
        }

        // `tmutil` qui rend 0 n'est cru que si la sauvegarde a disparu de la
        // liste : on n'annonce pas supprimé ce qui est encore là (règle 9).
        if results.contains(where: { $0.outcome == .deleted }),
           let after = tool.listBackups(mountPoint: destination) {
            let remaining = Set(TimeMachineBackups.timestamps(inListing: after))
            results = results.map { result in
                guard result.outcome == .deleted, remaining.contains(result.timestamp) else { return result }
                return .init(timestamp: result.timestamp, outcome: .failed, message: "still listed")
            }
        }
        return BackupDeletionResponse(results: results)
    }

    static let log = Logger(subsystem: HelperContract.daemonIdentifier, category: "helper")
}
