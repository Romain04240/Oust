import Darwin
import Foundation
import OustCore

/// Une arborescence analysée, et de quoi la tenir à jour sans tout relire.
///
/// Une valeur : la réanalyse incrémentale rend un nouvel index (sur une copie de
/// l'arbre) et ne touche jamais celui qu'on lui donne, que l'Explorateur est
/// peut-être en train de lire.
public struct ScanIndex: Sendable {
    public let root: TreeNode
    public let options: ScanOptions
    let ownership: Ownership
    /// FSEvents : où reprendre, et dans quelle base d'événements.
    public let eventID: UInt64
    public let eventDatabase: String?
    public let scannedAt: Date
    /// Le dernier parcours complet. Au-delà d'une semaine, on repart de zéro :
    /// les petites dérives (un lien physique dont le dossier compteur a
    /// disparu) ne s'accumulent pas.
    public let fullScanAt: Date
    public let skippedVolumes: [String]
    let preferenceDirectory: PreferenceDirectory?

    public var rootPath: String { root.path }

    package var hasCurrentPreferenceDirectory: Bool {
        preferenceDirectory == PreferenceDirectory.capturingLocation(at: options.readOnlyPreferencesDirectory)
    }

    package var hasWithheldGains: Bool { preferenceDirectory == nil }

    package func canReuse(for options: ScanOptions) -> Bool {
        self.options.describesSameTree(as: options) && hasCurrentPreferenceDirectory
    }

    package func checkedForDisplay(for options: ScanOptions? = nil) -> ScanIndex {
        guard !hasWithheldGains, !canReuse(for: options ?? self.options) else { return self }
        let safeRoot = root.clone()
        safeRoot.suppressFreeable()
        return ScanIndex(root: safeRoot, options: self.options, ownership: ownership, eventID: eventID, eventDatabase: eventDatabase,
                         scannedAt: scannedAt, fullScanAt: fullScanAt, skippedVolumes: skippedVolumes, preferenceDirectory: nil)
    }
}

/// Comment l'index a été rafraîchi.
public enum IndexRefresh: Sendable, Hashable {
    /// Tout relu, et pourquoi.
    case full(FullScanReason)
    /// Seuls ces dossiers ont été relus.
    case incremental(directories: Int)
    /// FSEvents n'a rien signalé.
    case unchanged

    public enum FullScanReason: Sendable, Hashable {
        case noIndex, optionsChanged, tooOld, historyLost, tooManyChanges
    }
}

extension ScanIndex {

