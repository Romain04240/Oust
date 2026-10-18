import CoreServices
import Darwin
import Foundation

/// Ce qui a bougé sur le disque depuis une analyse, d'après FSEvents.
public struct FileSystemChanges: Sendable, Hashable {
    /// Dossiers dont le contenu direct a changé : fichiers ajoutés, retirés,
    /// renommés ou modifiés, sous-dossiers créés ou supprimés.
    public var directories: Set<String> = []
    /// Dossiers à reparcourir entièrement : FSEvents a perdu le détail
    /// (`MustScanSubDirs`, événements abandonnés par le noyau ou le démon).
    public var recursive: Set<String> = []
    /// L'historique ne permet pas de conclure : tout reparcourir.
    public var historyLost = false
    public var eventCount = 0

    public init() {}

    public var isEmpty: Bool { directories.isEmpty && recursive.isEmpty && !historyLost }
}

/// La mémoire du disque tenue par macOS (`fseventsd`), interrogée pour ne
/// relire que ce qui a changé.
///
/// Les identifiants d'événements sont globaux et persistants : on garde celui
/// d'avant l'analyse, et au lancement suivant FSEvents rejoue tout ce qui s'est
/// passé depuis, dossier par dossier. Rien ne tourne entre deux lancements.
public enum FileSystemEvents {

    /// L'identifiant du dernier événement, à mémoriser *avant* une analyse : ce
    /// qui change pendant qu'elle tourne sera rejoué la fois suivante.
    public static var currentEventID: UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// L'identité de la base d'événements d'un volume. Si elle change (base
    /// effacée, volume reformaté ou restauré), les identifiants mémorisés ne
    /// veulent plus rien dire.
    public static func database(forDevice device: dev_t) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(device) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public static func database(for path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return database(forDevice: info.st_dev)
    }

    /// Rejoue les événements survenus sous `paths` depuis `eventID`.
    ///
    /// S'arrête au signal `HistoryDone` ; au-delà de `timeout`, on ne sait pas
    /// ce qu'on a manqué, et on le dit (`historyLost`).
    public static func changes(since eventID: UInt64, under paths: [String],
                               timeout: TimeInterval = 60) async -> FileSystemChanges {
        let collector = Collector()
        return await withCheckedContinuation { continuation in
            collector.start(continuation)
            let queue = collector.queue
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, eventCallback, &context,
                                                   paths as CFArray, eventID, 0, flags) else {
                collector.finish(lost: true)
                return
            }
            collector.attach(stream)
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) {
                collector.finish(lost: true)
                return
            }
            queue.asyncAfter(deadline: .now() + timeout) { collector.finish(lost: true) }
        }
    }

    /// Reçoit les événements sur la file de FSEvents, rend le résultat une seule fois.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var changes = FileSystemChanges()
        private var continuation: CheckedContinuation<FileSystemChanges, Never>?
        private var stream: FSEventStreamRef?
        private var done = false
        let queue = DispatchQueue(label: "fr.meaillais.oust.fsevents", qos: .userInitiated)

        func start(_ continuation: CheckedContinuation<FileSystemChanges, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func attach(_ stream: FSEventStreamRef) {
            lock.withLock { self.stream = stream }
        }

        func receive(path: String, flags: FSEventStreamEventFlags) {
            let flag = { (mask: Int) in flags & FSEventStreamEventFlags(mask) != 0 }
            if flag(kFSEventStreamEventFlagHistoryDone) {
                finish(lost: false)
                return
            }
            lock.withLock {
                guard !done else { return }
                changes.eventCount += 1
                var path = path
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if flag(kFSEventStreamEventFlagEventIdsWrapped) || flag(kFSEventStreamEventFlagRootChanged) {
                    changes.historyLost = true
                } else if flag(kFSEventStreamEventFlagMustScanSubDirs) {
                    changes.recursive.insert(path)
                } else if flag(kFSEventStreamEventFlagMount) || flag(kFSEventStreamEventFlagUnmount) {
                    // Un volume monté ou démonté sous la racine : son dossier parent
                    // change d'allure, le volume lui-même n'est jamais parcouru.
                    changes.directories.insert((path as NSString).deletingLastPathComponent)
                } else {
                    changes.directories.insert(path)
                }
            }
        }

        func finish(lost: Bool) {
            let (continuation, stream, result): (CheckedContinuation<FileSystemChanges, Never>?, FSEventStreamRef?, FileSystemChanges) =
                lock.withLock {
                    guard !done else { return (nil, nil, changes) }
                    done = true
                    if lost { changes.historyLost = true }
                    let pending = (self.continuation, self.stream, changes)
                    self.continuation = nil
                    self.stream = nil
                    return pending
                }
            if let stream {
                // Pas depuis le rappel lui-même : on libère le flux une fois rendu
                // la main à sa file.
                let handle = StreamHandle(stream)
                queue.async { handle.tearDown() }
            }
            continuation?.resume(returning: result)
        }
    }
}

