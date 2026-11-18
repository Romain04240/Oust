import Darwin
import Foundation

/// A read-only directory opened for one analysis. Paths below it are labels
/// and relative lookup names. The retained descriptor authorizes the lookup.
package final class AnalysisRoot: Sendable {
    package struct Identity: Hashable, Sendable {
        package let directory: VolumeMountIdentity
        package let filesystem: [Int32]
    }

    package let url: URL
    package let identity: Identity
    private let descriptor: Int32

    package init?(_ url: URL) {
        guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard let identity = Self.directoryIdentity(fd) else {
            close(fd)
            return nil
        }
        self.url = url
        self.identity = identity
        self.descriptor = fd
    }

    deinit { close(descriptor) }

    /// The caller owns the returned descriptor. Checking each component also
    /// rejects a nested mount when the initial and final devices look alike.
    package func openDirectory(_ url: URL, allowing: (URL, stat) -> Bool = { _, _ in true }) -> Int32? {
        guard let components = components(of: url) else { return nil }
        let progress = StorageOperationContext.progress
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC
        // A fresh open description gives each directory reader its own offset.
        var fd = openat(descriptor, ".", flags)
        guard fd >= 0 else { return nil }
        var current = self.url
        for (index, component) in ([""] + components).enumerated() {
            if index > 0 {
                let next = openat(fd, component, flags)
                close(fd)
                guard next >= 0 else { return nil }
                fd = next
                current.appendPathComponent(component, isDirectory: true)
            }
            var info = stat()
            guard fstat(fd, &info) == 0, matchesMount(of: fd, stat: info), allowing(current, info) else {
                close(fd)
                return nil
            }
            progress?.reportProgress()
        }
        return fd
    }

    package func contains(_ url: URL) -> Bool { components(of: url) != nil }

    package func matchesMount(of fd: Int32, stat info: stat) -> Bool {
        info.st_dev == identity.directory.device && Self.filesystem(of: fd) == identity.filesystem
    }

    private func components(of child: URL) -> [String]? {
        guard child.isFileURL else { return nil }
        let base = url.pathComponents
        let path = child.pathComponents
        guard path.starts(with: base) else { return nil }
        let relative = Array(path.dropFirst(base.count))
        guard !relative.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("/") })
        else { return nil }
        return relative
    }

    private static func directoryIdentity(_ fd: Int32) -> Identity? {
        var info = stat()
        guard fstat(fd, &info) == 0, let filesystem = filesystem(of: fd) else { return nil }
        return Identity(directory: VolumeMountIdentity(device: info.st_dev, inode: UInt64(info.st_ino),
                                                        createdSeconds: info.st_birthtimespec.tv_sec,
                                                        createdNanoseconds: info.st_birthtimespec.tv_nsec,
                                                        filesystemID: filesystem),
                        filesystem: filesystem)
    }

    private static func filesystem(of fd: Int32) -> [Int32]? {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return nil }
        return MountedFileSystems.identity(of: info)
    }
}