    /// Rend un index à jour : depuis `previous` si FSEvents sait ce qui a
    /// changé, par un parcours complet sinon.
    public static func refresh(
        _ previous: ScanIndex?,
        root: URL,
        options: ScanOptions,
        progress: ScanProgress = ScanProgress(),
        maximumAge: TimeInterval = 7 * 86_400,
        now: Date = Date()
    ) async -> (index: ScanIndex, how: IndexRefresh) {
        let rootPath = root.standardizedFileURL.path
        guard let previous, previous.rootPath == rootPath else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now), .full(.noIndex))
        }
        guard previous.canReuse(for: options) else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now), .full(.optionsChanged))
        }
        guard now.timeIntervalSince(previous.fullScanAt) < maximumAge else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now), .full(.tooOld))
        }
        // Base d'événements effacée, recréée ou absente : les identifiants
        // mémorisés ne désignent plus rien, et l'historique est perdu.
        let database = FileSystemEvents.database(for: rootPath)
        let start = FileSystemEvents.currentEventID
        guard let database, database == previous.eventDatabase, previous.eventID <= start else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now), .full(.historyLost))
        }
        let changes = await FileSystemEvents.changes(since: previous.eventID, under: [rootPath])
        if changes.historyLost {
            return (await fullScan(rootPath, options: options, progress: progress, now: now), .full(.historyLost))
        }
        guard previous.hasCurrentPreferenceDirectory else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now), .full(.optionsChanged))
        }
        if changes.directories.isEmpty && changes.recursive.isEmpty {
            let index = ScanIndex(root: previous.root, options: options, ownership: previous.ownership,
                                  eventID: start, eventDatabase: database, scannedAt: now,
                                  fullScanAt: previous.fullScanAt, skippedVolumes: previous.skippedVolumes,
                                  preferenceDirectory: previous.preferenceDirectory)
            return (index, .unchanged)
        }
        guard let updated = await previous.applying(changes, eventID: start, database: database,
                                                    progress: progress, now: now) else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now), .full(.tooManyChanges))
        }
        return updated
    }

    static func fullScan(_ rootPath: String, options: ScanOptions, progress: ScanProgress, now: Date) async -> ScanIndex {
        // L'identifiant d'avant le parcours : ce qui bouge pendant qu'il tourne
        // sera rejoué la prochaine fois, au pire relu deux fois.
        let start = FileSystemEvents.currentEventID
        let database = FileSystemEvents.database(for: rootPath)
        let result = await Scanner.scan([URL(fileURLWithPath: rootPath)], options: options, progress: progress)
        let root = result.roots[0]
        return ScanIndex(root: root, options: options, ownership: result.ownership, eventID: start,
                         eventDatabase: database, scannedAt: now, fullScanAt: now,
                         skippedVolumes: result.skippedVolumes, preferenceDirectory: result.preferenceDirectory)
    }

    /// Relit les dossiers signalés, sur une copie de l'arbre.
    ///
    /// `nil` quand il y a tant à relire qu'un parcours complet ira aussi vite.
    func applying(_ changes: FileSystemChanges, eventID: UInt64, database: String, progress: ScanProgress,
                  now: Date) async -> (index: ScanIndex, how: IndexRefresh)? {
        guard hasCurrentPreferenceDirectory else { return nil }
        let root = root.clone()
        let ownership = ownership.copy()
        var info = stat()
        guard lstat(root.path, &info) == 0 else { return nil }
        let device = info.st_dev

        // Chaque chemin signalé devient un dossier de l'arbre. Un dossier
        // inconnu (créé depuis) : c'est son plus proche parent connu qu'on
        // relit, il le découvrira.
        var deep: [ObjectIdentifier: TreeNode] = [:]
        var shallow: [ObjectIdentifier: TreeNode] = [:]
        func locate(_ path: String) -> (node: TreeNode, exact: Bool)? {
            guard var components = root.relativeComponents(of: path) else { return nil }
            var exact = true
            while true {
                var node = root
                var found = true
                for component in components {
                    guard node.status == .ok, let next = node.child(named: component) else { found = false; break }
                    node = next
                }
                if found { return node.status == .ok ? (node, exact) : nil }
                guard !components.isEmpty else { return nil }
                components.removeLast()
                exact = false
            }
        }
        for path in changes.recursive {
            guard let (node, exact) = locate(path) else { continue }
            if node === root && exact { return nil }
            if exact { deep[ObjectIdentifier(node)] = node } else { shallow[ObjectIdentifier(node)] = node }
        }
        for path in changes.directories {
            guard let (node, _) = locate(path) else { continue }
            shallow[ObjectIdentifier(node)] = node
        }
        // Un dossier refusé hier peut être lisible aujourd'hui (accès complet au
        // disque accordé entre deux lancements), sans que FSEvents ne dise rien.
        // Chaque `open` refusé par TCC coûte 3 ms (803 dossiers : 2,7 s, mesuré
        // le 18/10/2026) : on en essaie trois, et tous seulement si l'un d'eux
        // s'ouvre. L'accès complet s'accorde en bloc, pas dossier par dossier.
        let (total, refused) = root.census()
        func opens(_ node: TreeNode) -> Bool {
            let fd = open(node.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            close(fd)
            return true
        }
        let sample = stride(from: 0, to: refused.count, by: max(1, refused.count / 3)).prefix(3).map { refused[$0] }
        if sample.contains(where: opens) {
            for node in refused where opens(node) { deep[ObjectIdentifier(node)] = node }
        }

        // Rien à relire sous une branche qu'on reparcourt entièrement, et jamais
        // deux relectures du même dossier : deux threads y écriraient.
        func coveredByDeep(_ node: TreeNode) -> Bool {
            var current = node.parent
            while let ancestor = current {
                if deep[ObjectIdentifier(ancestor)] != nil { return true }
                current = ancestor.parent
            }
            return false
        }
        let deepNodes = deep.values.filter { !coveredByDeep($0) }
        let shallowNodes = shallow.values.filter { deep[ObjectIdentifier($0)] == nil && !coveredByDeep($0) }

        // Au-delà d'un dossier sur cinq, la relecture ciblée ne gagne plus rien.
        guard deepNodes.count + shallowNodes.count <= max(1_000, total / 5) else { return nil }

        var dropped: [TreeNode] = []
        var jobs: [Walk.Job] = []
        for node in deepNodes {
            dropped += node.children
            node.children = []
            node.resetOwnContent()
            node.status = NodeStatus.ok
            var stats = stat()
            node.ownLatestModification = lstat(node.path, &stats) == 0 ? Walk.date(stats.st_mtimespec) : nil
            jobs.append(Walk.Job(node: node, path: node.path, device: device, shallow: nil))
        }
        for node in shallowNodes {
            let known = Dictionary(node.children.map { ($0.name, Walk.Known(node: $0, fileID: $0.fileID, status: $0.status)) },
                                   uniquingKeysWith: { first, _ in first })
            jobs.append(Walk.Job(node: node, path: node.path, device: device, shallow: known))
        }

        let walk = Walk(options: options, progress: progress, ownership: ownership)
        guard walk.preferenceDirectory == preferenceDirectory else { return nil }
        dropped += await walk.run(jobs: jobs, root: root)
        guard !progress.isCancelled, walk.hasCurrentPreferenceDirectory else { return nil }

        // Les dossiers disparus ne comptent plus leurs liens physiques et leurs
        // clones ; un dossier simplement déplacé garde son inode, donc les siens.
        var gone = Set<UInt64>()
        var stack = dropped
        while let node = stack.popLast() {
            gone.insert(node.fileID)
            stack.append(contentsOf: node.children)
        }
        gone.subtract(walk.touchedFileIDs)
        ownership.release(owners: gone)

        let skipped = Array(Set(skippedVolumes).union(walk.skippedVolumes)).sorted()
        let index = ScanIndex(root: root, options: options, ownership: ownership, eventID: eventID,
                              eventDatabase: database, scannedAt: now, fullScanAt: fullScanAt,
                              skippedVolumes: skipped, preferenceDirectory: preferenceDirectory)
        return (index, .incremental(directories: jobs.count))
    }
}

extension ScanOptions {
    /// Deux réglages qui donnent le même arbre (le nombre de threads n'y change rien).
    func describesSameTree(as other: ScanOptions) -> Bool {
        leafThreshold == other.leafThreshold && measurePrivateSizes == other.measurePrivateSizes
            && excludedPaths == other.excludedPaths && notableNames == other.notableNames
            && readOnlyPreferencesDirectory == other.readOnlyPreferencesDirectory
    }
}

extension TreeNode {
    /// Le nombre de dossiers de l'arbre (celui-ci compris), et ceux que macOS a
    /// refusés.
    func census() -> (directories: Int, refused: [TreeNode]) {
        var count = 0
        var refused: [TreeNode] = []
        var stack: [TreeNode] = [self]
        while let node = stack.popLast() {
            count += 1
            if node.status.isInaccessible { refused.append(node) }
            stack.append(contentsOf: node.children)
        }
        return (count, refused)
    }
}
