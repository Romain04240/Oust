import Darwin
import Foundation
import OustCore
import Synchronization

/// Réglages d'une analyse.
public struct ScanOptions: Sendable, Hashable {
    /// Entre 4 et 12 threads : au-delà, la limite de threads par utilisateur de
    /// macOS et la contention du disque mangent le gain (observé par Mole).
    public var threads: Int
    /// En dessous, un fichier rejoint les « petits éléments » de son dossier.
    public var leafThreshold: Int64
    /// Demander la part privée des fichiers qui partagent des blocs.
    public var measurePrivateSizes: Bool
    /// Chemins à ne pas parcourir.
    public var excludedPaths: Set<String>
    /// Petits fichiers à retenir par leur nom (marqueurs de projets) : les règles
    /// les cherchent dans l'arbre au lieu de relister les dossiers. `*.ext` :
    /// une extension ; `._*` : un préfixe (les fichiers AppleDouble d'un disque
    /// exFAT, que la règle des traces de macOS compte).
    public var notableNames: Set<String>

    public init(
        threads: Int = min(12, max(4, ProcessInfo.processInfo.activeProcessorCount)),
        leafThreshold: Int64 = 1_000_000,
        measurePrivateSizes: Bool = true,
        excludedPaths: Set<String> = [],
        notableNames: Set<String> = []
    ) {
        self.threads = threads
        self.leafThreshold = leafThreshold
        self.measurePrivateSizes = measurePrivateSizes
        self.excludedPaths = excludedPaths
        self.notableNames = notableNames
    }

    /// Pour mesurer des éléments : pas de feuilles, juste des totaux.
    public static var measuring: ScanOptions {
        ScanOptions(leafThreshold: .max)
    }
}

/// L'avancement d'une analyse, lisible depuis l'interface pendant qu'elle tourne.
public final class ScanProgress: Sendable {
    private let files = Atomic<Int>(0)
    private let directories = Atomic<Int>(0)
    private let bytes = Atomic<Int64>(0)
    private let cancelled = Atomic<Bool>(false)

    public init() {}

    public var fileCount: Int { files.load(ordering: .relaxed) }
    public var directoryCount: Int { directories.load(ordering: .relaxed) }
    public var allocatedBytes: Int64 { bytes.load(ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }

    func add(files count: Int, bytes size: Int64) {
        files.add(count, ordering: .relaxed)
        bytes.add(size, ordering: .relaxed)
    }

    func addDirectory() { directories.add(1, ordering: .relaxed) }
}

/// Ce qu'une analyse rend.
public struct ScanResult: Sendable {
    public let roots: [TreeNode]
    public let duration: TimeInterval
    public let skippedVolumes: [String]
    /// Qui compte chaque lien physique et chaque clone : de quoi réanalyser un
    /// dossier plus tard sans compter deux fois ni oublier.
    let ownership: Ownership

    public var root: TreeNode? { roots.first }
}

/// Ce que mesure `Scanner.measure` pour un élément.
public struct Measurement: Sendable, Hashable {
    public var sizes: Sizes
    public var fileCount: Int
    public var latestModification: Date?
    public var inaccessible: Bool
    public var directoryDevice: Int32?
    public var directoryFileID: UInt64?

    public init(sizes: Sizes, fileCount: Int, latestModification: Date?, inaccessible: Bool,
                directoryDevice: Int32? = nil, directoryFileID: UInt64? = nil) {
        self.sizes = sizes
        self.fileCount = fileCount
        self.latestModification = latestModification
        self.inaccessible = inaccessible
        self.directoryDevice = directoryDevice
        self.directoryFileID = directoryFileID
    }

    public static let empty = Measurement(sizes: .zero, fileCount: 0, latestModification: nil, inaccessible: false)
}

/// Le parcours du disque (SPEC §3.1).
public enum Scanner {

    /// Analyse un ou plusieurs dossiers et rend leur arborescence.
    public static func scan(
        _ roots: [URL],
        options: ScanOptions = ScanOptions(),
        progress: ScanProgress = ScanProgress()
    ) async -> ScanResult {
        configureProcessIOPolicy()
        let started = Date()
        let ownership = Ownership()
        let walk = Walk(options: options, progress: progress, ownership: ownership)
        let nodes = await walk.run(roots: roots.map { $0.standardizedFileURL.path })
        return ScanResult(roots: nodes, duration: Date().timeIntervalSince(started),
                          skippedVolumes: walk.skippedVolumes, ownership: ownership)
    }

