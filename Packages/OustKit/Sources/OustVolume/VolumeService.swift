import AppKit
import Darwin
import Foundation
import OustCore

/// Les volumes, leur capacité et leurs snapshots (SPEC §3.4 et §3.5).
public enum VolumeService {

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
        var volumes: [VolumeDescriptor] = []
        if let boot = bootVolume() { volumes.append(boot) }

        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsRootFileSystem == true || url.path == "/" { continue }
            if values.volumeIsBrowsable == false { continue }
            if url.path.hasPrefix("/System/Volumes") { continue }
            guard let capacity = capacity(of: url) else { continue }
            volumes.append(VolumeDescriptor(
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                mountURL: url,
                scanRoot: url,
                isBoot: false,
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false),
                capacity: capacity
            ))
        }
        return volumes
    }

    // MARK: Snapshots

    /// Les snapshots locaux du volume de données.
    ///
    /// Sur `/System/Volumes/Data` et non sur `/` : `tmutil listlocalsnapshots /`
    /// ne montre que le volume système scellé et son snapshot de mise à jour,
    /// qu'il ne faut jamais toucher.
    public static func localSnapshots() async -> [LocalSnapshot] {
        let result = await Command.run("/usr/bin/tmutil", ["listlocalsnapshots", bootDataRoot.path], timeout: 20)
        guard result.succeeded else { return [] }
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
        let commands = dates.map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }.joined(separator: "; ")
        return "do shell script \"\(commands)\" with administrator privileges"
    }

    /// Supprime des snapshots Time Machine : par le démon privilégié s'il est
    /// installé et approuvé, sinon après une invite administrateur.
    ///
    /// Rend `true` si macOS a confirmé. L'espace ne revient pas tout de suite :
    /// APFS le libère en arrière-plan (voir `watchReclaim`).
    public static func deleteSnapshots(_ snapshots: [LocalSnapshot]) async -> Bool {
        guard let script = deletionScript(for: snapshots) else { return false }
        // Les mêmes dates, déjà validées, revalidées par le démon. S'il est
        // injoignable ou refuse la demande entière, il n'a rien fait : l'invite
        // d'avant prend le relais, inchangée (docs/adr/0001).
        let dates = snapshots.compactMap(\.date)
        switch await PrivilegedHelper.deleteSnapshots(dates: dates) {
        case .answered(let response): return response.deletedAll(dates)
        case .timedOut: return false
        case .unreachable: break
        }
        let result = await Command.run("/usr/bin/osascript", ["-e", script], timeout: 300)
        return result.succeeded
    }

    // MARK: Reprise d'espace

    /// Suit l'espace libre réel pendant qu'APFS récupère ce qui a été libéré.
    ///
    /// Le 18/10/2026, après la suppression des snapshots, l'espace est revenu
    /// une minute et demie plus tard : annoncer « 0 libéré » sur-le-champ aurait
    /// été faux. On mesure toutes les `interval` secondes, pendant `duration`.
    public static func watchReclaim(of url: URL, duration: TimeInterval = 180,
                                    interval: TimeInterval = 5) -> AsyncStream<Capacity> {
        AsyncStream { continuation in
            let task = Task {
                let end = Date().addingTimeInterval(duration)
                while Date() < end, !Task.isCancelled {
                    if let capacity = capacity(of: url) { continuation.yield(capacity) }
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
