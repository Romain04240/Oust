import Darwin
import Foundation
import OustCore
import OustSafety

struct UserLogRecovery: Codable {
    static let prefix = ".oust-log-recovery-"
    static let receiptName = "intent.json"
    static let stagedName = "journal"
    var outcome: CleanupOutcome
    let trashName: String
    let device: Int32
    let inode: UInt64
}

extension CleanupEngine {
    func userLogProtection(_ item: CleanupItem) -> SkipReason {
        guard item.ruleID == "logs.user", item.method == .trash, item.paths.count == 1,
              let path = item.paths.first, let location = pathGuard.userLogLocation(path) else {
            return .refusedByGuard
        }
        if let bundle = location.bundleDirectory, runningApps().contains(bundle) {
            return .nowProtected(.appRunning(name: bundle))
        }
        guard let facts = FileFacts.of(path.path) else { return .vanished }
        guard facts.isRegularFile, facts.linkCount == 1 else { return .refusedByGuard }
        guard facts.userLogID(at: path) == item.id else { return .changedSinceScan }
        if userLogOpenStatus(path.path) == .open { return .nowProtected(.fileOpen) }
        // libproc ne peut pas lier son constat au renommage du même inode.
        // Aucun résultat de la sonde n'autorise donc un déplacement.
        return .nowProtected(.unknownState)
    }

    static func directoryMatches(_ fd: Int32, at path: String) -> Bool {
        var opened = stat()
        var named = stat()
        return fstat(fd, &opened) == 0 && lstat(path, &named) == 0 &&
            (named.st_mode & S_IFMT) == S_IFDIR && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
    }

    static func canonicalDirectory(_ url: URL) -> String? {
        guard let result = realpath(url.path, nil) else { return nil }
        defer { free(result) }
        return String(cString: result)
    }

    /// La reprise ne pousse jamais un fichier isolé vers la Corbeille. Elle
    /// rend son emplacement visible, ou enregistre un déplacement déjà fini.
    public func recoverUserLogs() async {
        guard let history, let home = Self.canonicalDirectory(userLogTrashDirectory.deletingLastPathComponent()),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: home) else { return }
        let homeURL = URL(fileURLWithPath: home)
        let trashURL = homeURL.appendingPathComponent(userLogTrashDirectory.lastPathComponent, isDirectory: true)
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        let trash = open(trashURL.path, directoryFlags)
        defer { if trash >= 0 { close(trash) } }
        for entry in entries where entry.hasPrefix(UserLogRecovery.prefix) {
            guard UUID(uuidString: String(entry.dropFirst(UserLogRecovery.prefix.count))) != nil else { continue }
            let folder = homeURL.appendingPathComponent(entry, isDirectory: true)
            let fd = open(folder.path, directoryFlags)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else { continue }
            let receipt = openat(fd, UserLogRecovery.receiptName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard receipt >= 0 else { continue }
            defer { close(receipt) }
            guard flock(receipt, LOCK_EX | LOCK_NB) == 0,
                  fstat(receipt, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == getuid(), metadata.st_size > 0, metadata.st_size <= 65_536,
                  let data = try? FileHandle(fileDescriptor: receipt, closeOnDealloc: false).read(upToCount: 65_536),
                  let intent = try? JSONDecoder().decode(UserLogRecovery.self, from: data),
                  intent.trashName.hasSuffix(".log"),
                  UUID(uuidString: String(intent.trashName.dropLast(4))) != nil,
                  intent.outcome.category == .userLogs, intent.outcome.method == .trash,
                  intent.outcome.paths.count == 1 else { continue }
            let destination = trashURL.appendingPathComponent(intent.trashName).path
            let staged = FileFacts.at(UserLogRecovery.stagedName, in: fd)
            func matchesJournal(_ facts: FileFacts?) -> Bool {
                guard let facts, facts.isRegularFile, facts.device == intent.device, facts.inode == intent.inode else {
                    return false
                }
                return intent.outcome.userLogRestoreIdentity?.matches(facts) == true
            }
            var outcome = intent.outcome
            if let staged {
                guard matchesJournal(staged), Self.directoryMatches(fd, at: folder.path) else { continue }
                outcome.result = .failed(message: "logs.user.error.restore_conflict")
                outcome.bytes = 0
                outcome.trashedTo = [folder.appendingPathComponent(UserLogRecovery.stagedName).path]
            } else if trash >= 0, Self.directoryMatches(trash, at: trashURL.path),
                      matchesJournal(FileFacts.at(intent.trashName, in: trash)) {
                outcome.trashedTo = [destination]
            } else {
                continue
            }
            // Le reçu reste en place. unlinkat ne vérifie pas l'identité du
            // fichier que le noyau trouve sous ce nom, même avec le parent ouvert.
            do {
                try await history.appendRecoveredUserLog(outcome)
            } catch {
                // L'intention reste disponible pour le prochain lancement.
            }
        }
    }
}

extension CleanupOutcome.UserLogRestoreIdentity {
    func matches(_ facts: FileFacts?) -> Bool {
        guard let facts else { return false }
        return facts.isRegularFile && facts.device == device && facts.inode == inode
            && facts.created.tv_sec == birthSeconds && facts.created.tv_nsec == birthNanoseconds
    }
}
