import AppKit
import Darwin
import Foundation
import OustCore
import Synchronization

/// Les volumes, leur capacité et leurs snapshots (SPEC §3.4 et §3.5).
public enum VolumeService {
    private static let inventoryWorkers = Mutex([String: Bool]())

    package struct Inventory: Sendable {
        package let volumes: [VolumeDescriptor]
        package let unverified: Set<String>
    }

    /// Le volume de données du disque de démarrage : c'est lui qu'on parcourt,
    /// jamais `/`, qui ferait suivre les firmlinks et compter deux fois.
    public static let bootDataRoot = URL(fileURLWithPath: "/System/Volumes/Data")

    /// La capacité d'un volume, sous les trois angles de macOS.
    ///
    /// L'espace libre et la taille viennent de `statfs`, relu à chaque appel.
    /// Foundation garde en cache la capacité d'un volume dans le processus,
    /// même sur une URL neuve dont on a vidé le cache : le 18/10/2026, 400 Mo
    /// écrits ne changeaient pas `volumeAvailableCapacity` (`statfs`, lui, les
    /// voyait), et le bilan d'un nettoyage affichait « Mesuré sur le disque : — »
    /// en accusant les snapshots d'espace qu'APFS avait déjà rendu (2,1 Go selon
    /// `df`). Seule la capacité « pour un usage important », qui compte le
    /// purgeable, n'existe qu'auprès de Foundation.
    public static func capacity(of url: URL) -> Capacity? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let blockSize = Int64(info.f_bsize)
        let total = Int64(info.f_blocks) * blockSize
        let available = Int64(info.f_bavail) * blockSize
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        let important = (try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return Capacity(total: total, available: available,
                        availableForImportantUsage: max(important ?? available, available))
    }

    /// Le disque de démarrage.
    public static func bootVolume() -> VolumeDescriptor? {
        let root = URL(fileURLWithPath: "/")
        let name = (try? root.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"
        guard let capacity = capacity(of: bootDataRoot) ?? capacity(of: root) else { return nil }
        return VolumeDescriptor(name: name, mountURL: root, scanRoot: bootDataRoot, isBoot: true,
                                isInternal: true, isRemovable: false, capacity: capacity)
    }

    /// Tous les volumes qu'un humain reconnaîtrait : le disque de démarrage, puis
    /// les disques internes et externes visibles dans le Finder.
    ///
    /// Les volumes cachés (simulateurs montés, cryptex, Preboot, VM) sont écartés
    /// par `skipHiddenVolumes` : ce ne sont pas des disques qu'on « nettoie ».
    public static func mountedVolumes() -> [VolumeDescriptor] {
        let startup = bootVolume().map { [$0] } ?? []
        return startup + otherMountedVolumes()
    }

    package static func otherMountedVolumes() -> [VolumeDescriptor] {
        guard let table = MountedFileSystems.read() else { return [] }
        return table.filter { $0.isExternalCandidate && !$0.isHidden }.compactMap(descriptor)
    }

    package static func readInventory() async -> Inventory? {
        guard let table = await checkStorageIO({ MountedFileSystems.read() }) ?? nil else { return nil }
        return await collectInventory(table) { entry in
            guard inventoryWorkers.withLock({ active in
                guard active[entry.path] == nil,
                      entry.isLocal || active.values.filter({ !$0 }).count < 4 else { return false }
                active[entry.path] = entry.isLocal
                return true
            }) else { return nil }
            defer { inventoryWorkers.withLock { _ = $0.removeValue(forKey: entry.path) } }
            return descriptor(entry)
        }
    }

    package static func collectInventory(
        _ table: [MountedFileSystems.Entry],
        read: @escaping @Sendable (MountedFileSystems.Entry) -> VolumeDescriptor?
    ) async -> Inventory {
        let candidates = table.filter(\.isExternalCandidate)
        return await withTaskGroup(of: (String, VolumeDescriptor?).self) { tasks in
            for entry in candidates where !entry.isHidden {
                tasks.addTask { (entry.path, await checkStorageIO { read(entry) } ?? nil) }
            }
            var pending = Set(candidates.map(\.path))
            var ready: [VolumeDescriptor] = []
            for await (path, result) in tasks {
                guard let result else { continue }
                pending.remove(path)
                ready.append(result)
            }
            return Inventory(volumes: ready.sorted { $0.id < $1.id }, unverified: pending)
        }
    }

    private static func descriptor(_ entry: MountedFileSystems.Entry) -> VolumeDescriptor? {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey,
        ]
        let url = URL(fileURLWithPath: entry.path, isDirectory: true)
        return stableMount(at: url) { identity -> VolumeDescriptor? in
            guard identity.filesystemID == entry.identity, let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true, values.volumeIsBrowsable != false,
                  let capacity = capacity(of: url) else { return nil }
            var volume = VolumeDescriptor(name: values.volumeLocalizedName ?? url.lastPathComponent,
                                        mountURL: url, scanRoot: url, isBoot: false,
                                        isInternal: values.volumeIsInternal ?? false,
                                        isRemovable: values.volumeIsRemovable == true || values.volumeIsEjectable == true,
                                        capacity: capacity)
            volume.mountIdentity = identity
            volume.mountedReadOnly = values.volumeIsReadOnly
            volume.mountedFileSystem = entry.type
            return volume
        }
    }

    package static func stableMount<Row>(
        at url: URL, identityAt: (URL) -> VolumeMountIdentity? = mountIdentity,
        read: (VolumeMountIdentity) -> Row?
    ) -> Row? {
        guard let before = identityAt(url), let row = read(before),
              identityAt(url) == before else { return nil }
        return row
    }

