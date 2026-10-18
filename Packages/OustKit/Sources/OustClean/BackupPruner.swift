import Foundation
import OustCore
import OustVolume

/// Pourquoi rien ne part du disque Time Machine.
public enum BackupPruneRefusal: Sendable, Equatable {
    /// Garder moins d'une sauvegarde : jamais.
    case keepAtLeastOne
    /// Il n'y a rien au-delà des sauvegardes gardées.
    case nothingToDelete
    /// La plus récente figure dans la liste : jamais.
    case latest
    /// Ce volume n'est plus une destination Time Machine branchée (débranché,
    /// remplacé, retiré des réglages de Time Machine).
    case unknownDestination
    /// La liste ne se lit plus : rien n'est comparable.
    case unreadable
    /// Time Machine sauvegarde en ce moment.
    case backupRunning
    /// La liste a changé depuis qu'on l'a montrée, au point qu'on en
    /// garderait moins que demandé : à revoir.
    case changed
    /// L'invite administrateur a été fermée sans mot de passe.
    case cancelled
    /// Le démon n'a pas répondu à temps : il travaille peut-être encore.
    case timedOut
    case failed(message: String)

    public var localizationKey: String {
        switch self {
        case .keepAtLeastOne: "backups.refusal.keep_one"
        case .nothingToDelete: "backups.refusal.nothing"
        case .latest: "backups.refusal.latest"
        case .unknownDestination: "backups.refusal.destination"
        case .unreadable: "backups.refusal.unreadable"
        case .backupRunning: "backups.refusal.running"
        case .changed: "backups.refusal.changed"
        case .cancelled: "backups.refusal.cancelled"
        case .timedOut: "backups.refusal.timed_out"
        case .failed: "backups.refusal.failed"
        }
    }
}

/// Ce qu'a donné une suppression de sauvegardes, d'après la liste relue après.
public struct BackupPruneReport: Sendable, Equatable {
    /// Parties : listées avant, plus listées après.
    public var deleted: [TimeMachineBackup] = []
    /// Encore là après coup, avec ce que `tmutil` en a dit.
    public var failed: [TimeMachineBackup] = []
    /// Déjà disparues au moment d'agir (Time Machine fait aussi le ménage).
    public var vanished: [TimeMachineBackup] = []
    /// Non nil : rien n'a été tenté, ou tout s'est arrêté là.
    public var refusal: BackupPruneRefusal?
    public var path: BackupDeletionReply.Path?
    /// L'espace libre du disque de sauvegarde, mesuré et non calculé : avant
    /// d'agir, puis juste après. APFS en rend une partie plus tard.
    public var availableBefore: Int64?
    public var availableAfter: Int64?

    public init() {}
}

/// Supprimer les plus anciennes sauvegardes d'un disque Time Machine en gardant
/// les N dernières (Romain, 18/10/2026 : « dégager les plus anciennes et garder
/// par exemple les deux ou trois dernières ; je ne reviens jamais en arrière,
/// mes données sont aussi dans le cloud »).
///
/// Comme toute suppression, elle passe ici, dans OustClean (règle 1), par la
/// commande de l'outil (règle 6, `tmutil delete`), revalidée juste avant
/// d'agir (règle 2) et journalisée. Elle ne passe pas par la corbeille d'Oust! :
/// une sauvegarde n'est pas un élément de l'analyse, elle se choisit dans le
/// panneau du disque, avec son propre avertissement.
///
/// Aucune taille n'est annoncée par sauvegarde : sur un disque APFS, ce qu'une
/// sauvegarde garde à elle seule ne se mesure qu'en la parcourant entière
/// (`tmutil uniquesize`, des heures). On annonce l'espace libre avant, et on le
/// relit après (règle 9).
public enum BackupPruner {

    /// Ce que le panneau propose d'office : « les deux ou trois dernières ».
    public static let defaultKept = 3
    /// Jamais moins : la plus récente reste toujours.
    public static let minimumKept = 1

    /// Les sauvegardes qui partiraient en gardant les `keep` plus récentes :
    /// les plus anciennes, dans l'ordre. Rien si `keep` est sous le minimum,
    /// et jamais la plus récente.
    public static func plan(_ backups: [TimeMachineBackup], keeping keep: Int) -> [TimeMachineBackup] {
        guard keep >= minimumKept else { return [] }
        let sorted = Set(backups).sorted()
        guard sorted.count > keep else { return [] }
        return Array(sorted.dropLast(keep))
    }

    /// Les gardes, sans rien toucher : sur ce qu'on montre, puis sur ce qu'on
    /// relit juste avant d'agir.
    public static func refusal(deleting chosen: [TimeMachineBackup], keeping keep: Int,
                               in destination: TimeMachineDestination) -> BackupPruneRefusal? {
        guard keep >= minimumKept else { return .keepAtLeastOne }
        guard !chosen.isEmpty else { return .nothingToDelete }
        if let latest = destination.latest, chosen.contains(latest) { return .latest }
        guard !destination.isBackupRunning else { return .backupRunning }
        let listed = Set(destination.backups)
        let leaving = Set(chosen).intersection(listed)
        guard !leaving.isEmpty else { return .nothingToDelete }
        guard listed.count - leaving.count >= keep else { return .changed }
        return nil
    }

    /// Ce dont le pruneur a besoin du système. Remplacé par les tests : aucun
    /// ne supprime de vraie sauvegarde.
    public struct System: Sendable {
        var listing: @Sendable (URL) async -> TimeMachineListing
        var delete: @Sendable (_ timestamps: [String], _ mountPoint: String) async -> BackupDeletionReply
        var capacity: @Sendable (URL) -> Capacity?

