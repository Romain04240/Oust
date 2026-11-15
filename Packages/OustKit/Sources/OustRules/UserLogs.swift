import Darwin
import Foundation
import OustCore
import OustSafety

struct UserLogsFinder {
    let context: RuleContext

    func find() -> [Candidate] {
        guard context.volume == nil else { return [] }
        let root = context.path("Library/Logs")
        let guardPaths = PathGuard(home: context.home)
        guard guardPaths.allowsUserLog(root.appendingPathComponent("test.log")) else { return [] }
        var rootInfo = stat()
        var homeInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              stat(context.home.path, &homeInfo) == 0, rootInfo.st_dev == homeInfo.st_dev,
              let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [], options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return [] }

        let cutoff = context.now.addingTimeInterval(-30 * 86_400)
        let openPaths = OpenFiles.paths(under: root.path)
        let roblox = root.appendingPathComponent("Roblox").path
        var candidates: [Candidate] = []
        while let file = entries.nextObject() as? URL {
            if Task.isCancelled { break }
            var info = stat()
            // Roblox a déjà sa propre règle. Un autre volume ou un lien ne fait
            // pas partie des journaux de ce dossier personnel.
            guard !PathNormalizer.isWithin(file.path, roblox),
                  lstat(file.path, &info) == 0, info.st_dev == rootInfo.st_dev else {
                entries.skipDescendants()
                continue
            }
            let name = file.lastPathComponent
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                  name.lowercased().wholeMatch(of: /.+\.log(?:\.\d+)?(?:\.gz)?/) != nil,
                  !openPaths.contains(PathNormalizer.normalize(file.path)),
                  guardPaths.allowsUserLog(file) else { continue }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            guard modified < cutoff else { continue }
            // Une nouvelle analyse ne doit pas transférer une coche à une
            // autre version qui a pris le même chemin lors d'une rotation.
            guard let facts = FileFacts.of(file.path), facts.inode == UInt64(info.st_ino),
                  facts.device == info.st_dev, facts.modificationDate == modified,
                  facts.isRegularFile, facts.linkCount == 1 else { continue }
            candidates.append(Candidate(item: CleanupItem(
                id: facts.userLogID(at: file), title: name, detail: file.abbreviated(home: context.home), paths: [file], category: .userLogs,
                owner: file.deletingLastPathComponent().lastPathComponent, ruleID: "logs.user",
                safety: .protected, protections: [.unknownState], method: .trash,
                lastActivity: modified, rebuild: .irreversible,
                fingerprint: Fingerprint(modificationDate: modified, fileID: UInt64(info.st_ino))
            )))
        }
        return candidates
    }
}