    /// Mesure des éléments sans garder leur arborescence.
    ///
    /// Les liens physiques et les clones sont dédoublonnés sur l'ensemble : un
    /// fichier présent dans deux éléments n'est compté qu'une fois, dans le
    /// premier rencontré.
    public static func measure(_ urls: [URL], options: ScanOptions = .measuring) async -> [URL: Measurement] {
        guard !urls.isEmpty else { return [:] }
        let result = await scan(urls, options: options)
        var measures: [URL: Measurement] = [:]
        for (url, node) in zip(urls, result.roots) {
            measures[url] = Measurement(
                sizes: node.total,
                fileCount: node.fileCount,
                latestModification: node.latestModification,
                inaccessible: node.status.isInaccessible
                    || (SafariDownloadPath.containsPackage(url.path) && node.inaccessibleCount > 0),
                directoryDevice: node.measurementDevice,
                directoryFileID: node.measurementDevice.map { _ in node.fileID }
            )
        }
        return measures
    }

    /// Mesure un seul élément (fichier ou dossier).
    public static func measure(_ url: URL) async -> Measurement {
        await measure([url])[url] ?? .empty
    }

    /// Une seule fois par processus : ne jamais télécharger un fichier iCloud
    /// en le regardant, et ne pas réécrire la date d'accès de chaque fichier lu.
    private static let ioPolicyOnce: Void = {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_PROCESS, IOPOL_ATIME_UPDATES_OFF)
    }()

    /// À appeler avant de lire des fichiers ailleurs que dans le parcours (les
    /// empreintes des doublons) : un fichier iCloud non téléchargé ne doit pas
    /// l'être parce qu'Oust! l'a regardé.
    public static func configureProcessIOPolicy() {
        _ = ioPolicyOnce
    }
}

// MARK: - Le parcours lui-même

/// Une analyse en cours : une file de dossiers, un pool de threads.
///
/// Des `Thread` et non des tâches Swift : chaque dossier est une suite d'appels
/// système bloquants, et le pool coopératif de Swift, dimensionné sur le nombre
/// de cœurs, ne rend ses threads qu'aux points `await`. Le bloquer, c'est figer
/// tout le reste de l'application.
final class Walk: @unchecked Sendable {
    /// Ce qu'on sait d'un sous-dossier avant de relire son parent : de quoi le
    /// garder tel quel s'il n'a pas changé.
    struct Known {
        let node: TreeNode
        let fileID: UInt64
        let status: NodeStatus
    }

    struct Job {
        let node: TreeNode
        let path: String
        let device: Int32
        /// Relecture partielle : seuls les fichiers du dossier et la liste de ses
        /// sous-dossiers sont relus ; un sous-dossier connu et inchangé garde
        /// son arborescence. `nil` : tout est parcouru.
        var shallow: [String: Known]?
    }

    private let options: ScanOptions
    private let progress: ScanProgress
    private let mounts: Set<String>
    private let ownership: Ownership

    private let condition = NSCondition()
    private var pending: [Job] = []
    private var active = 0
    private var finished = false

    /// Les motifs `*.ext` de `notableNames`, sans l'étoile ni le point.
    private let notableExtensions: Set<String>
    /// Les motifs `préfixe*` de `notableNames`, sans l'étoile.
    private let notablePrefixes: [String]
    private let extendedSupported = Atomic<Bool>(true)
    private let skipped = Mutex<[String]>([])
    /// Les nœuds relus, pour ne recalculer que leurs totaux et ceux de leurs
    /// ancêtres.
    private let touched = Mutex<[TreeNode]>([])
    /// Les sous-dossiers abandonnés lors d'une relecture partielle (disparus,
    /// renommés, remplacés).
    private let dropped = Mutex<[TreeNode]>([])

    var skippedVolumes: [String] { skipped.withLock { $0 } }
    var touchedFileIDs: Set<UInt64> { Set(touched.withLock { $0.map(\.fileID) }) }

    init(options: ScanOptions, progress: ScanProgress, ownership: Ownership) {
        self.options = options
        self.progress = progress
        self.ownership = ownership
        self.mounts = MountTable.mountPoints()
        self.notableExtensions = Set(options.notableNames.filter { $0.hasPrefix("*.") }.map { String($0.dropFirst(2)) })
        self.notablePrefixes = options.notableNames.filter { $0.hasSuffix("*") && !$0.hasPrefix("*") }
            .map { String($0.dropLast()) }.sorted()
    }