        init(listing: @escaping @Sendable (URL) async -> TimeMachineListing,
             delete: @escaping @Sendable ([String], String) async -> BackupDeletionReply,
             capacity: @escaping @Sendable (URL) -> Capacity?) {
            self.listing = listing
            self.delete = delete
            self.capacity = capacity
        }

        public static let live = System(
            listing: { await TimeMachineService.listing(of: $0) },
            delete: { await TimeMachineService.deleteBackups($0, at: $1) },
            capacity: { VolumeService.capacity(of: $0) })
    }

    /// Revalide, supprime, relit la liste, puis journalise sauvegarde par
    /// sauvegarde ce qui est vraiment parti et ce qui est resté.
    ///
    /// `shown` : la destination telle que le panneau l'a montrée. Si le disque
    /// branché n'est plus celui-là, rien ne part. `title` donne le nom d'une
    /// sauvegarde dans l'Historique (sa date, à la façon du Mac).
    public static func prune(
        _ chosen: [TimeMachineBackup], keeping keep: Int, shown: TimeMachineDestination,
        system: System = .live, history: HistoryStore? = .standard(), origin: CleanupOrigin = .app,
        title: @Sendable (TimeMachineBackup) -> String = { $0.timestamp }
    ) async -> BackupPruneReport {
        var report = BackupPruneReport()
        let volume = URL(fileURLWithPath: shown.mountPoint)

        // Juste avant d'agir : la destination, l'état, la liste, relus.
        let now: TimeMachineDestination
        switch await system.listing(volume) {
        case .notADestination:
            report.refusal = .unknownDestination
            return report
        case .unreadable:
            report.refusal = .unreadable
            return report
        case .listed(let destination):
            guard destination.id == shown.id, destination.mountPoint == shown.mountPoint else {
                report.refusal = .unknownDestination
                return report
            }
            now = destination
        }
        let listed = Set(now.backups)
        report.vanished = chosen.filter { !listed.contains($0) }.sorted()
        if let refusal = refusal(deleting: chosen, keeping: keep, in: now) {
            report.refusal = refusal
            return report
        }
        let present = chosen.filter(listed.contains).sorted()

        let session = UUID()
        report.availableBefore = system.capacity(volume)?.available
        let reply = await system.delete(present.map(\.timestamp), now.mountPoint)
        report.path = reply.path
        report.refusal = reply.refusal.map(Self.refusal(from:))

        // Ce qui est parti se lit dans la liste relue, pas dans ce que `tmutil`
        // ou l'invite ont répondu. Si elle ne se relit pas, seul ce que le démon
        // a confirmé (il relit lui-même) compte comme parti.
        let remaining: Set<TimeMachineBackup>
        if case .listed(let after) = await system.listing(volume) {
            remaining = Set(after.backups)
        } else if reply.path == .helper, reply.refusal == nil {
            remaining = Set(present.filter { reply.messages[$0.timestamp] != nil })
        } else {
            remaining = Set(present)
        }
        report.availableAfter = system.capacity(volume)?.available
        report.deleted = present.filter { !remaining.contains($0) }
        report.failed = present.filter { remaining.contains($0) }

        // Au journal : ce qui est parti, ce qui est resté et pourquoi, ce qui
        // avait déjà disparu. Rien quand la demande a été refusée d'emblée
        // (invite fermée, sauvegarde lancée, disque changé) : rien n'a été fait,
        // et le panneau le dit.
        var lines: [CleanupOutcome] = []
        func line(_ backup: TimeMachineBackup, _ result: OutcomeResult) {
            var outcome = CleanupOutcome(sessionID: session, date: Date(),
                                         item: item(for: backup, on: now, title: title(backup)),
                                         result: result, bytes: 0)
            outcome.origin = origin
            lines.append(outcome)
        }
        for backup in report.deleted { line(backup, .delegated) }
        if reply.refusal == nil || !report.deleted.isEmpty {
            for backup in report.failed {
                switch reply.refusal {
                // Laissées parce que Time Machine s'est mis à sauvegarder.
                case .backupRunning?: line(backup, .skipped(.nowProtected(.daemonRunning(name: "Time Machine"))))
                // Le démon les supprime peut-être encore : rien d'affirmé.
                case .timedOut?: continue
                default: line(backup, .failed(message: reply.messages[backup.timestamp] ?? failureMessage(reply)))
                }
            }
            for backup in report.vanished { line(backup, .skipped(.vanished)) }
        }
        for outcome in lines { try? await history?.append(outcome) }
        return report
    }

    /// La ligne de l'Historique d'une sauvegarde : sa date pour titre, le disque
    /// pour propriétaire, sans taille (elle ne se mesure pas, règle 9).
    static func item(for backup: TimeMachineBackup, on destination: TimeMachineDestination,
                     title: String) -> CleanupItem {
        CleanupItem(
            id: "timemachine|\(destination.id)|\(backup.timestamp)",
            title: title,
            detail: backup.timestamp,
            paths: [URL(fileURLWithPath: destination.mountPoint)],
            category: .snapshots,
            owner: destination.name,
            ruleID: "time_machine.backup",
            safety: .review,
            method: .timeMachineBackup(destination: destination.mountPoint, timestamp: backup.timestamp),
            lastActivity: backup.date,
            rebuild: .irreversible
        )
    }

    static func refusal(from refusal: BackupDeletionRefusal) -> BackupPruneRefusal {
        switch refusal {
        case .backupRunning: .backupRunning
        case .unknownDestination: .unknownDestination
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .failed(let message): .failed(message: message)
        }
    }

    private static func failureMessage(_ reply: BackupDeletionReply) -> String {
        if case .failed(let message)? = reply.refusal { return message }
        return "tmutil"
    }
}
