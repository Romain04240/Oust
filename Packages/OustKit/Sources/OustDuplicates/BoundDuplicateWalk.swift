import Darwin
import Foundation
import OustScan
import UniformTypeIdentifiers

extension DuplicateExclusions {
    /// Enumerates names and metadata through the admitted directories.
    func walkBound(
        cancelled: () -> Bool,
        descend: (URL) -> Bool,
        enter: (Int32) -> Bool = { _ in true },
        file: (URL, stat) -> Void
    ) {
        let mountPoints = MountTable.mountPoints()
        var packages: [String: Bool] = [:]
        for root in analysisRoots where permitsDirectory(root.url) {
            var pending = [root.url]
            while let url = pending.popLast(), !cancelled() {
                guard let fd = root.openDirectory(url, allowing: permitsBoundDirectory) else { continue }
                guard enter(fd), let directory = fdopendir(fd) else {
                    close(fd)
                    continue
                }
                defer { closedir(directory) }
                while !cancelled(), let entry = readdir(directory) {
                    let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                        String(bytes: bytes.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
                    }
                    guard let name, !name.hasPrefix("."), !name.isEmpty else { continue }
                    let child = url.appendingPathComponent(name, isDirectory: false)
                    guard !mountPoints.contains(child.path) else { continue }
                    var info = stat()
                    guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                          info.st_flags & UInt32(UF_HIDDEN) == 0,
                          info.st_dev == root.identity.directory.device else { continue }
                    switch info.st_mode & S_IFMT {
                    case S_IFDIR:
                        let ext = child.pathExtension.lowercased()
                        let isPackage = packages[ext] ?? (UTType(filenameExtension: ext)?.conforms(to: .package) == true)
                        packages[ext] = isPackage
                        if !isPackage, permitsBoundDirectory(child, info), descend(child) { pending.append(child) }
                    case S_IFREG:
                        file(child, info)
                    default:
                        continue
                    }
                }
            }
        }
    }
}
