import AppKit
import Darwin
import Foundation
import OustCore
import OustSafety
import OustVolume
import Synchronization

/// Fait le vide, élément par élément, en le racontant au fil de l'eau
/// (SPEC §6.2).
///
/// Quatre éléments au plus à la fois, chacun revalidé juste avant d'agir et
/// annoncé au moment où il part : l'interface le voit toujours partir un par
/// un. Ce qu'un même outil traite (un dépôt git, simctl, Homebrew) passe à la
/// file, un à la fois : deux `git worktree remove` simultanés sur un dépôt se
/// disputeraient son verrou.
public struct CleanupEngine: Sendable {
    let trasher: any Trasher
    private let allowsPathBasedRemoval: Bool
    let history: HistoryStore?
    let pathGuard: PathGuard
    let processes: @Sendable () -> ProcessSnapshot
    let capacity: @Sendable (URL) -> Capacity?
    let deleteSnapshots: @Sendable ([LocalSnapshot], @Sendable () -> Bool, @Sendable (CleanupPhase) -> Void) async -> SnapshotDeletionReport
    /// Les applications ouvertes, par identifiant de bundle (caches, Mail, Messages).
    let runningApps: @Sendable () -> Set<String>
    /// La photothèque, par PhotoKit : la seule voie pour en supprimer un élément.
    let photos: any PhotoEraser
    /// Ce que macOS dit du compte d'un fichier du cloud : le fichier, le dossier
    /// de son compte File Provider (nil pour iCloud Drive), les apps ouvertes.
    let cloudConnection: @Sendable (URL, URL?, Set<String>) async -> CloudConnection
    let userLogOpenStatus: @Sendable (String) -> OpenFiles.Status
    let userLogTrashDirectory: URL

    /// Le régénérable y est renommé puis effacé en arrière-plan ; sans lui, il
    /// est effacé sur place (les tests, qui n'écrivent que chez eux).
    let transit: Transit?

    /// Qui a lancé le nettoyage, inscrit sur chaque ligne du journal.
    public let origin: CleanupOrigin

    /// Combien d'éléments à la fois.
    static let parallelism = 4

    public init(
        trasher: any Trasher = FinderTrasher(),
        history: HistoryStore? = .standard(),
        pathGuard: PathGuard = PathGuard(),
        processes: @escaping @Sendable () -> ProcessSnapshot = { .current() },
        capacity: @escaping @Sendable (URL) -> Capacity? = { VolumeService.capacity(of: $0) },
        deleteSnapshots: (@Sendable ([LocalSnapshot]) async -> Bool)? = nil,
        snapshotResults: (@Sendable ([LocalSnapshot]) async -> SnapshotDeletionReport)? = nil,
        runningApps: @escaping @Sendable () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        transit: Transit? = nil,
        origin: CleanupOrigin = .app,
        photos: any PhotoEraser = SystemPhotoEraser(),
        cloudConnection: @escaping @Sendable (URL, URL?, Set<String>) async -> CloudConnection = {
            await CloudConnectionCheck.connection(of: $0, accountRoot: $1, running: $2)
        },
        allowsPathBasedRemoval: Bool = false,
        userLogOpenStatus: @escaping @Sendable (String) -> OpenFiles.Status = OpenFiles.status(at:),
        userLogTrashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    ) {
        self.trasher = trasher
        self.allowsPathBasedRemoval = allowsPathBasedRemoval
        self.history = history
        self.pathGuard = pathGuard
        self.processes = processes
        self.capacity = capacity
        if let snapshotResults {
            self.deleteSnapshots = { snapshots, _, progress in
                progress(.deletingSnapshots(count: snapshots.count))
                return await snapshotResults(snapshots)
            }
        } else if let deleteSnapshots {
            self.deleteSnapshots = { snapshots, _, progress in
                progress(.deletingSnapshots(count: snapshots.count))
                let succeeded = await deleteSnapshots(snapshots)
                let dates = snapshots.compactMap(\.date)
                return SnapshotDeletionReport(deleted: succeeded ? Set(dates) : [],
                    failures: succeeded ? [:] : Dictionary(uniqueKeysWithValues: dates.map { ($0, "tmutil") }))
            }
        } else {
            self.deleteSnapshots = { snapshots, isCancelled, progress in
                await VolumeService.deleteSnapshotResults(snapshots, isCancelled: isCancelled, progress: progress)
            }
        }
        self.transit = transit
        self.runningApps = runningApps
        self.origin = origin
        self.photos = photos
        self.cloudConnection = cloudConnection
        self.userLogOpenStatus = userLogOpenStatus
        self.userLogTrashDirectory = userLogTrashDirectory
    }

