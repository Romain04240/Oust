import Darwin
import Foundation
import OustCore
import OustSafety

/// Inventorie les archives de comptes laissées par macOS à partir des métadonnées du dossier.
struct AccountArchivesFinder {
    let context: RuleContext

    func find() -> [Candidate] {
        guard context.volume == nil else { return [] }
        let root = context.accountArchivesRoot
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let parent = open(root.deletingLastPathComponent().path, flags)
        guard parent >= 0 else { return [] }
        defer { close(parent) }
        let fd = openat(parent, root.lastPathComponent, flags)
        guard fd >= 0 else { return [] }
        guard let stream = fdopendir(fd) else { close(fd); return [] }
        defer { closedir(stream) }
        guard let directory = FileFacts.openFile(fd), !directory.isDataless,
              FileFacts.openFile(parent)?.device == directory.device else { return [] }

        var candidates: [Candidate] = []
        while !Task.isCancelled, let entry = readdir(stream) {
            guard let name = withUnsafeBytes(of: entry.pointee.d_name, { bytes in
                String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
            }), AccountArchivePath.isDiskImage(name),
                  let facts = FileFacts.at(name, in: fd), facts.isRegularFile, !facts.isDataless,
                  facts.device == directory.device, facts.linkCount == 1 else { continue }
            let url = root.appendingPathComponent(name)
            let item = CleanupItem(
                id: "\(CleanupItem.accountArchiveRuleID)|\(PathNormalizer.normalize(url.path))",
                title: name, paths: [url], category: .accountArchives, owner: "",
                ruleID: CleanupItem.accountArchiveRuleID, safety: .protected, method: .manual,
                sizes: Sizes(allocated: facts.allocated, freeable: 0),
                lastActivity: facts.modificationDate, rebuild: .irreversible,
                fingerprint: Fingerprint(modificationDate: facts.modificationDate, fileID: facts.inode)
            )
            candidates.append(Candidate(item: item, needsMeasure: false,
                                        location: AnalyzedItemLocation(directory: directory, entry: facts)))
        }
        return candidates
    }
}