    /// Un parcours complet de chaque racine.
    func run(roots rootPaths: [String]) async -> [TreeNode] {
        var nodes: [TreeNode] = []
        var jobs: [Job] = []
        for path in rootPaths {
            var info = stat()
            let exists = lstat(path, &info) == 0
            let node = TreeNode(name: (path as NSString).lastPathComponent, parent: nil,
                                fileID: exists ? UInt64(info.st_ino) : 0, rootPath: path)
            nodes.append(node)
            guard exists else {
                node.status = .inaccessible(code: errno)
                node.recomputeTotals()
                continue
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                node.measurementDevice = info.st_dev
                node.ownLatestModification = Self.date(info.st_mtimespec)
                jobs.append(Job(node: node, path: path, device: info.st_dev))
            } else {
                // Un fichier seul : sa mesure suffit.
                let allocated = Int64(info.st_blocks) * 512
                node.ownFiles = Sizes(private: allocated)
                node.ownFileCount = 1
                node.ownLatestModification = Self.date(info.st_mtimespec)
                if options.measurePrivateSizes, let privateSize = BulkReader.privateSize(path: path) {
                    node.ownFiles = Sizes(allocated: allocated, freeable: privateSize)
                }
                if SafariDownloadPath.containsPackage(path) { node.ownFiles.freeable = 0 }
                node.recomputeTotals()
            }
        }
        await process(jobs)
        for node in nodes { node.refreshTotals() }
        return nodes
    }

    /// Relit des dossiers d'une arborescence existante (réanalyse incrémentale).
    /// Rend les nœuds abandonnés, pour libérer ce qu'ils comptaient.
    func run(jobs: [Job], root: TreeNode) async -> [TreeNode] {
        await process(jobs)
        root.refreshTotals()
        return dropped.withLock { $0 }
    }

    private func process(_ jobs: [Job]) async {
        guard !jobs.isEmpty else { return }
        pending = jobs
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let remaining = Countdown(options.threads)
            for index in 0..<options.threads {
                let thread = Thread { [self] in
                    self.work()
                    if remaining.tick() {
                        continuation.resume()
                    }
                }
                thread.name = "fr.meaillais.oust.scan.\(index)"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        }
        // Chaque nœud relu et ses ancêtres devront être recomptés. Marqués ici,
        // une fois tous les threads finis : un seul écrivain.
        for node in touched.withLock({ $0 }) {
            var current: TreeNode? = node
            while let candidate = current, !candidate.needsTotals {
                candidate.needsTotals = true
                current = candidate.parent
            }
        }
    }

