import Darwin
import Foundation
import OustClean
import OustCore
import OustSafety

/// Ce qu'il est advenu d'un projet.
public struct ArchiveOutcome: Sendable, Identifiable {
    public var id: String { project.id }
    public let project: ProjectCandidate
    /// La copie vérifiée sur le volume d'archive, s'il y en a une.
    public let copy: URL?
    /// Le sort de l'original : `.trashed` quand tout s'est bien passé.
    public let result: OutcomeResult
    public let error: ArchiveError?
    public let bytes: Int64

    /// La copie existe et l'original est parti à la corbeille du Mac.
    public var completed: Bool { copy != nil && result == .trashed }
}

/// Ce que l'archivage raconte au fil de l'eau.
public enum ArchiveEvent: Sendable {
    case began(total: Int, bytes: Int64)
    case projectBegan(id: String, step: ArchiveStep)
    case projectFinished(ArchiveOutcome)
    case finished([ArchiveOutcome])
}

public enum ArchiveStep: Sendable, Hashable {
    case copying
    case trashing
}

/// Archive des projets inactifs sur un disque externe (SPEC §10, phase 2).
///
/// L'ordre ne se discute pas : copier, vérifier chaque fichier (taille et
/// empreinte SHA-256), et seulement ensuite envoyer l'original à la corbeille du
/// Mac — par `OustClean`, qui revérifie juste avant que l'original n'a pas changé
/// depuis la copie (RULES.md, règles 1 et 2). Une étape qui échoue arrête tout
/// pour ce projet, et l'original reste où il est.
public struct ProjectArchiver: Sendable {
    let engine: CleanupEngine
    let history: HistoryStore?
    let copier: ArchiveCopier
    let processes: @Sendable () -> ProcessSnapshot
    /// Le message d'un échec, tel qu'il entre au journal (traduit par l'appelant).
    let describe: @Sendable (ArchiveError) -> String

    public init(
        engine: CleanupEngine = CleanupEngine(),
        history: HistoryStore? = .standard(),
        copier: ArchiveCopier = ArchiveCopier(),
        processes: @escaping @Sendable () -> ProcessSnapshot = { .current() },
        describe: @escaping @Sendable (ArchiveError) -> String = { String(describing: $0) }
    ) {
        self.engine = engine
        self.history = history
        self.copier = copier
        self.processes = processes
        self.describe = describe
    }

    /// Archive les projets dans `<volume>/<folderName>`. Annuler la tâche qui lit
    /// le flux (ou `progress.cancel()`) arrête la copie en cours ; ce qui était
    /// copié à moitié est retiré, l'original reste.
    public func run(_ projects: [ProjectCandidate], to destination: ArchiveDestination, folderName: String,
                    progress: ArchiveProgress = ArchiveProgress()) -> AsyncStream<ArchiveEvent> {
        AsyncStream { continuation in
            let task = Task {
                let outcomes = await execute(projects, to: destination, folderName: folderName, progress: progress) {
                    continuation.yield($0)
                }
                continuation.yield(.finished(outcomes))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                progress.cancel()
                task.cancel()
            }
        }
    }

    func execute(_ projects: [ProjectCandidate], to destination: ArchiveDestination, folderName: String,
                 progress: ArchiveProgress, emit: @Sendable (ArchiveEvent) -> Void) async -> [ArchiveOutcome] {
        let session = UUID()
        let folder = destination.volumeURL.appendingPathComponent(folderName, isDirectory: true)
        let archivable = projects.filter(\.isArchivable)
        emit(.began(total: archivable.count, bytes: archivable.reduce(0) { $0 + $1.sizes.allocated }))

        var outcomes: [ArchiveOutcome] = []
        for project in archivable {
            let outcome = await archive(project, into: folder, destination: destination, session: session,
                                        progress: progress, emit: emit)
            outcomes.append(outcome)
            emit(.projectFinished(outcome))
        }
        return outcomes
    }

