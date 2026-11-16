import Darwin
import Foundation
import OustSafety
import Synchronization

/// Les métadonnées des révisions d'un document choisi. Les URL des versions
/// restent dans Foundation et n'entrent jamais dans le modèle du nettoyage.
package struct DocumentVersionHistory: Identifiable, Sendable {
    private let url: URL

    package var id: URL { url }
    package var name: String { url.lastPathComponent }

    package init(url: URL) { self.url = url }

    package func prepare() async -> Prepared? {
        await prepare(resolve: PathGuard.withResolvedParent)
    }

    private static let workers = HistoryWorkers()

    func prepare(resolve: @escaping @Sendable (URL) -> URL?) async -> Prepared? {
        let reply = HistoryReply<Prepared>()
        let prepared = await withTaskCancellationHandler { @Sendable in
            await withCheckedContinuation { continuation in
                guard reply.install(continuation) else { return }
                if !Self.workers.submit({ _ in
                    let prepared: Prepared? = Self.withoutMaterializing {
                        guard !reply.isFinished, let resolved = resolve(url), !reply.isFinished,
                              let selection = HistorySelection(resolved, cancelled: { reply.isFinished }),
                              PathGuard.withResolvedParent(url) == resolved else { return nil }
                        return Prepared(url: url, resolved: resolved, selection: selection)
                    }
                    reply.finish(prepared)
                }) { reply.finish(nil) }
            }
        } onCancel: {
            reply.finish(nil)
        }
        return Task.isCancelled ? nil : prepared
    }

    /// Cette politique ne traverse ni une suspension Swift ni un changement de fil.
    static func withoutMaterializing<Result>(_ access: () -> Result?) -> Result? {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let previous = getiopolicy_np(type, scope)
        guard previous >= 0, setiopolicy_np(type, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            return nil
        }
        defer { _ = setiopolicy_np(type, scope, previous) }
        return access()
    }

    static let readOptions: NSFileCoordinator.ReadingOptions = [.withoutChanges, .immediatelyAvailableMetadataOnly]

    package struct Prepared: Sendable {
        fileprivate let url: URL
        fileprivate let resolved: URL
        fileprivate let selection: HistorySelection

        package var path: String { resolved.path }
        package var modificationDate: Date { selection.documentFacts.modificationDate }
        package var byteCount: Int64 { selection.documentFacts.size }

        package func revisionDates() async -> [Date?]? {
            await revisionDates { document in
                NSFileVersion.otherVersionsOfItem(at: document)?
                    .filter { $0.hasLocalContents && !$0.isConflict }
                    .map(\.modificationDate)
                    .sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) }
            }
        }

        func revisionDates(read: @escaping @Sendable (URL) -> [Date?]?) async -> [Date?]? {
            let request = HistoryCoordination()
            let reply = HistoryReply<[Date?]>()
            let dates = await withTaskCancellationHandler { @Sendable in
                await withCheckedContinuation { (continuation: CheckedContinuation<[Date?]?, Never>) in
                    guard reply.install(continuation) else { return }
                    if !DocumentVersionHistory.workers.submit({ slot in
                        let registered: Bool? = DocumentVersionHistory.withoutMaterializing {
                            guard !reply.isFinished, selectionIsCurrent() else { return nil }
                            let intent = NSFileAccessIntent.readingIntent(with: resolved, options: DocumentVersionHistory.readOptions)
                            let queue = OperationQueue()
                            queue.qualityOfService = .userInitiated
                            return request.cancelled.withLock { isCancelled in
                                guard !isCancelled, !reply.isFinished else { return false }
                                slot.beginCoordination()
                                request.coordinator.coordinate(with: [intent], queue: queue) { error in
                                    defer { slot.finish() }
                                    let dates: [Date?]? = DocumentVersionHistory.withoutMaterializing {
                                        guard error == nil, !reply.isFinished,
                                              intent.url.path == resolved.path, selectionIsCurrent(),
                                              !reply.isFinished else { return nil }
                                        let result = read(intent.url)
                                        return !reply.isFinished && selectionIsCurrent() ? result : nil
                                    }
                                    reply.finish(dates)
                                }
                                return true
                            }
                        }
                        if registered != true { reply.finish(nil) }
                    }) { reply.finish(nil) }
                }
            } onCancel: {
                reply.finish(nil)
                request.cancelled.withLock { $0 = true }
                request.coordinator.cancel()
            }
            return Task.isCancelled ? nil : dates
        }

        private func selectionIsCurrent() -> Bool {
            PathGuard.withResolvedParent(url) == resolved && selection.isCurrent()
        }
    }
}

/// Un appel disque bloqué conserve sa place jusqu’à son retour. Les nouvelles
/// demandes reçoivent une réponse immédiate lorsque les deux places sont prises.
private final class HistoryWorkers: Sendable {
    private let active = Mutex(0)
    private let queue = DispatchQueue(label: "fr.meaillais.oust.document-history", qos: .userInitiated,
                                      attributes: .concurrent)

