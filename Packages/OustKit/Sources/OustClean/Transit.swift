import Darwin
import Foundation
import Synchronization

/// Le dossier de transit : le régénérable y est renommé d'un seul `rename`, puis
/// effacé en arrière-plan.
///
/// Effacer 2 Go en 256 000 petits fichiers prend dix secondes (`removefile`,
/// mesuré le 18/10/2026) ; les renommer, une fraction de milliseconde. Le
/// dossier quitte sa place à l'instant, l'interface le voit partir, et le disque
/// se vide derrière, sans retenir le nettoyage. Ce qui n'a pas fini d'être
/// effacé quand Oust! s'arrête l'est au lancement suivant (`resume`).
///
/// Le renommage ne vaut que sur un même volume ; ailleurs (autre disque, droits
/// refusés), on efface sur place, comme avant.
public final class Transit: Sendable {
    /// Le dossier de transit du volume de données.
    public let directory: URL
    /// Le nom du dossier de transit à la racine des autres volumes.
    static let volumeFolderName = ".oust-transit"

    private let purger: Purger

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
        self.purger = Purger()
    }

    /// `~/Library/Application Support/Oust/.transit`, caché, sur le volume de
    /// données comme tout le dossier personnel.
    public static func standard() -> Transit {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Transit(directory: support.appendingPathComponent("Oust/.transit", isDirectory: true))
    }

    /// Ce qui attend encore d'être effacé, en octets libérables.
    public var pendingBytes: Int64 { purger.pendingBytes }

    /// Rend la main quand tout ce qui a été mis de côté est effacé.
    public func drained() async {
        await purger.drained()
    }

    // MARK: Mettre de côté

    /// Renomme `url` dans le dossier de transit de son volume, puis le confie à
    /// l'effacement. `false` si c'est impossible : à l'appelant d'effacer sur
    /// place.
    ///
    /// La revalidation et la garde de chemins ont eu lieu avant : ce renommage
    /// est le geste qui fait partir l'élément, il ne décide rien.
    func move(_ url: URL, bytes: Int64) -> Bool {
        var item = stat()
        guard lstat(url.path, &item) == 0 else { return false }
        guard let folder = folder(for: url, device: item.st_dev) else { return false }
        // Jamais le dossier de transit lui-même, ni un dossier qui le contient :
        // `rename` refuserait, mais autant ne pas le lui demander.
        let path = url.standardizedFileURL.path
        if folder.path.hasPrefix(path + "/") || path.hasPrefix(folder.path + "/") || path == folder.path { return false }
        let destination = folder.appendingPathComponent(UUID().uuidString, isDirectory: false)
        guard rename(url.path, destination.path) == 0 else { return false }
        purger.enqueue(destination, bytes: bytes)
        return true
    }

    /// Le dossier de transit sur le volume de `device`, créé au besoin.
    private func folder(for url: URL, device: dev_t) -> URL? {
        if let folder = Self.prepared(directory, device: device) { return folder }
        // Un autre volume : son propre dossier de transit, à sa racine.
        guard let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return nil }
        return Self.prepared(volume.appendingPathComponent(Self.volumeFolderName, isDirectory: true), device: device)
    }

    /// Un dossier de transit utilisable : un vrai dossier (pas un lien), à
    /// nous, sur le bon volume.
    static func prepared(_ folder: URL, device: dev_t) -> URL? {
        var info = stat()
        if lstat(folder.path, &info) != 0 {
            try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            guard mkdir(folder.path, 0o700) == 0 || errno == EEXIST, lstat(folder.path, &info) == 0 else { return nil }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_dev == device else { return nil }
        return folder
    }

    // MARK: Reprendre

    /// Efface ce qu'un lancement précédent a laissé en transit : dans le dossier
    /// de transit du volume de données, et à la racine des volumes montés.
    public func resume(volumes: [URL] = []) {
        var folders = [directory]
        folders += volumes.map { $0.appendingPathComponent(Self.volumeFolderName, isDirectory: true) }
        for folder in folders {
            var info = stat()
            // Le même contrôle qu'à l'écriture : on n'efface que dans un dossier
            // de transit à nous, jamais au bout d'un lien.
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for entry in entries {
                purger.enqueue(folder.appendingPathComponent(entry), bytes: 0)
            }
        }
    }
}

// MARK: - L'effacement en arrière-plan

/// Un thread à lui, à basse priorité : `removefile` est une longue suite
/// d'appels système bloquants, qui n'ont rien à faire dans le pool coopératif
/// de Swift, et qui ne doivent pas ralentir ce que l'utilisateur fait pendant ce
/// temps.
final class Purger: @unchecked Sendable {
    private struct Work {
        let url: URL
        let bytes: Int64
    }

    private let condition = NSCondition()
    private var queue: [Work] = []
    private var busy = false
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let pending = Atomic<Int64>(0)

    var pendingBytes: Int64 { pending.load(ordering: .relaxed) }

    func enqueue(_ url: URL, bytes: Int64) {
        pending.add(bytes, ordering: .relaxed)
        condition.lock()
        queue.append(Work(url: url, bytes: bytes))
        if !started {
            started = true
            let thread = Thread { [self] in run() }
            thread.name = "fr.meaillais.oust.transit"
            thread.qualityOfService = .utility
            thread.start()
        }
        condition.signal()
        condition.unlock()
    }

    func drained() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            condition.lock()
            if queue.isEmpty && !busy {
                condition.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                condition.unlock()
            }
        }
    }

    private func run() {
        // Les entrées-sorties de ce thread passent après celles des autres.
        _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_UTILITY)
        while true {
            condition.lock()
            while queue.isEmpty { condition.wait() }
            let work = queue.removeFirst()
            busy = true
            condition.unlock()

            // Un échec (fichier verrouillé que même `Remover` ne déverrouille
            // pas) laisse l'élément en transit : le prochain lancement réessaiera.
            _ = Remover.remove(work.url)
            pending.subtract(work.bytes, ordering: .relaxed)

            condition.lock()
            busy = false
            let finished = queue.isEmpty ? waiters : []
            if queue.isEmpty { waiters.removeAll() }
            condition.unlock()
            for waiter in finished { waiter.resume() }
        }
    }
}