    static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
    }

    // MARK: File de travail

    private func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && active > 0 && !finished && !progress.isCancelled {
            condition.wait()
        }
        if progress.isCancelled || (pending.isEmpty && active == 0) {
            finished = true
            condition.broadcast()
            return nil
        }
        active += 1
        // Dernier entré, premier sorti : on termine une branche avant d'en
        // ouvrir d'autres, ce qui borne la file sur les arborescences larges.
        return pending.removeLast()
    }

    private func complete(adding jobs: [Job]) {
        condition.lock()
        pending.append(contentsOf: jobs)
        active -= 1
        condition.broadcast()
        condition.unlock()
    }

    private func work() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 128 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        var processed: [TreeNode] = []
        var abandoned: [TreeNode] = []
        while let job = next() {
            let children = process(job, buffer: buffer, abandoned: &abandoned)
            processed.append(job.node)
            complete(adding: children)
        }
        touched.withLock { $0.append(contentsOf: processed) }
        if !abandoned.isEmpty { dropped.withLock { $0.append(contentsOf: abandoned) } }
    }

    // MARK: Un dossier

    private func process(_ job: Job, buffer: UnsafeMutableRawBufferPointer, abandoned: inout [TreeNode]) -> [Job] {
        progress.addDirectory()
        let node = job.node
        let insideSafariDownload = SafariDownloadPath.containsPackage(job.path)
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let openError: Int32
        if fd < 0 {
            openError = errno
        } else if insideSafariDownload {
            var info = stat()
            openError = fstat(fd, &info) == 0 && info.st_dev == job.device && UInt64(info.st_ino) == node.fileID
                && info.st_flags & Attr.sfDataless == 0 ? 0 : ESTALE
        } else {
            openError = 0
        }
        defer { if fd >= 0 { close(fd) } }
        guard openError == 0 else {
            let code = openError
            node.status = .inaccessible(code: code)
            if let known = job.shallow { abandoned.append(contentsOf: known.values.map(\.node)) }
            node.children = []
            node.resetOwnContent()
            return []
        }
        // Relu avec succès : un dossier refusé hier peut être lisible aujourd'hui.
        node.status = .ok
        if job.shallow != nil {
            // Sa propre date a pu changer (un fichier retiré) : on la relit, ses
            // fichiers la compléteront.
            var info = stat()
            node.ownLatestModification = fstat(fd, &info) == 0 ? Self.date(info.st_mtimespec) : nil
        }

        var children: [Job] = []
        var keptOrNew: [TreeNode] = []
        var files = 0
        var bytes: Int64 = 0
        // Ce que ce dossier a déjà compté pendant ce passage : deux noms pour un
        // même inode dans un même dossier ne comptent qu'une fois.
        var countedHere = Set<UInt64>()
        let known = job.shallow ?? [:]

        let visit: (RawEntry) -> Void = { [self] entry in
            guard entry.error == 0, !entry.name.isEmpty else { return }
            let childPath = job.path.hasSuffix("/") ? job.path + entry.name : job.path + "/" + entry.name

            if entry.isDirectory {
                let reason = skipReason(for: entry, path: childPath, rootDevice: job.device)
                // Inchangé depuis la dernière analyse : même nom, même inode, et il
                // avait été parcouru. FSEvents signalera lui-même ce qui a bougé
                // dedans.
                if reason == nil, let previous = known[entry.name], previous.fileID == entry.fileID,
                   previous.status == .ok {
                    keptOrNew.append(previous.node)
                    return
                }
                let child = TreeNode(name: entry.name, parent: node, fileID: entry.fileID)
                child.ownLatestModification = entry.modified
                keptOrNew.append(child)
                if let reason {
                    child.status = reason
                    child.recomputeTotals()
                    if reason == .otherVolume { skipped.withLock { $0.append(childPath) } }
                    return
                }
                children.append(Job(node: child, path: childPath, device: job.device))
                return
            }

            // Un fichier, un lien symbolique ou autre : on compte ce qu'il occupe,
            // sans jamais suivre un lien.
            var allocated = entry.allocated
            var freeable = allocated
            if entry.linkCount > 1, !claim(entry.fileID, in: ownership.links, by: node, counted: &countedHere) {
                // Un autre lien physique vers le même fichier est compté ailleurs.
                allocated = 0
                freeable = 0
            } else if entry.isFullClone, entry.cloneID != 0,
                      !claim(entry.cloneID, in: ownership.clones, by: node, counted: &countedHere) {
                // Clone complet d'un fichier compté ailleurs : il n'occupe rien de plus.
                allocated = 0
                freeable = 0
            } else if options.measurePrivateSizes, entry.mayShareBlocks,
                      let privateSize = BulkReader.privateSize(directoryFD: fd, name: entry.name) {
                freeable = privateSize
            }
            let protected = insideSafariDownload || SafariDownloadPath.hasPackageExtension(entry.name)
            let sizes = Sizes(allocated: allocated, freeable: protected ? 0 : freeable)
            node.ownFiles += sizes
            node.ownFileCount += 1
            if let date = entry.modified, date > (node.ownLatestModification ?? .distantPast) {
                node.ownLatestModification = date
            }
            // Sur la taille brute : un clone ou un lien compté ailleurs reste une
            // feuille (à zéro), sans quoi les doublons ne le verraient jamais.
            if entry.allocated >= options.leafThreshold {
                node.files.append(FileLeaf(name: entry.name, sizes: sizes, modified: entry.modified,
                                           accessed: entry.accessed, fileID: entry.fileID, isClone: entry.isFullClone,
                                           logicalSize: entry.logicalSize, cloneID: entry.cloneID))
            } else {
                node.smallFiles += sizes
                node.smallFileCount += 1
                if !options.notableNames.isEmpty, isNotable(entry.name) {
                    node.notableFiles.append(entry.name)
                }
            }
            files += 1
            bytes += allocated
        }

        node.resetOwnContent()
        var status = BulkReader.read(directoryFD: fd, extended: extendedSupported.load(ordering: .relaxed),
                                     buffer: buffer, visit: visit)
        if status == EINVAL, extendedSupported.load(ordering: .relaxed) {
            // Volume qui refuse les attributs étendus (exFAT, réseau) : on
            // recommence sans, et on ne les redemande plus.
            extendedSupported.store(false, ordering: .relaxed)
            node.resetOwnContent()
            keptOrNew.removeAll()
            countedHere.removeAll()
            children.removeAll()
            files = 0
            bytes = 0
            lseek(fd, 0, SEEK_SET)
            status = BulkReader.read(directoryFD: fd, extended: false, buffer: buffer, visit: visit)
        }
        node.children = keptOrNew
        node.files.sort { $0.sizes.allocated > $1.sizes.allocated }
        if !known.isEmpty {
            let kept = Set(keptOrNew.map(ObjectIdentifier.init))
            abandoned.append(contentsOf: known.values.map(\.node).filter { !kept.contains(ObjectIdentifier($0)) })
        }
        if status != 0 && node.ownFileCount == 0 && node.children.isEmpty {
            node.status = .inaccessible(code: status)
        }
        progress.add(files: files, bytes: bytes)
        return children
    }

    private func isNotable(_ name: String) -> Bool {
        if options.notableNames.contains(name) { return true }
        if notablePrefixes.contains(where: name.hasPrefix) { return true }
        guard !notableExtensions.isEmpty, let dot = name.lastIndex(of: ".") else { return false }
        return notableExtensions.contains(String(name[name.index(after: dot)...]))
    }

    /// Ce dossier doit-il compter ce lien physique (ou ce clone) ?
    ///
    /// Oui s'il est le premier à le rencontrer, ou s'il le comptait déjà lors
    /// de l'analyse précédente : c'est ce qui permet de relire un seul dossier
    /// sans fausser les totaux.
    private func claim(_ key: UInt64, in map: OwnerMap, by node: TreeNode, counted: inout Set<UInt64>) -> Bool {
        guard map.claim(key, by: node.fileID) else { return false }
        return counted.insert(key).inserted
    }

    /// Pourquoi ne pas descendre dans ce dossier, s'il y a une raison.
    private func skipReason(for entry: RawEntry, path: String, rootDevice: Int32) -> NodeStatus? {
        if options.excludedPaths.contains(path) { return .excluded }
        // `getattrlistbulk` décrit un point de montage avec les attributs du
        // système de fichiers *en dessous* : son DEVID est celui du parent. Seul
        // l'état de montage le trahit. Comparer les DEVID n'aurait pas suffi à
        // éviter DeviceFS et ses 142 Go fictifs.
        if entry.isMountPoint || mounts.contains(path) || entry.device != rootDevice { return .otherVolume }
        if entry.isFirmlink { return .firmlink }
        if entry.isDataless { return .dataless }
        return nil
    }
}