    func submit(_ work: @escaping @Sendable (HistoryWorkSlot) -> Void) -> Bool {
        let reserved = active.withLock { count in
            guard count < 2 else { return false }
            count += 1
            return true
        }
        guard reserved else { return false }
        let slot = HistoryWorkSlot { self.active.withLock { $0 -= 1 } }
        queue.async {
            defer { slot.finish() }
            work(slot)
        }
        return true
    }
}

/// La soumission et le rappel peuvent se terminer dans un ordre quelconque.
/// Une place n’est rendue qu’après le retour des deux.
private final class HistoryWorkSlot: Sendable {
    private let pending = Mutex(1)
    private let release: @Sendable () -> Void

    init(release: @escaping @Sendable () -> Void) { self.release = release }

    func beginCoordination() {
        pending.withLock { $0 += 1 }
    }

    func finish() {
        let done = pending.withLock { count in
            count -= 1
            return count == 0
        }
        if done { release() }
    }
}

/// L’annulation rend la main même si le système n’a pas encore rendu le fil.
private final class HistoryReply<Value: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Value?, Never>)
        case finished
    }

    private let state = Mutex(State.idle)

    var isFinished: Bool {
        state.withLock { if case .finished = $0 { true } else { false } }
    }

    func install(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        let installed = state.withLock { state in
            guard case .idle = state else { return false }
            state = .waiting(continuation)
            return true
        }
        if !installed { continuation.resume(returning: nil) }
        return installed
    }

    func finish(_ value: Value?) {
        let continuation = state.withLock { state -> CheckedContinuation<Value?, Never>? in
            defer { state = .finished }
            if case .waiting(let continuation) = state { return continuation }
            return nil
        }
        continuation?.resume(returning: value)
    }
}

/// Une seule demande. Foundation autorise explicitement l’appel à cancel()
/// depuis un autre fil pendant cette coordination.
private final class HistoryCoordination: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
    let cancelled = Mutex(false)
}

/// Les événements vnode restent en attente dans la file même si un dossier
/// reprend sa place avant le contrôle suivant. Les écritures dans un dossier
/// (par exemple l’arrivée d’un fichier voisin) ne sont pas des renommages.
private final class HistorySelection: Sendable {
    private struct Entry {
        let path: String
        let descriptor: Int32
        let facts: FileFacts
    }

    private let events: Int32
    private let entries: [Entry]
    private let invalidated = Mutex(false)

    var documentFacts: FileFacts { entries[entries.count - 1].facts }

    init?(_ url: URL, cancelled: () -> Bool) {
        guard !url.pathComponents.contains(where: { $0.caseInsensitiveCompare(".DocumentRevisions-V100") == .orderedSame })
        else { return nil }

        var paths = [url.path]
        var parent = url.deletingLastPathComponent()
        while !parent.path.isEmpty {
            paths.append(parent.path)
            if parent.path == "/" { break }
            parent.deleteLastPathComponent()
        }

        let events = kqueue()
        guard events >= 0 else { return nil }
        var entries: [Entry] = []
        var installed = false
        defer {
            if !installed {
                close(events)
                for entry in entries { close(entry.descriptor) }
            }
        }
        guard fcntl(events, F_SETFD, FD_CLOEXEC) == 0 else { return nil }

        for path in paths.reversed() {
            guard !cancelled() else { return nil }
            let isFile = path == url.path
            let options = O_EVTONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK | (isFile ? 0 : O_DIRECTORY)
            let descriptor = open(path, options)
            guard descriptor >= 0 else { return nil }
            guard let facts = FileFacts.openFile(descriptor), !facts.isDataless, !isFile || facts.isRegularFile else {
                close(descriptor)
                return nil
            }
            entries.append(Entry(path: path, descriptor: descriptor, facts: facts))
            var event = kevent()
            event.ident = UInt(descriptor)
            event.filter = Int16(EVFILT_VNODE)
            event.flags = UInt16(EV_ADD | EV_CLEAR)
            event.fflags = UInt32(NOTE_RENAME | NOTE_DELETE | NOTE_REVOKE)
            guard kevent(events, &event, 1, nil, 0, nil) == 0 else { return nil }
        }
        self.events = events
        self.entries = entries
        installed = true
        guard isCurrent() else { return nil }
    }

    deinit {
        close(events)
        for entry in entries { close(entry.descriptor) }
    }

    func isCurrent() -> Bool {
        invalidated.withLock { invalid in
            guard !invalid else { return false }
            var event = kevent()
            var timeout = timespec()
            let unchanged = entries.allSatisfy { entry in
                guard let current = FileFacts.of(entry.path) else { return false }
                let expected = entry.facts
                guard current.device == expected.device, current.inode == expected.inode,
                      current.created.tv_sec == expected.created.tv_sec,
                      current.created.tv_nsec == expected.created.tv_nsec,
                      current.mode == expected.mode, current.flags == expected.flags else { return false }
                return !expected.isRegularFile || current.isUnchanged(comparedTo: expected)
            }
            invalid = !unchanged || kevent(events, nil, 0, &event, 1, &timeout) != 0
            return !invalid
        }
    }
}
