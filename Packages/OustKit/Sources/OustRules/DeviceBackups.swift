import Darwin
import Foundation
import OustCore
import OustSafety

struct DeviceBackupsFinder {
    let context: RuleContext

    private struct Backup {
        let name: String
        let device: String?
        let date: Date?
        let url: URL
        let facts: FileFacts
        let completed: Bool?
        let metadata: [BackupMetadata]
    }

    func find() -> [Candidate] {
        guard context.volume == nil else { return [] }
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let previous = getiopolicy_np(policy, scope)
        guard previous >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return [] }
        defer { _ = setiopolicy_np(policy, scope, previous) }
        let root = DeviceBackupPath.root(in: context.home)
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        // Le domicile peut être présenté sous /var ou /private/var. À partir
        // de son descripteur, chaque composant est ouvert sans suivre de lien.
        var fd = open(context.home.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        guard let home = FileFacts.openFile(fd), !home.isDataless else { close(fd); return [] }
        for component in DeviceBackupPath.components {
            let child = openat(fd, component, flags)
            close(fd)
            guard child >= 0 else { return [] }
            guard let facts = FileFacts.openFile(child), !facts.isDataless, facts.device == home.device else {
                close(child)
                return []
            }
            fd = child
        }
        guard let stream = fdopendir(fd) else { close(fd); return [] }
        defer { closedir(stream) }
        guard let directory = FileFacts.openFile(fd) else { return [] }

        var backups: [Backup] = []
        var uncertainInventory = false
        while !Task.isCancelled {
            errno = 0
            guard let entry = readdir(stream) else {
                uncertainInventory = uncertainInventory || errno != 0
                break
            }
            guard let name = withUnsafeBytes(of: entry.pointee.d_name, { bytes in
                String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
            }) else { uncertainInventory = true; continue }
            guard name != ".", name != ".." else { continue }
            guard let facts = FileFacts.at(name, in: fd) else { uncertainInventory = true; continue }
            if facts.mode & S_IFMT == S_IFLNK { uncertainInventory = true; continue }
            guard facts.mode & S_IFMT == S_IFDIR else { continue }
            guard !facts.isDataless, facts.device == directory.device else { uncertainInventory = true; continue }
            let url = root.appendingPathComponent(name, isDirectory: true)
            let metadata = Self.metadata(for: name, url: url, in: fd, expecting: facts)
            let info = metadata?.info
            let status = metadata?.status
            let completed = (status?["SnapshotState"] as? String).map { $0 == "finished" }
            let identifiers = ["Target Identifier", "Unique Identifier"].compactMap { info?[$0] }
            let valid = identifiers.compactMap { Self.identifier($0 as? String) }
            let device = valid.count == identifiers.count && Set(valid).count == 1 ? valid.first : nil
            let title = (info?["Device Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            backups.append(Backup(name: title.flatMap { $0.isEmpty ? nil : $0 } ?? name, device: device,
                                  date: completed == true ? status?["Date"] as? Date : info?["Last Backup Date"] as? Date,
                                  url: url, facts: facts, completed: completed, metadata: metadata?.checks ?? []))
        }
        guard !Task.isCancelled, let current = FileFacts.of(root.path),
              current.device == directory.device, current.isUnchanged(comparedTo: directory) else { return [] }
        var latest: [String: Date] = [:]
        var uncertain = Set<String>()
        for backup in backups {
            if backup.completed == false { continue }
            guard let device = backup.device else { uncertainInventory = true; continue }
            if backup.completed == true, let date = backup.date {
                latest[device] = max(latest[device] ?? date, date)
            } else {
                uncertain.insert(device)
            }
        }
        let ranking = BackupRanking(root: BackupMetadata(url: root, facts: directory),
                                    entries: backups.flatMap { [BackupMetadata(url: $0.url, facts: $0.facts)] + $0.metadata })
        return backups.map { backup in
            var item = CleanupItem(title: backup.name,
                                   detail: backup.date?.formatted(date: .abbreviated, time: .shortened),
                                   paths: [backup.url], category: .iosBackups, owner: "", ruleID: "ios.backup",
                                   safety: .protected, method: .manual, lastActivity: backup.date, rebuild: .irreversible,
                                   fingerprint: Fingerprint(modificationDate: backup.facts.modificationDate,
                                                            fileID: backup.facts.inode))
            if backup.completed == false {
                item.protect(.unknownState)
            } else if !uncertainInventory, let device = backup.device, let date = backup.date, !uncertain.contains(device) {
                if latest[device] == date { item.protect(.newestKept) }
            } else {
                item.protect(.unknownState)
            }
            return Candidate(item: item, location: AnalyzedItemLocation(directory: directory, entry: backup.facts,
                             backupMetadata: backup.metadata, backupRanking: item.protections.contains(.newestKept) ? ranking : nil))
        }
    }

    private static func identifier(_ value: String?) -> String? {
        guard let value, (8...128).contains(value.utf8.count), value.utf8.contains(where: { $0 != 45 }),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 }) else { return nil }
        return value.lowercased()
    }

    private static func metadata(for name: String, url: URL, in root: Int32, expecting facts: FileFacts)
        -> (info: [String: Any]?, status: [String: Any]?, checks: [BackupMetadata])? {
        let dir = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return nil }
        defer { close(dir) }
        guard let actual = FileFacts.openFile(dir), actual.device == facts.device,
              actual.isUnchanged(comparedTo: facts) else { return nil }
        let info = FileFacts.at("Info.plist", in: dir)
        let status = FileFacts.at("Status.plist", in: dir)
        return (plist("Info.plist", in: dir, expecting: info, device: facts.device),
                plist("Status.plist", in: dir, expecting: status, device: facts.device),
                [BackupMetadata(url: url.appendingPathComponent("Info.plist"), facts: info),
                 BackupMetadata(url: url.appendingPathComponent("Status.plist"), facts: status)])
    }

    private static func plist(_ name: String, in dir: Int32, expecting expected: FileFacts?, device: Int32) -> [String: Any]? {
        let limit = 4 * 1024 * 1024
        guard let expected, expected.device == device, expected.isRegularFile, !expected.isDataless,
              expected.linkCount == 1, (1...Int64(limit)).contains(expected.size) else { return nil }
        let fd = openat(dir, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        guard let before = FileFacts.openFile(fd), before.device == device, before.isRegularFile,
              !before.isDataless, before.isUnchanged(comparedTo: expected),
              let data = try? file.read(upToCount: Int(before.size) + 1), data.count == Int(before.size),
              let after = FileFacts.at(name, in: dir), after.device == device,
              after.isUnchanged(comparedTo: before) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