extension TreeNode {
    /// Oublie ce qu'on savait des fichiers de ce dossier, avant de le relire.
    func resetOwnContent() {
        files.removeAll()
        smallFiles = .zero
        smallFileCount = 0
        ownFiles = .zero
        ownFileCount = 0
        notableFiles.removeAll()
    }

    /// Recalcule les totaux des nœuds marqués, du bas vers le haut, sans
    /// descendre dans les branches qui n'ont pas bougé.
    func refreshTotals() {
        guard needsTotals else { return }
        var stack: [(TreeNode, Bool)] = [(self, false)]
        while let (node, visited) = stack.popLast() {
            if visited {
                node.recomputeTotals()
                node.needsTotals = false
            } else {
                stack.append((node, true))
                for child in node.children where child.needsTotals { stack.append((child, false)) }
            }
        }
    }
}

// MARK: - Liens physiques et clones

/// Qui compte quoi : pour chaque inode à plusieurs liens et chaque clone complet,
/// le dossier (par son inode) qui l'a compté.
///
/// Un simple ensemble « déjà vu » suffisait pour un parcours complet. Il ne
/// suffit plus quand on relit un seul dossier : son fichier serait « déjà vu »
/// et compté zéro, alors que c'est lui qui le comptait.
final class Ownership: Sendable {
    let links: OwnerMap
    let clones: OwnerMap

