import Darwin
import Foundation
import Synchronization

/// Le panneau natif reçoit uniquement ces copies privées.
package final class DuplicatePreviewCopies: Sendable {
    package struct Source: Sendable {
        let url: URL
        let identity: DuplicateReadIdentity?

        package init(_ file: DuplicateFile) {
            url = file.url
            identity = file.readIdentity
        }

        package init(_ image: SimilarImage) {
            url = image.url
            identity = image.readIdentity
        }
    }

    package static let perFile: Int64 = 32 * 1024 * 1024
    package static let perGroup: Int64 = 64 * 1024 * 1024
    private static let reserved = Mutex(Int64(0))

    package let urls: [URL: URL]
    private let directory: StagingDirectory
    private let children: [StagedFile]
    private let limit: Int64

    private init(urls: [URL: URL], directory: StagingDirectory, children: [StagedFile], limit: Int64) {
        self.urls = urls
        self.directory = directory
        self.children = children
        self.limit = limit
    }

    deinit {
        if directory.clean(children) { Self.reserved.withLock { $0 -= limit } }
    }

    private struct FileStamp: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    private struct StagedFile: Sendable {
        let descriptor: Int32
        let directoryName: String
        let fileName: String
        var stamp: FileStamp?
    }

    private struct StagingDirectory: Sendable {
        let url: URL
        let parent: Int32
        let descriptor: Int32

        init?(_ url: URL) {
            self.url = url
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let parent = open(url.deletingLastPathComponent().path, flags)
            guard parent >= 0 else { return nil }
            let folder = openat(parent, url.lastPathComponent, flags)
            guard folder >= 0 else { close(parent); return nil }
            self.parent = parent
            descriptor = folder
        }

        func createChild(_ name: String, fileName: String) -> StagedFile? {
            guard mkdirat(descriptor, name, 0o700) == 0 else { return nil }
            let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return nil }
            return StagedFile(descriptor: child, directoryName: name, fileName: fileName)
        }

        var isCurrent: Bool { Self.matches(descriptor, parent: parent, name: url.lastPathComponent) }

        func clean(_ children: [StagedFile]) -> Bool {
            defer { close(descriptor); close(parent) }
            var complete = true
            for child in children {
                if let stamp = child.stamp {
                    var info = stat()
                    if fstatat(child.descriptor, child.fileName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                        if FileStamp(info) != stamp || unlinkat(child.descriptor, child.fileName, 0) != 0 {
                            complete = false
                        }
                    } else if errno != ENOENT {
                        complete = false
                    }
                }
                if Self.matches(child.descriptor, parent: descriptor, name: child.directoryName) {
                    if unlinkat(descriptor, child.directoryName, AT_REMOVEDIR) != 0 { complete = false }
                } else {
                    complete = false
                }
                close(child.descriptor)
            }
            guard isCurrent else { return false }
            // Ne jamais descendre dans le dossier qu'un autre chemin désigne.
            return unlinkat(parent, url.lastPathComponent, AT_REMOVEDIR) == 0 && complete
        }

        private static func matches(_ descriptor: Int32, parent: Int32, name: String) -> Bool {
            var opened = stat()
            var named = stat()
            return fstat(descriptor, &opened) == 0
                && fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0
                && FileStamp(opened) == FileStamp(named)
        }
    }

    package static func prepare(
        _ selected: URL, sources: [Source], exclusions: DuplicateExclusions,
        maximumFileBytes: Int64 = perFile, maximumGroupBytes: Int64 = perGroup
    ) -> DuplicatePreviewCopies? {
        guard !exclusions.analysisRoots.isEmpty, let first = sources.first(where: { $0.url == selected }),
              let size = first.identity?.size,
              (1...perFile).contains(maximumFileBytes), (1...perGroup).contains(maximumGroupBytes),
              size <= min(maximumFileBytes, maximumGroupBytes) else { return nil }
        guard reserved.withLock({ bytes in
            guard bytes + maximumGroupBytes <= 4 * perGroup else { return false }
            bytes += maximumGroupBytes
            return true
        }) else { return nil }
        var keep = false
        var directory: StagingDirectory?
        var children: [StagedFile] = []
        var created = false
        defer {
            if !keep, directory?.clean(children) ?? !created {
                reserved.withLock { $0 -= maximumGroupBytes }
            }
        }
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-preview.XXXXXX").path.utf8CString)
        guard let folder = template.withUnsafeMutableBufferPointer({ buffer -> URL? in
            guard let path = buffer.baseAddress, mkdtemp(path) != nil else { return nil }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }) else { return nil }
        created = true
        guard let staging = StagingDirectory(folder) else { return nil }
        directory = staging
        var remaining = maximumGroupBytes
        var urls: [URL: URL] = [:]
        let candidates = [first] + Array(sources.lazy.filter { $0.url != selected }.prefix(15))
        for (index, source) in candidates.enumerated() {
            guard !Task.isCancelled else { return nil }
            guard urls[source.url] == nil, let identity = source.identity,
                  identity.size <= min(maximumFileBytes, remaining) else { continue }
            remaining -= identity.size
            let name = source.url.lastPathComponent
            guard var child = staging.createChild(String(index), fileName: name) else {
                if source.url == selected { return nil }
                continue
            }
            let copied = copy(source, identity: identity, to: &child, exclusions: exclusions)
            children.append(child)
            guard copied else {
                if source.url == selected { return nil }
                continue
            }
            urls[source.url] = folder.appendingPathComponent(child.directoryName, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
        }
        guard urls[selected] != nil, staging.isCurrent, !Task.isCancelled else { return nil }
        keep = true
        return DuplicatePreviewCopies(urls: urls, directory: staging, children: children, limit: maximumGroupBytes)
    }

    private static func copy(_ source: Source, identity: DuplicateReadIdentity, to destination: inout StagedFile,
                             exclusions: DuplicateExclusions) -> Bool {
        do {
            return try exclusions.withRead(source.url, expected: identity) { input, size in
                let fd = openat(destination.descriptor, destination.fileName,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { return nil }
                let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? writer.close() }
                var info = stat()
                guard fstat(fd, &info) == 0 else { return nil }
                destination.stamp = FileStamp(info)
                var remaining = size
                while remaining > 0 {
                    guard !Task.isCancelled,
                          let data = try input.read(upToCount: Int(min(remaining, 128 * 1024))),
                          !data.isEmpty else { return nil }
                    try writer.write(contentsOf: data)
                    remaining -= Int64(data.count)
                }
                return true
            } == true
        } catch {
            return false
        }
    }
}