    package static func mountIdentity(of url: URL) -> VolumeMountIdentity? {
        let fd = open(url.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = statfs()
        var root = stat()
        guard fstatfs(fd, &info) == 0, fstat(fd, &root) == 0 else { return nil }
        let mountedAt = withUnsafeBytes(of: &info.f_mntonname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard URL(fileURLWithPath: mountedAt).standardizedFileURL.path == url.standardizedFileURL.path else { return nil }
        return VolumeMountIdentity(device: root.st_dev, inode: UInt64(root.st_ino),
                                   createdSeconds: root.st_birthtimespec.tv_sec,
                                   createdNanoseconds: root.st_birthtimespec.tv_nsec,
                                   filesystemID: MountedFileSystems.identity(of: info))
    }

    // MARK: Snapshots

    /// Les snapshots locaux du volume de données.
    ///
    /// Sur `/System/Volumes/Data` et non sur `/` : `tmutil listlocalsnapshots /`
    /// ne montre que le volume système scellé et son snapshot de mise à jour,
    /// qu'il ne faut jamais toucher.
    public static func localSnapshots() async -> [LocalSnapshot] {
        await readLocalSnapshots() ?? []
    }

    /// nil distingue un refus d'accès d'une liste réellement vide.
    public static func readLocalSnapshots() async -> [LocalSnapshot]? {
        let result = await Command.run("/usr/bin/tmutil", ["listlocalsnapshots", bootDataRoot.path], timeout: 20)
        guard result.succeeded else { return nil }
        return parseSnapshots(result.output)
    }

    static func parseSnapshots(_ output: String) -> [LocalSnapshot] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") }
            .map(LocalSnapshot.init(name:))
    }

    /// La commande exécutée en administrateur pour supprimer des snapshots.
    ///
    /// Construite ici, et testée, parce qu'elle part en root : seules des dates
    /// validées une à une y entrent, rien d'autre (RULES.md, règle 7).
    public static func deletionScript(for snapshots: [LocalSnapshot]) -> String? {
        let dates = snapshots.compactMap(\.date).filter(LocalSnapshot.isValidDate)
        guard !dates.isEmpty, dates.count == snapshots.count else { return nil }
        let commands = dates.map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }.joined(separator: " && ")
        return "do shell script \"\(commands)\" with administrator privileges"
    }

    /// Compatibilité pour les clients qui ne demandent qu'un bilan global.
    public static func deleteSnapshots(_ snapshots: [LocalSnapshot]) async -> Bool {
        let result = await deleteSnapshotResults(snapshots)
        return !snapshots.isEmpty && snapshots.allSatisfy { result.deleted.contains($0.date ?? "") }
    }

    // MARK: Reprise d'espace

    /// Suit l'espace libre réel pendant qu'APFS récupère ce qui a été libéré.
    ///
    /// Le 18/10/2026, après la suppression des snapshots, l'espace est revenu
    /// une minute et demie plus tard : annoncer « 0 libéré » sur-le-champ aurait
    /// été faux. On mesure toutes les `interval` secondes, pendant `duration`.
    public static func watchReclaim(of url: URL, duration: TimeInterval = 180,
                                    interval: TimeInterval = 5) -> AsyncStream<Capacity> {
        watchReclaim(of: url, duration: duration, interval: interval) { capacity, _ in capacity }
    }

    package struct ReclaimedSample: Sendable {
        package let capacity: Capacity
        package let measuredAt: ContinuousClock.Instant

        package init(capacity: Capacity, measuredAt: ContinuousClock.Instant) {
            self.capacity = capacity
            self.measuredAt = measuredAt
        }
    }

    package static func watchReclaimSamples(of url: URL) -> AsyncStream<ReclaimedSample> {
        watchReclaim(of: url, duration: 180, interval: 5) { ReclaimedSample(capacity: $0, measuredAt: $1) }
    }

    private static func watchReclaim<Sample: Sendable>(
        of url: URL, duration: TimeInterval, interval: TimeInterval,
        sample: @escaping @Sendable (Capacity, ContinuousClock.Instant) -> Sample
    ) -> AsyncStream<Sample> {
        AsyncStream { continuation in
            let task = Task {
                let end = Date().addingTimeInterval(duration)
                while Date() < end, !Task.isCancelled {
                    let measuredAt = ContinuousClock.now
                    if let capacity = capacity(of: url) { continuation.yield(sample(capacity, measuredAt)) }
                    try? await Task.sleep(for: .seconds(interval))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Un disque branché ou débranché.
public enum VolumeEvent: Sendable {
    case mounted(URL)
    case unmounted(URL)
}

/// Écoute les branchements de disques, pour proposer de les analyser.
public enum VolumeMonitor {
    @MainActor
    public static func events() -> AsyncStream<VolumeEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let mounted = center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    continuation.yield(.mounted(url))
                }
            }
            let unmounted = center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    continuation.yield(.unmounted(url))
                }
            }
            let tokens = ObserverTokens(mounted, unmounted)
            continuation.onTermination = { _ in tokens.remove() }
        }
    }

    private final class ObserverTokens: @unchecked Sendable {
        private let tokens: [any NSObjectProtocol]
        init(_ tokens: any NSObjectProtocol...) { self.tokens = tokens }
        func remove() {
            let center = NSWorkspace.shared.notificationCenter
            for token in tokens { center.removeObserver(token) }
        }
    }
}