    init(links: OwnerMap = OwnerMap(), clones: OwnerMap = OwnerMap()) {
        self.links = links
        self.clones = clones
    }

    func copy() -> Ownership {
        Ownership(links: OwnerMap(entries: links.entries()), clones: OwnerMap(entries: clones.entries()))
    }

    /// Les dossiers disparus ne comptent plus rien.
    func release(owners: Set<UInt64>) {
        guard !owners.isEmpty else { return }
        links.release(owners: owners)
        clones.release(owners: owners)
    }
}

/// Une table partagée entre threads, découpée en tranches pour que deux threads
/// se gênent rarement.
final class OwnerMap: Sendable {
    private final class Shard: Sendable {
        let values = Mutex<[UInt64: UInt64]>([:])
    }

    private let shards: [Shard]

    init(count: Int = 64) {
        shards = (0..<count).map { _ in Shard() }
    }

    convenience init(entries: [(key: UInt64, owner: UInt64)]) {
        self.init()
        for entry in entries { _ = claim(entry.key, by: entry.owner) }
    }

    private func shard(_ key: UInt64) -> Shard {
        shards[Int(key % UInt64(shards.count))]
    }

    /// Vrai si `owner` compte `key` : il était libre, ou déjà à lui.
    func claim(_ key: UInt64, by owner: UInt64) -> Bool {
        shard(key).values.withLock { values in
            if let current = values[key] { return current == owner }
            values[key] = owner
            return true
        }
    }

    func release(owners: Set<UInt64>) {
        for shard in shards {
            shard.values.withLock { values in values = values.filter { !owners.contains($0.value) } }
        }
    }

    func entries() -> [(key: UInt64, owner: UInt64)] {
        shards.flatMap { shard in shard.values.withLock { $0.map { (key: $0.key, owner: $0.value) } } }
    }

    var count: Int { shards.reduce(0) { $0 + $1.values.withLock { $0.count } } }
}

/// Un compte à rebours partagé : le dernier thread qui termine le sait.
final class Countdown: Sendable {
    private let remaining: Atomic<Int>

    init(_ count: Int) {
        remaining = Atomic(count)
    }

    /// Vrai pour le dernier appel.
    func tick() -> Bool {
        remaining.subtract(1, ordering: .acquiringAndReleasing).newValue == 0
    }
}

// MARK: - Table des montages

/// Les points de montage du système, pour ne jamais les traverser.
public enum MountTable {
    /// Chaque point de montage sous ses deux noms : celui que `mount` affiche
    /// (`/Users/…`) et celui qu'on rencontre en parcourant le volume de données
    /// depuis `/System/Volumes/Data`, où passent les firmlinks.
    public static func mountPoints() -> Set<String> {
        var points = Set<String>()
        for entry in entries() where entry.mountPoint != "/" {
            points.insert(entry.mountPoint)
            if !entry.mountPoint.hasPrefix("/System/Volumes/") {
                points.insert("/System/Volumes/Data" + entry.mountPoint)
            }
        }
        return points
    }

    public struct Entry: Sendable, Hashable {
        public let mountPoint: String
        public let fileSystem: String
        public let device: String
    }

    public static func entries() -> [Entry] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Un tampon brut plutôt que `[statfs](repeating: statfs(), …)` : le nom
        // du type est aussi celui d'une fonction, et Swift ne sait pas lequel on
        // veut.
        let capacity = Int(count) + 8
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let filled = getfsstat(buffer, Int32(MemoryLayout<statfs>.stride * capacity), MNT_NOWAIT)
        guard filled > 0 else { return [] }
        return (0..<Int(filled)).map { index in
            var info = buffer[index]
            return Entry(
                mountPoint: cString(&info.f_mntonname),
                fileSystem: cString(&info.f_fstypename),
                device: cString(&info.f_mntfromname)
            )
        }
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

extension Scanner {
    /// La part privée d'un fichier (`ATTR_CMNEXT_PRIVATESIZE`) : ce que sa
    /// suppression rendrait vraiment, clones et snapshots déduits.
    public static func blockSharing(fileDescriptor: Int32, allocated: Int64)
    -> (privateSize: Int64?, fullCloneID: UInt64?) {
        BulkReader.blockSharing(descriptor: fileDescriptor, allocated: allocated)
    }

    public static func privateSize(of url: URL) -> Int64? {
        BulkReader.privateSize(path: url.path)
    }
}
