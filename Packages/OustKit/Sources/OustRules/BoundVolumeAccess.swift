import Darwin
import Foundation
import OustCore
import OustSafety
import OustScan

extension RuleContext {
    /// Only entries verified on the retained mount. Use a direct lookup for a
    /// known name when missing and inaccessible must be distinguished.
    func volumeEntries(in directory: URL) -> [(url: URL, facts: FileFacts)]? {
        Scanner.configureProcessIOPolicy()
        guard !Task.isCancelled, let anchor = volumeAnchor, let fd = anchor.openDirectory(directory) else { return nil }
        guard let stream = fdopendir(fd) else {
            close(fd)
            return nil
        }
        defer { closedir(stream) }
        guard let names = VolumeDirectory.names(in: stream) else { return nil }
        return names.compactMap { name in
            guard !Task.isCancelled, let facts = VolumeDirectory.entry(name, in: fd, anchor: anchor).facts else { return nil }
            let url = directory.appendingPathComponent(name, isDirectory: facts.mode & S_IFMT == S_IFDIR)
            StorageOperationContext.reportProgress()
            return (url, facts)
        }
    }

    /// Read bounded metadata from the same file observed in the verified
    /// parent directory, without following links or opening cloud placeholders.
    func volumeData(at url: URL, maximumBytes: Int) -> Data? {
        Scanner.configureProcessIOPolicy()
        guard !Task.isCancelled, let anchor = volumeAnchor, anchor.contains(url), url.path != anchor.url.path,
              maximumBytes >= 0, maximumBytes < Int.max,
              let parent = anchor.openDirectory(url.deletingLastPathComponent()) else { return nil }
        defer { close(parent) }
        let name = url.lastPathComponent
        guard let expected = FileFacts.at(name, in: parent), expected.device == anchor.identity.directory.device,
              expected.isRegularFile, !expected.isDataless, expected.linkCount == 1,
              (0...Int64(maximumBytes)).contains(expected.size) else { return nil }

        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC | O_RESOLVE_BENEATH)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, anchor.matchesMount(of: fd, stat: info),
              let before = FileFacts.openFile(fd), before.isRegularFile, !before.isDataless,
              before.isUnchanged(comparedTo: expected) else { return nil }

        guard !Task.isCancelled else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.read(upToCount: Int(before.size) + 1) ?? Data()
        } catch {
            return nil
        }
        guard data.count == Int(before.size),
              let after = FileFacts.openFile(fd), !after.isDataless, after.isUnchanged(comparedTo: before),
              let current = FileFacts.at(name, in: parent), current.device == after.device,
              current.mode == after.mode, !current.isDataless, current.isUnchanged(comparedTo: after)
        else { return nil }
        StorageOperationContext.reportProgress()
        return data
    }
}

/// The facts retained here were checked on both sides of the measurement.
struct BoundItemIdentity: Sendable {
    let anchor: AnalysisRoot
    let entries: [(URL, FileFacts)]

    func isCurrent() -> Bool {
        !entries.isEmpty && entries.allSatisfy { url, expected in
            guard !Task.isCancelled,
                  let current = VolumeDirectory.entry(url, in: anchor).facts else { return false }
            return current.device == expected.device && current.mode == expected.mode
                && current.flags == expected.flags
                && current.created.tv_sec == expected.created.tv_sec
                && current.created.tv_nsec == expected.created.tv_nsec
                && current.isUnchanged(comparedTo: expected)
        }
    }
}
