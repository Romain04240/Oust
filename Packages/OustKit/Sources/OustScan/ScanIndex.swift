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
    let scannedRootLocation: PreferenceDirectory
    let preferenceDirectory: PreferenceDirectory?
    let accountArchiveDirectory: PreferenceDirectory
    let deviceBackupDirectory: DeviceBackupPath.Snapshot

    public var rootPath: String { root.path }

    package var hasCurrentProtectionRoots: Bool {
        !deviceBackupDirectory.uncertain
            && (options.deviceBackupsDirectory == nil || (scannedRootLocation.identity != nil
                && scannedRootLocation == PreferenceDirectory.capturingLocation(at: rootPath)))
            && preferenceDirectory == PreferenceDirectory.capturingLocation(at: options.readOnlyPreferencesDirectory)
            && accountArchiveDirectory == PreferenceDirectory.capturingLocation(at: options.accountArchivesDirectory)
            && deviceBackupDirectory == DeviceBackupPath.Snapshot.capture(options.deviceBackupsDirectory)
    }

    package var hasWithheldGains: Bool { preferenceDirectory == nil }

    package func canReuse(for options: ScanOptions) -> Bool {
        self.options.describesSameTree(as: options) && hasCurrentProtectionRoots
    }

    package func checkedForDisplay(for options: ScanOptions? = nil) -> ScanIndex {
        guard !hasWithheldGains, !canReuse(for: options ?? self.options) else { return self }
        return withholdingGains()
    }

    package func revalidatedForDisplay(for options: ScanOptions? = nil) async -> ScanIndex {
        guard !hasWithheldGains else { return self }
        if await checkStorageIO({ canReuse(for: options ?? self.options) }) == true { return self }
        return await Task.detached { withholdingGains() }.value
    }

    package var hasDeviceBackupProtection: Bool { options.deviceBackupsDirectory != nil }

    package func withholdingGains() -> ScanIndex {
        guard !hasWithheldGains else { return self }
        let safeRoot = root.clone()
        safeRoot.suppressFreeable()
        return ScanIndex(root: safeRoot, options: self.options, ownership: ownership, eventID: eventID, eventDatabase: eventDatabase,
                         scannedAt: scannedAt, fullScanAt: fullScanAt, skippedVolumes: skippedVolumes, scannedRootLocation: scannedRootLocation, preferenceDirectory: nil,
                         accountArchiveDirectory: accountArchiveDirectory, deviceBackupDirectory: deviceBackupDirectory)
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
        await refresh(previous, root: root, options: options, progress: progress, maximumAge: maximumAge,
                      now: now, boundRoot: nil)
    }

    package static func refreshBound(
        _ previous: ScanIndex?, root: AnalysisRoot, options: ScanOptions, progress: ScanProgress
    ) async -> (index: ScanIndex, how: IndexRefresh) {
        var options = options
        options.bindMeasurementsToRoots = true
        options.boundRootIdentity = root.identity
        return await refresh(previous, root: root.url, options: options, progress: progress,
                             maximumAge: 7 * 86_400, now: Date(), boundRoot: root)
    }

    private static func refresh(
        _ previous: ScanIndex?, root: URL, options: ScanOptions, progress: ScanProgress,
        maximumAge: TimeInterval, now: Date, boundRoot: AnalysisRoot?
    ) async -> (index: ScanIndex, how: IndexRefresh) {
        let rootPath = options.bindMeasurementsToRoots ? root.path : root.standardizedFileURL.path
        guard let previous, previous.rootPath == rootPath,
              previous.options.boundRootIdentity == boundRoot?.identity else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now, boundRoot: boundRoot), .full(.noIndex))
        }
        guard await checkStorageIO({ previous.canReuse(for: options) }) == true else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now, boundRoot: boundRoot), .full(.optionsChanged))
        }
        guard now.timeIntervalSince(previous.fullScanAt) < maximumAge else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now, boundRoot: boundRoot), .full(.tooOld))
        }
        // Base d'événements effacée, recréée ou absente : les identifiants
        // mémorisés ne désignent plus rien, et l'historique est perdu.
        let database = FileSystemEvents.database(for: rootPath)
        let start = FileSystemEvents.currentEventID
        guard let database, database == previous.eventDatabase, previous.eventID <= start else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now, boundRoot: boundRoot), .full(.historyLost))
        }
        let changes = await FileSystemEvents.changes(since: previous.eventID, under: [rootPath])
        if changes.historyLost {
            return (await fullScan(rootPath, options: options, progress: progress, now: now, boundRoot: boundRoot), .full(.historyLost))
        }
        guard await checkStorageIO({ previous.hasCurrentProtectionRoots }) == true else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now, boundRoot: boundRoot), .full(.optionsChanged))
        }
        if changes.directories.isEmpty && changes.recursive.isEmpty {
            let index = ScanIndex(root: previous.root, options: options, ownership: previous.ownership,
                                  eventID: start, eventDatabase: database, scannedAt: now,
                                  fullScanAt: previous.fullScanAt, skippedVolumes: previous.skippedVolumes,
                                  scannedRootLocation: previous.scannedRootLocation,
                                  preferenceDirectory: previous.preferenceDirectory,
                                  accountArchiveDirectory: previous.accountArchiveDirectory,
                                  deviceBackupDirectory: previous.deviceBackupDirectory)
            return (index, .unchanged)
        }
        guard let updated = await previous.applying(changes, eventID: start, database: database,
                                                    progress: progress, now: now, boundRoot: boundRoot) else {
            return (await fullScan(rootPath, options: options, progress: progress, now: now, boundRoot: boundRoot), .full(.tooManyChanges))
        }
        return updated
    }

    static func fullScan(_ rootPath: String, options: ScanOptions, progress: ScanProgress, now: Date,
                         boundRoot: AnalysisRoot? = nil) async -> ScanIndex {
        // L'identifiant d'avant le parcours : ce qui bouge pendant qu'il tourne
        // sera rejoué la prochaine fois, au pire relu deux fois.
        let start = FileSystemEvents.currentEventID
        let database = FileSystemEvents.database(for: rootPath)
        let location = options.deviceBackupsDirectory == nil ? PreferenceDirectory(nil) :
            await checkStorageIO { PreferenceDirectory.capturingLocation(at: rootPath) } ?? PreferenceDirectory(nil)
        let result = await Scanner.scan([URL(fileURLWithPath: rootPath)], options: options, progress: progress,
                                        boundRoot: boundRoot)
        let root = result.roots.first ?? TreeNode(name: (rootPath as NSString).lastPathComponent,
                                                  parent: nil, fileID: 0, rootPath: rootPath)
        let stableRoot: Bool
        if options.deviceBackupsDirectory == nil {
            stableRoot = true
        } else {
            let current = await checkStorageIO { PreferenceDirectory.capturingLocation(at: rootPath) }
            stableRoot = location == current && location.identity?.inode == root.fileID
                && location.identity?.device == root.measurementDevice && !location.isUncertain
            if !stableRoot { root.suppressFreeable() }
        }
        return ScanIndex(root: root, options: options, ownership: result.ownership, eventID: start,
                         eventDatabase: database, scannedAt: now, fullScanAt: now,
                         skippedVolumes: result.skippedVolumes, scannedRootLocation: location,
                         preferenceDirectory: stableRoot ? result.preferenceDirectory : nil,
                         accountArchiveDirectory: result.accountArchiveDirectory, deviceBackupDirectory: result.deviceBackupDirectory)
    }

    /// Relit les dossiers signalés, sur une copie de l'arbre.
    ///
    /// `nil` quand il y a tant à relire qu'un parcours complet ira aussi vite.
    func applying(_ changes: FileSystemChanges, eventID: UInt64, database: String, progress: ScanProgress,
                  now: Date, boundRoot: AnalysisRoot? = nil) async -> (index: ScanIndex, how: IndexRefresh)? {
        guard await checkStorageIO({ hasCurrentProtectionRoots }) == true else { return nil }
        let root = root.clone()
        let ownership = ownership.copy()
        var info = stat()
        let device: dev_t
        if let boundRoot {
            device = boundRoot.identity.directory.device
        } else {
            guard lstat(root.path, &info) == 0 else { return nil }
            device = info.st_dev
        }

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
        func openDirectory(_ node: TreeNode) -> Int32 {
            if let boundRoot {
                return boundRoot.openDirectory(URL(fileURLWithPath: node.path, isDirectory: true)) ?? -1
            }
            return open(node.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        func opens(_ node: TreeNode) -> Bool {
            let fd = openDirectory(node)
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
            if boundRoot != nil {
                let fd = openDirectory(node)
                node.ownLatestModification = fd >= 0 && fstat(fd, &stats) == 0 ? Walk.date(stats.st_mtimespec) : nil
                if fd >= 0 { close(fd) }
            } else {
                node.ownLatestModification = lstat(node.path, &stats) == 0 ? Walk.date(stats.st_mtimespec) : nil
            }
            jobs.append(Walk.Job(node: node, path: node.path, device: device, shallow: nil))
        }
        for node in shallowNodes {
            let known = Dictionary(node.children.map { ($0.name, Walk.Known(node: $0, fileID: $0.fileID, status: $0.status)) },
                                   uniquingKeysWith: { first, _ in first })
            jobs.append(Walk.Job(node: node, path: node.path, device: device, shallow: known))
        }

        guard let backups = await checkStorageIO({ DeviceBackupPath.Snapshot.capture(options.deviceBackupsDirectory) }),
              !backups.uncertain else { return nil }
        let walk = Walk(options: options, progress: progress, ownership: ownership, deviceBackupDirectory: backups, boundRoot: boundRoot)
        guard walk.preferenceDirectory == preferenceDirectory, walk.accountArchiveDirectory == accountArchiveDirectory,
              walk.deviceBackupDirectory == deviceBackupDirectory else { return nil }
        dropped += await walk.run(jobs: jobs, root: root)
        guard !walk.sawStaleDirectories,
              await checkStorageIO({ walk.hasCurrentProtectionRoots && hasCurrentProtectionRoots }) == true,
              !progress.isCancelled else { return nil }

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
                              skippedVolumes: skipped, scannedRootLocation: scannedRootLocation, preferenceDirectory: preferenceDirectory, accountArchiveDirectory: accountArchiveDirectory, deviceBackupDirectory: deviceBackupDirectory)
        return (index, .incremental(directories: jobs.count))
    }
}

extension ScanOptions {
    /// Deux réglages qui donnent le même arbre (le nombre de threads n'y change rien).
    func describesSameTree(as other: ScanOptions) -> Bool {
        leafThreshold == other.leafThreshold && measurePrivateSizes == other.measurePrivateSizes
            && boundRootIdentity == other.boundRootIdentity
            && excludedPaths == other.excludedPaths && notableNames == other.notableNames
            && readOnlyPreferencesDirectory == other.readOnlyPreferencesDirectory
            && accountArchivesDirectory == other.accountArchivesDirectory && deviceBackupsDirectory == other.deviceBackupsDirectory
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