// MARK: - Suivi en direct

extension FileSystemEvents {

    /// Les fichiers créés, modifiés, renommés ou retirés sous `paths`, au fil
    /// de l'eau, par lots : FSEvents regroupe ce qui arrive en `latency`
    /// secondes, le premier événement d'une rafale partant sans attendre.
    ///
    /// Le suivi commence avant que la fonction rende la main ; il s'arrête
    /// quand plus personne ne lit le flux. Les chemins sont ceux du disque,
    /// liens résolus (`/private/var/…` pour `/var/…`).
    public static func watch(_ paths: [String], latency: TimeInterval = 0.3) -> AsyncStream<Set<String>> {
        AsyncStream { continuation in
            let watcher = Watcher(continuation)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(watcher).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, watchCallback, &context,
                                                   paths.map(resolved) as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
                continuation.finish()
                return
            }
            FSEventStreamSetDispatchQueue(stream, watcher.queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                continuation.finish()
                return
            }
            let handle = StreamHandle(stream)
            // Arrêté depuis sa file, où aucun rappel ne peut être en cours ; le
            // veilleur, que le flux ne retient pas, vit jusque-là.
            continuation.onTermination = { _ in
                watcher.queue.async {
                    handle.tearDown()
                    withExtendedLifetime(watcher) {}
                }
            }
        }
    }

    /// Le chemin, liens résolus, même s'il n'existe pas encore.
    ///
    /// FSEvents résout lui-même un chemin qui existe, pas un chemin à venir :
    /// un dossier pas encore créé sous `/var/folders` n'était jamais reconnu
    /// dans les événements, qui arrivent en `/private/var/folders`.
    static func resolved(_ path: String) -> String {
        var missing: [String] = []
        var existing = path
        while existing.count > 1, access(existing, F_OK) != 0 {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let real = realpath(existing, nil) else { return path }
        defer { free(real) }
        return missing.reduce(String(cString: real)) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// Reçoit les lots sur la file de FSEvents et les passe au flux.
    final class Watcher: Sendable {
        let continuation: AsyncStream<Set<String>>.Continuation
        let queue = DispatchQueue(label: "fr.meaillais.oust.fsevents.watch", qos: .utility)

        init(_ continuation: AsyncStream<Set<String>>.Continuation) {
            self.continuation = continuation
        }

        func receive(_ paths: Set<String>) {
            continuation.yield(paths)
        }
    }
}

/// Le rappel du suivi en direct : comme `eventCallback`, sans capture.
private let watchCallback: FSEventStreamCallback = { _, info, count, paths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<FileSystemEvents.Watcher>.fromOpaque(info).takeUnretainedValue()
    let list = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    watcher.receive(Set((0..<count).map { String(cString: list[$0]) }))
}

/// Un flux à arrêter depuis sa file.
private struct StreamHandle: @unchecked Sendable {
    let stream: FSEventStreamRef
    init(_ stream: FSEventStreamRef) { self.stream = stream }
    func tearDown() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// Le rappel de FSEvents : une fonction C, sans capture, qui retrouve son
/// collecteur par le pointeur de contexte.
private let eventCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    let collector = Unmanaged<FileSystemEvents.Collector>.fromOpaque(info).takeUnretainedValue()
    let list = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    for index in 0..<count {
        collector.receive(path: String(cString: list[index]), flags: flags[index])
    }
}
