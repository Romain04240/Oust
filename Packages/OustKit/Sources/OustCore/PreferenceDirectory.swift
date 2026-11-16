import Darwin
import Foundation

/// L'identité du dossier, y compris quand il est atteint par un autre chemin.
package struct PreferenceDirectory: Sendable, Equatable {
    package struct Identity: Sendable, Equatable {
        package let device: Int32
        package let inode: UInt64
        package let birthSeconds: Int64
        package let birthNanoseconds: Int64

        package init(device: Int32, inode: UInt64, birthSeconds: Int64, birthNanoseconds: Int64) {
            self.device = device
            self.inode = inode
            self.birthSeconds = birthSeconds
            self.birthNanoseconds = birthNanoseconds
        }

        fileprivate init?(_ info: stat) {
            guard info.st_mode & S_IFMT == S_IFDIR else { return nil }
            self.init(device: info.st_dev, inode: UInt64(info.st_ino), birthSeconds: Int64(info.st_birthtimespec.tv_sec),
                      birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
        }
    }

    package let identity: Identity?
    package let isUncertain: Bool
    package let resolvedPath: String?

    package init(identity: Identity?, isUncertain: Bool, resolvedPath: String? = nil) {
        self.identity = identity
        self.isUncertain = isUncertain
        self.resolvedPath = resolvedPath
    }

    package init(_ path: String?) {
        var info = stat()
        guard let path else { self.init(identity: nil, isUncertain: false); return }
        if stat(path, &info) == 0 {
            self.init(identity: Identity(info), isUncertain: false)
            return
        }
        self.init(identity: nil, isUncertain: errno != ENOENT && errno != ENOTDIR)
    }

    /// Un index dépend de l'identité du dossier, mais aussi de sa place dans l'arbre.
    /// Le chemin et l'identité proviennent du même descripteur.
    package static func capturingLocation(at path: String?) -> PreferenceDirectory {
        guard let path else { return PreferenceDirectory(nil) }
        let fd = open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            return PreferenceDirectory(identity: nil, isUncertain: errno != ENOENT && errno != ENOTDIR)
        }
        defer { close(fd) }
        return capturingLocation(openDirectory: fd)
    }

    package static func capturingLocation(openDirectory fd: Int32) -> PreferenceDirectory {
        var info = stat()
        guard fstat(fd, &info) == 0, let identity = Identity(info) else {
            return PreferenceDirectory(identity: nil, isUncertain: true)
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let resolved: String? = buffer.withUnsafeMutableBufferPointer { bytes in
            guard let start = bytes.baseAddress, fcntl(fd, F_GETPATH, start) == 0, bytes.last == 0 else { return nil }
            return String(validatingCString: start)
        }
        guard let resolved, resolved.hasPrefix("/") else {
            return PreferenceDirectory(identity: identity, isUncertain: true)
        }
        return PreferenceDirectory(identity: identity, isUncertain: false, resolvedPath: resolved)
    }

    package static func url(in home: URL) -> URL {
        home.appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    package static func isPlist(_ name: String) -> Bool {
        name.range(of: ".plist", options: [.caseInsensitive, .anchored, .backwards]) != nil
    }

    package func matches(_ directory: String) -> Bool {
        guard let identity else { return false }
        var info = stat()
        guard stat(directory, &info) == 0 else { return false }
        return Identity(info) == identity
    }

    package func matches(openDirectory fd: Int32) -> Bool {
        guard let identity else { return false }
        var info = stat()
        return fstat(fd, &info) == 0 && Identity(info) == identity
    }
}
