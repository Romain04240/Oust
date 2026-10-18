import Darwin
import Foundation
import OustCore

/// Ce qu'un volume est, au-delà de sa capacité : son système de fichiers, et
/// s'il accepte qu'on y écrive. De quoi analyser un autre disque comme le
/// disque de démarrage, sans y proposer ce qui ne pourrait pas partir.
public struct VolumeFacts: Sendable, Hashable {
    /// `apfs`, `hfs`, `exfat`, `msdos`, `ntfs`, `smbfs`…, en minuscules.
    public let fileSystem: String
    public let isReadOnly: Bool
    public let isLocal: Bool

    public init(fileSystem: String, isReadOnly: Bool, isLocal: Bool) {
        self.fileSystem = fileSystem
        self.isReadOnly = isReadOnly
        self.isLocal = isLocal
    }
}

extension VolumeService {

    /// Ce que `statfs` dit du volume qui porte `url`.
    public static func facts(of url: URL) -> VolumeFacts? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let type = withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return VolumeFacts(fileSystem: type.lowercased(), isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
                           isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0)
    }
}
