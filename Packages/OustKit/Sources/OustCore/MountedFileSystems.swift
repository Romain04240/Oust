import Darwin
import Foundation

/// The kernel's last known mount table. No volume metadata reads are needed.
package enum MountedFileSystems {
    package struct Entry: Sendable, Equatable {
        package let path: String
        package let type: String
        package let source: String
        package let identity: [Int32]
        package let isLocal: Bool
        package let isHidden: Bool

        package var isExternalCandidate: Bool {
            path != "/" && (!path.hasPrefix("/System/Volumes/") || path.hasPrefix("/System/Volumes/Data/"))
        }

        package init(path: String, type: String, source: String, identity: [Int32], isLocal: Bool, isHidden: Bool) {
            self.path = path
            self.type = type
            self.source = source
            self.identity = identity
            self.isLocal = isLocal
            self.isHidden = isHidden
        }
    }

    package static func read() -> [Entry]? {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return nil }
        let stride = MemoryLayout<statfs>.stride
        for extra in [16, 64, 256] {
            let capacity = Int(count) + extra
            guard capacity <= Int(Int32.max) / stride else { return nil }
            let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            let filled = getfsstat(buffer, Int32(stride * capacity), MNT_NOWAIT)
            guard filled > 0 else { return nil }
            guard filled < capacity else { continue }
            let entries: [Entry] = (0..<Int(filled)).compactMap { index in
                var info = buffer[index]
                guard let path = string(&info.f_mntonname), path.hasPrefix("/") else { return nil }
                return Entry(path: path, type: string(&info.f_fstypename) ?? "",
                             source: string(&info.f_mntfromname) ?? "", identity: identity(of: info),
                             isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0,
                             isHidden: info.f_flags & UInt32(MNT_DONTBROWSE) != 0)
            }
            return entries.count == Int(filled) ? entries : nil
        }
        return nil
    }

    package static func identity(of info: statfs) -> [Int32] {
        [info.f_fsid.val.0, info.f_fsid.val.1]
    }

    private static func string<T>(_ field: inout T) -> String? {
        withUnsafeBytes(of: &field) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
    }
}