    public func supports(_ method: CleanupMethod) -> Bool {
        Self.supports(method, trasher: trasher, allowsPathBasedRemoval: allowsPathBasedRemoval)
    }

    public static func supports(_ method: CleanupMethod, trasher: any Trasher,
                                allowsPathBasedRemoval: Bool) -> Bool {
        switch method {
        case .trash, .archive, .trashFromCloud: trasher.isAvailable
        // Le transit et la suppression sur place résolvent des chemins après
        // le contrôle. Seuls les bancs isolés activent cette implémentation.
        case .removeNow, .cloneOf, .compressInPlace: allowsPathBasedRemoval
        default: true
        }
    }

    /// Lance le nettoyage. Annuler la tâche qui lit le flux, ou `cancellation`,
    /// arrête tout entre deux éléments ; les suivants sont notés « annulés ».
    /// Avec `cancellation`, le flux continue jusqu'au bilan.
    ///
    /// `session` regroupe au journal plusieurs passages qui forment une seule
    /// opération (l'archivage traite ses projets un par un).
    public func run(_ items: [CleanupItem], session: UUID = UUID(),
                    cancellation: CleanupCancellation? = nil) -> AsyncStream<CleanupEvent> {
        AsyncStream { continuation in
            let task = Task {
                let report = await execute(items, session: session, cancellation: cancellation) { continuation.yield($0) }
                continuation.yield(.finished(report))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func execute(_ items: [CleanupItem], session: UUID = UUID(), cancellation: CleanupCancellation? = nil,
                 emit: @escaping @Sendable (CleanupEvent) -> Void) async -> CleanupReport {
        let started = Date()
        let selectable = items.filter {
            $0.isSelectable && (!($0.category == .userLogs || $0.ruleID == "logs.user") || $0.method == .trash)
        }
        emit(.began(total: selectable.count, expectedBytes: selectable.reduce(0) { $0 + $1.sizes.freeable }))
        emit(.phaseChanged(.preparing, itemIDs: []))
        let volumes = Self.volumes(of: items)
        let before = Self.available(on: volumes, capacity: capacity)

        var snapshot = processes()
        var lastRefresh = Date()
        var outcomes: [CleanupOutcome] = []
        var pending = selectable
        var running = 0
        var busyQueues = Set<String>()
        let isCancelled: @Sendable () -> Bool = { Task.isCancelled || cancellation?.isCancelled == true }

        await withTaskGroup(of: (item: CleanupItem, outcome: CleanupOutcome).self) { group in
            while true {
                // Lancer tout ce qui peut l'être, dans l'ordre de la corbeille.
                while running < Self.parallelism,
                      let index = pending.firstIndex(where: { Self.queue(for: $0.method).map { !busyQueues.contains($0) } ?? true }) {
                    let item = pending.remove(at: index)
                    emit(.itemBegan(id: item.id))
                    if isCancelled() {
                        let outcome = CleanupOutcome(sessionID: session, date: Date(), item: item,
                                                     result: .skipped(.cancelled), bytes: 0)
                        await record(outcome, into: &outcomes, emit: emit)
                        continue
                    }
                    if item.category == .userLogs || item.ruleID == "logs.user" {
                        let outcome = CleanupOutcome(sessionID: session, date: Date(), item: item,
                                                     result: .skipped(userLogProtection(item)), bytes: 0)
                        await record(outcome, into: &outcomes, emit: emit)
                        continue
                    }
                    if item.method.isSnapshot {
                        // Tous les snapshots d'un coup : une seule invite administrateur.
                        let batch = [item] + pending.filter(\.method.isSnapshot)
                        pending.removeAll { $0.method.isSnapshot }
                        let all = batch.compactMap { candidate -> LocalSnapshot? in
                            guard case .localSnapshot(let date) = candidate.method else { return nil }
                            return LocalSnapshot(name: "com.apple.TimeMachine.\(date).local")
                        }
                        for candidate in batch where candidate.id != item.id { emit(.itemBegan(id: candidate.id)) }
                        emit(.phaseChanged(.revalidating, itemIDs: batch.map(\.id)))
                        let reply = await deleteSnapshots(all, isCancelled) { phase in
                            emit(.phaseChanged(phase, itemIDs: batch.map(\.id)))
                        }
                        for candidate in batch {
                            guard case .localSnapshot(let date) = candidate.method else { continue }
                            let succeeded = reply.deleted.contains(date)
                            let result: OutcomeResult = succeeded ? .delegated
                                : reply.failures[date] == "snapshot.error.cancelled" ? .skipped(.cancelled)
                                : .failed(message: reply.failures[date] ?? "snapshot.error.unverified")
                            let one = CleanupOutcome(sessionID: session, date: Date(), item: candidate, result: result,
                                                     bytes: succeeded ? candidate.sizes.freeable : 0)
                            await record(one, into: &outcomes, emit: emit)
                        }
                        continue
                    }
                    if item.method.photoAssetID != nil {
                        // Toutes les photos d'un coup : une seule confirmation de macOS.
                        let batch = [item] + pending.filter { $0.method.photoAssetID != nil }
                        pending.removeAll { $0.method.photoAssetID != nil }
                        for candidate in batch where candidate.id != item.id { emit(.itemBegan(id: candidate.id)) }
                        let results = await erasePhotos(batch, session: session, isCancelled: isCancelled) { phase in
                            emit(.phaseChanged(phase, itemIDs: batch.map(\.id)))
                        }
                        for one in results {
                            await record(one, into: &outcomes, emit: emit)
                        }
                        continue
                    }
                    // Les processus changent : on relit la table toutes les cinq secondes.
                    if Date().timeIntervalSince(lastRefresh) > 5 {
                        snapshot = processes()
                        lastRefresh = Date()
                    }
                    if let queue = Self.queue(for: item.method) { busyQueues.insert(queue) }
                    running += 1
                    let current = snapshot
                    group.addTask {
                        // La revalidation se fait ici, juste avant d'agir, et non au
                        // moment où l'élément est entré dans la file.
                        emit(.phaseChanged(.revalidating, itemIDs: [item.id]))
                        if let reason = await revalidate(item, snapshot: current) {
                            return (item, CleanupOutcome(sessionID: session, date: Date(), item: item,
                                                         result: .skipped(reason), bytes: 0))
                        }
                        // Une revalidation (archive, git, nuage) peut durer :
                        // Arrêter pendant celle-ci doit encore empêcher la mutation.
                        if isCancelled() {
                            return (item, CleanupOutcome(sessionID: session, date: Date(), item: item,
                                                         result: .skipped(.cancelled), bytes: 0))
                        }
                        // Le SHA d'une archive peut durer : un agent démarré
                        // pendant cette lecture doit encore conserver l'original.
                        if case .archive = item.method,
                           let reason = archiveActivityProtection(item, snapshot: processes()) {
                            return (item, CleanupOutcome(sessionID: session, date: Date(), item: item,
                                                         result: .skipped(reason), bytes: 0))
                        }
                        if isCancelled() {
                            return (item, CleanupOutcome(sessionID: session, date: Date(), item: item,
                                                         result: .skipped(.cancelled), bytes: 0))
                        }
                        emit(.phaseChanged(.deleting, itemIDs: [item.id]))
                        return (item, await perform(item, session: session))
                    }
                }
                guard running > 0, let done = await group.next() else { break }
                running -= 1
                if let queue = Self.queue(for: done.item.method) { busyQueues.remove(queue) }
                await record(done.outcome, into: &outcomes, emit: emit)
            }
        }

        emit(.phaseChanged(.measuring, itemIDs: []))
        let after = Self.available(on: volumes, capacity: capacity)
        // Le bilan suit l'ordre de la corbeille, pas celui des fins.
        let order = Dictionary(selectable.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        outcomes.sort { (order[$0.itemID] ?? .max) < (order[$1.itemID] ?? .max) }
        var report = CleanupReport(sessionID: session, startedAt: started, finishedAt: Date(), outcomes: outcomes,
                                   availableBefore: before, availableAfter: after)
        // Compté comme libéré, mais pas encore effacé : le volume ne l'a pas
        // encore rendu, et ce n'est pas la faute des snapshots.
        report.purging = transit?.pendingBytes ?? 0
        return report
    }

    /// La file d'attente d'un élément : ceux d'une même file passent un à un.
    /// `nil` : rien ne s'oppose à ce qu'il parte en même temps que d'autres.
    static func queue(for method: CleanupMethod) -> String? {
        switch method {
        case .removeNow, .trash, .cloneOf, .compressInPlace: nil
        case .gitWorktreeRemove(let repository): "git:" + repository
        case .simulatorDevice, .simulatorRuntime: "simctl"
        case .firefoxHistory(let database): "firefox:" + database
        // Une méthode d'outil inconnue d'ici attend son tour, par prudence.
        default: method.localizationKey
        }
    }

    private func record(_ outcome: CleanupOutcome, into outcomes: inout [CleanupOutcome],
                        emit: @Sendable (CleanupEvent) -> Void) async {
        // Toute ligne passe ici : l'origine n'a qu'un endroit où être posée.
        var outcome = outcome
        outcome.origin = origin
        outcomes.append(outcome)
        if outcome.result != .skipped(.cancelled) {
            emit(.phaseChanged(.journaling, itemIDs: [outcome.itemID]))
            try? await history?.append(outcome)
        }
        emit(.itemFinished(outcome))
    }

    // MARK: Revalidation

    func archiveActivityProtection(_ item: CleanupItem, snapshot: ProcessSnapshot) -> SkipReason? {
        guard snapshot.isComplete else { return .nowProtected(.unknownState) }
        let scopes = (item.activityScope.map { [$0] } ?? []) + item.paths
        for scope in scopes {
            if let process = snapshot.busy(under: scope.path) {
                return .nowProtected(.activeProcess(name: process.name))
            }
            if let process = snapshot.running(inside: scope.path) {
                return .nowProtected(.appRunning(name: process.name))
            }
        }
        return nil
    }

    /// Rend une raison de ne pas toucher l'élément, ou `nil` si tout est en ordre
    /// (RULES.md, règle 2).
    func revalidate(_ item: CleanupItem, snapshot: ProcessSnapshot) async -> SkipReason? {
        guard supports(item.method) else { return .refusedByGuard }
        for path in item.paths {
            guard !pathGuard.protectsUserLogs(path) else { return .refusedByGuard }
            // L'éviction ne supprime rien, mais ne vaut que dans le nuage ; un
            // fichier d'un nuage ne part que s'il est bien un document de
            // l'utilisateur (jamais la racine d'un compte) ; tout le reste passe
            // la garde ordinaire.
            let allowed = switch item.method {
            case .evictLocalCopy: pathGuard.allowsEviction(path)
            case .trashFromCloud: pathGuard.allowsCloudTrash(path)
            default: pathGuard.allows(path)
            }
            guard allowed else { return .refusedByGuard }
            var info = stat()
            if lstat(path.path, &info) != 0 { return .vanished }
        }
        if let first = item.paths.first, let fingerprint = item.fingerprint {
            var info = stat()
            lstat(first.path, &info)
            if let inode = fingerprint.fileID, inode != UInt64(info.st_ino) { return .changedSinceScan }
            // Le contenu personnel a pu être modifié depuis qu'on l'a montré :
            // on ne jette pas à la corbeille ce que l'utilisateur n'a pas vu.
            // Un cache, lui, change sans cesse et reste un cache.
            if item.safety == .review, let date = fingerprint.modificationDate {
                let current = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                if abs(current.timeIntervalSince(date)) > 2 { return .changedSinceScan }
            }
        }
        // Un compte du cloud déconnecté depuis l'analyse (l'app du service
        // fermée entre-temps) : écarté ici, sans passer par le Finder. Lui
        // affichait une alerte qui bloquait le nettoyage jusqu'au clic sur OK,
        // puis échouait (essai du 18/10/2026).
        if item.method == .trashFromCloud {
            let running = runningApps()
            for path in item.paths {
                let connection = await cloudConnection(path, pathGuard.fileProviderAccount(of: path), running)
                if !connection.isConnected { return .nowProtected(.cloudDisconnected) }
            }
        }
        // Le dossier de travail d'abord (un agent, une compilation), puis les
        // exécutables : une application ouverte a `/` pour dossier courant.
        let scopes = (item.activityScope.map { [$0] } ?? []) + item.paths
        for scope in scopes {
            if let process = snapshot.busy(under: scope.path) {
                return .nowProtected(.activeProcess(name: process.name))
            }
        }
        for scope in scopes {
            if let process = snapshot.running(inside: scope.path) {
                return .nowProtected(.appRunning(name: process.name))
            }
        }
        // L'application propriétaire a pu être ouverte depuis l'analyse.
        if let owner = AppOwnership.runningOwner(ruleID: item.ruleID, paths: item.paths, running: runningApps()) {
            return .nowProtected(.appRunning(name: owner))
        }
        // Archivé : l'original ne part que s'il est encore celui qu'on a copié.
        if case .archive(let copy) = item.method, let original = item.paths.first {
            let matches = await withCheckedContinuation { continuation in
                // Les lectures et SHA de plusieurs Go ne doivent pas retenir
                // un thread du pool coopératif pendant des minutes.
                let worker = Thread {
                    continuation.resume(returning: ArchiveSeal.originalMatchesCopy(
                        original: original, copy: URL(fileURLWithPath: copy)))
                }
                worker.name = "Oust.ArchiveVerification"
                worker.qualityOfService = .utility
                worker.start()
            }
            guard matches else {
                return .changedSinceScan
            }
        }
        if case .gitWorktreeRemove = item.method, let worktree = item.paths.first {
            guard let state = await GitInspector.state(ofWorktree: worktree) else { return .nowProtected(.unknownState) }
            if state.uncommitted > 0 { return .nowProtected(.uncommittedChanges(count: state.uncommitted)) }
            if !state.uniqueSensitiveFiles.isEmpty { return .nowProtected(.uniqueIgnoredFiles(state.uniqueSensitiveFiles)) }
            if state.isLocked { return .nowProtected(.gitLocked) }
        }
        return nil
    }

    // MARK: Exécution

    func perform(_ item: CleanupItem, session: UUID) async -> CleanupOutcome {
        func outcome(_ result: OutcomeResult, bytes: Int64 = 0, trashedTo: [String] = []) -> CleanupOutcome {
            CleanupOutcome(sessionID: session, date: Date(), item: item, result: result,
                           bytes: result.succeeded ? bytes : 0, trashedTo: trashedTo)
        }
        guard supports(item.method) else { return outcome(.skipped(.refusedByGuard)) }
        var resolvedPaths: [URL] = []
        for path in item.paths {
            guard !pathGuard.protectsUserLogs(path), let resolved = PathGuard.withResolvedParent(path),
                  !pathGuard.protectsUserLogs(resolved),
                  !pathGuard.protectsPreferences(path, resolved: resolved),
                  !pathGuard.protectsSafariDownload(path, resolved: resolved, protectAncestors: item.method != .evictLocalCopy)
            else { return outcome(.skipped(.refusedByGuard)) }
            resolvedPaths.append(resolved)
        }
        let freeable = item.sizes.freeable

        switch item.method {
        case .removeNow:
            // Renommé dans le dossier de transit : parti à l'instant, effacé
            // derrière. Sinon (autre volume, droits), effacé sur place.
            for (index, path) in resolvedPaths.enumerated() {
                if transit?.move(path, bytes: index == 0 ? freeable : 0) == true { continue }
                if let error = Remover.remove(path) { return outcome(.failed(message: error)) }
            }
            return outcome(.removed, bytes: freeable)

        // Un fichier d'un nuage part par le même chemin : le Finder le range dans
        // la corbeille du service (iCloud Drive, Google Drive), sans le télécharger,
        // et « Remettre » le fait revenir.
        case .trash, .archive, .trashFromCloud:
            let results = await trasher.trash(resolvedPaths)
            var destinations: [String] = []
            for result in results {
                switch result {
                case .success(let url): destinations.append(url.path)
                case .failure(let error): return outcome(.failed(message: error.message), trashedTo: destinations)
                }
            }
            return outcome(.trashed, bytes: freeable, trashedTo: destinations)

        case .gitWorktreeRemove(let repository):
            guard let worktree = item.paths.first else { return outcome(.skipped(.vanished)) }
            if let error = await ToolActions.removeWorktree(worktree, repository: repository) {
                return outcome(.failed(message: error))
            }
            return outcome(.delegated, bytes: freeable)

        case .simulatorDevice(let udid):
            if let error = await ToolActions.deleteSimulator(udid: udid) { return outcome(.failed(message: error)) }
            return outcome(.delegated, bytes: freeable)

        case .simulatorRuntime(let identifier):
            if let error = await ToolActions.deleteRuntime(identifier: identifier) { return outcome(.failed(message: error)) }
            return outcome(.delegated, bytes: freeable)

        case .firefoxHistory(let database):
            if let error = ToolActions.clearFirefoxHistory(database: database) { return outcome(.failed(message: error)) }
            return outcome(.delegated, bytes: freeable)

        case .cloneOf(let original):
            guard let target = item.paths.first else { return outcome(.skipped(.vanished)) }
            if let error = ToolActions.replaceWithClone(target, original: URL(fileURLWithPath: original)) {
                return outcome(.failed(message: error))
            }
            return outcome(.cloned, bytes: freeable)

        case .evictLocalCopy:
            // Ce qui compte est ce qui a été évincé, mesuré fichier par fichier.
            let summary = Evictor.evict(item.paths, isCancelled: { Task.isCancelled })
            if summary.evicted == 0, let first = summary.failures.first { return outcome(.failed(message: first)) }
            return outcome(.evicted, bytes: summary.evictedBytes)

        case .compressInPlace:
            var summary = Compressor.Summary()
            for path in item.paths {
                let one = Compressor.compressTree(path, notAfter: item.lastActivity, isCancelled: { Task.isCancelled })
                summary.savedBytes += one.savedBytes
                summary.compressed += one.compressed
                summary.failures += one.failures
            }
            if summary.compressed == 0, let first = summary.failures.first { return outcome(.failed(message: first)) }
            // Le gain réel, pas l'estimation de l'analyse.
            return outcome(.compressed, bytes: summary.savedBytes)

        case .uninstallVersion(let tool, let executable, let root, let version):
            if let error = await ToolActions.uninstallVersion(tool: tool, executable: executable, root: root,
                                                              version: version, folder: item.paths.first) {
                return outcome(.failed(message: error))
            }
            return outcome(.delegated, bytes: freeable)

        case .brewCleanup(let executable):
            if let error = await ToolActions.brewCleanup(executable: executable) { return outcome(.failed(message: error)) }
            return outcome(.delegated, bytes: freeable)

        case .containerPrune(let executable, let scope, let ids):
            switch await ToolActions.containerPrune(executable: executable, scope: scope, ids: ids) {
            case .success(let reclaimed): return outcome(.delegated, bytes: reclaimed ?? freeable)
            case .failure(let error): return outcome(.failed(message: error.message))
            }

        // Les photos partent par lot (`erasePhotos`), jamais une à une : chaque
        // demande à Photos ferait paraître une invite. Les sauvegardes Time
        // Machine n'entrent jamais dans la corbeille : `BackupPruner`, depuis
        // le panneau du disque, et lui seul.
        case .localSnapshot, .manual, .photoAsset, .timeMachineBackup:
            return outcome(.skipped(.refusedByGuard))
        }
    }

    static func volumeURL(of url: URL) -> URL? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    /// Les volumes que ces éléments libèrent, chacun une fois. Une corbeille
    /// peut mêler le disque de démarrage et un disque externe : mesurer le seul
    /// volume du premier élément ferait dire « retenu par les snapshots » à
    /// l'espace rendu sur l'autre. Un élément sans chemin (snapshot) libère le
    /// disque de démarrage.
    ///
    /// Foundation nomme `/` le volume d'un fichier du dossier personnel, et
    /// `/System/Volumes/Data` celui des snapshots : deux noms pour un même
    /// espace libre, qui compté deux fois doublerait le gain mesuré.
    public static func volumes(of items: [CleanupItem]) -> [URL] {
        var seen = Set<String>()
        var volumes: [URL] = []
        func add(_ url: URL) {
            let volume = url.standardizedFileURL.path == "/" ? VolumeService.bootDataRoot : url
            if seen.insert(volume.standardizedFileURL.path).inserted { volumes.append(volume) }
        }
        for item in items {
            if let first = item.paths.first {
                if let volume = volumeURL(of: first) { add(volume) }
            } else {
                add(VolumeService.bootDataRoot)
            }
        }
        return volumes.isEmpty ? [VolumeService.bootDataRoot] : volumes
    }

    /// L'espace libre de ces volumes, additionné ; `nil` si l'un ne répond pas.
    public static func available(on volumes: [URL], capacity: (URL) -> Capacity?) -> Int64? {
        var total: Int64 = 0
        for volume in volumes {
            guard let available = capacity(volume)?.available else { return nil }
            total += available
        }
        return total
    }
}

/// Arrêter un nettoyage entre deux éléments, sans couper le flux d'événements :
/// le bilan arrive quand même, avec les éléments restants notés « annulés ».
public final class CleanupCancellation: Sendable {
    private let flag = Atomic<Bool>(false)

    public init() {}

    public func cancel() { flag.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { flag.load(ordering: .relaxed) }
}