    private func archive(_ project: ProjectCandidate, into folder: URL, destination: ArchiveDestination,
                         session: UUID, progress: ArchiveProgress,
                         emit: @Sendable (ArchiveEvent) -> Void) async -> ArchiveOutcome {
        if Task.isCancelled || progress.isCancelled {
            return ArchiveOutcome(project: project, copy: nil, result: .skipped(.cancelled), error: .cancelled, bytes: 0)
        }
        // L'original doit pouvoir partir avant d'engager la moindre copie.
        guard engine.supports(.trash) else {
            return ArchiveOutcome(project: project, copy: nil, result: .skipped(.refusedByGuard),
                                  error: .trashUnavailable, bytes: 0)
        }
        // Avant de copier : copier un projet où quelqu'un travaille, c'est
        // archiver un état qui n'existera plus dans une minute.
        let snapshot = processes()
        if let process = snapshot.busy(under: project.url.path) ?? snapshot.running(inside: project.url.path) {
            return ArchiveOutcome(project: project, copy: nil,
                                  result: .skipped(.nowProtected(.activeProcess(name: process.name))), error: nil, bytes: 0)
        }
        var root = stat()
        guard lstat(project.url.path, &root) == 0, UInt64(root.st_ino) == project.fileID || project.fileID == 0 else {
            return ArchiveOutcome(project: project, copy: nil, result: .skipped(.vanished), error: nil, bytes: 0)
        }
        // Déjà refusé par l'interface ; revérifié ici, juste avant d'agir.
        guard root.st_dev != destination.device else {
            return ArchiveOutcome(project: project, copy: nil, result: .skipped(.refusedByGuard), error: nil, bytes: 0)
        }
        let fingerprint = Fingerprint(modificationDate: Date(timeIntervalSince1970: TimeInterval(root.st_mtimespec.tv_sec)),
                                      fileID: UInt64(root.st_ino))

        emit(.projectBegan(id: project.id, step: .copying))
        let attempt = await Self.onDedicatedThread { [copier] in
            copier.copy(project.url, into: folder, appleDouble: destination.storesAppleDouble, progress: progress)
        }

        let item = CleanupItem(
            id: "archive|\(project.url.path)", title: project.name, detail: project.url.deletingLastPathComponent().path,
            paths: [project.url], category: .archives, owner: destination.name, ruleID: "archive.project",
            safety: .review, method: .archive(copy: (try? attempt.result.get())?.destination.path ?? folder.path),
            sizes: project.sizes, lastActivity: project.lastModified, rebuild: .irreversible,
            fingerprint: fingerprint, activityScope: project.url
        )

        let copy: ArchiveCopy
        switch attempt.result {
        case .success(let done):
            copy = done
        case .failure(let error):
            if let staging = attempt.staging { _ = ArchiveStaging.discard(staging) }
            if error == .cancelled {
                return ArchiveOutcome(project: project, copy: nil, result: .skipped(.cancelled), error: error, bytes: 0)
            }
            var failed = CleanupOutcome(sessionID: session, date: Date(), item: item,
                                        result: .failed(message: describe(error)), bytes: 0)
            failed.origin = engine.origin
            try? await history?.append(failed)
            return ArchiveOutcome(project: project, copy: nil, result: failed.result, error: error, bytes: 0)
        }

        // La copie est complète et vérifiée : l'original peut partir, par OustClean.
        emit(.projectBegan(id: project.id, step: .trashing))
        var trashed: CleanupOutcome?
        for await event in engine.run([item], session: session) {
            if case .itemFinished(let outcome) = event { trashed = outcome }
        }
        let result = trashed?.result ?? .skipped(.vanished)
        return ArchiveOutcome(project: project, copy: copy.destination, result: result, error: nil,
                              bytes: result.succeeded ? project.sizes.freeable : 0)
    }

    /// La copie est une longue suite d'appels système bloquants : un thread à
    /// elle, pour ne pas immobiliser le pool coopératif (même raison que
    /// `Scanner`).
    static func onDedicatedThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: work())
            }
            thread.name = "fr.meaillais.oust.archive"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
