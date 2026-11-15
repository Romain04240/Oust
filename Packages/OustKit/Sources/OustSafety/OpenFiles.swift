import Darwin
import Foundation

/// Les fichiers que les processus de l'utilisateur gardent ouverts, par `libproc`
/// (ce que fait `lsof`, sans le lancer).
///
/// Remplacer un fichier ouvert par un autre ne change rien pour le processus qui
/// le tient : il continue d'écrire dans l'ancien, que plus personne ne lira. La
/// compression sur place écarte donc tout ce qui est ouvert au moment de passer.
public enum OpenFiles {
    public enum Status: Sendable {
        case open, closed, unknown
    }

    /// La recherche système peut ignorer un processus illisible. Un résultat
    /// positif suffit, mais un résultat vide doit être vérifié séparément.
    public static func status(at path: String) -> Status {
        let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, 0, nil, 0)
        guard bytes > 0 else { return .unknown }
        let stride = MemoryLayout<Int32>.stride
        var pids = [Int32](repeating: 0, count: Int(bytes) / stride + 64)
        let used = pids.withUnsafeMutableBytes {
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, 0, $0.baseAddress, Int32($0.count))
        }
        guard used >= 0, Int(used) < pids.count * stride, Int(used) % stride == 0 else { return .unknown }
        if used > 0 { return .open }
        guard let facts = FileFacts.of(path), facts.isRegularFile else { return .unknown }
        return status(device: facts.device, inode: facts.inode)
    }

    private static func status(device: Int32, inode: UInt64) -> Status {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return .unknown }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0, Int(filled) < pids.count else { return .unknown }
        var complete = true
        let me = getuid()
        let stride = MemoryLayout<proc_fdinfo>.stride
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdshortinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, infoSize) == infoSize else {
                if !hasExited(pid) { complete = false }
                continue
            }
            guard info.pbsi_uid == me else { continue }
            errno = 0
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else {
                if errno != 0 && !hasExited(pid) { complete = false }
                continue
            }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
            errno = 0
            let used = descriptors.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            if (used == 0 && errno != 0) || Int(used) >= descriptors.count * stride || Int(used) % stride != 0 {
                if !hasExited(pid) { complete = false }
                continue
            }
            for descriptor in descriptors.prefix(Int(used) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vnode = vnode_fdinfo()
                let vnodeSize = Int32(MemoryLayout<vnode_fdinfo>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEINFO, &vnode, vnodeSize) == vnodeSize else {
                    if !hasExited(pid) { complete = false }
                    continue
                }
                if vnode.pvi.vi_stat.vst_dev == UInt32(bitPattern: device), vnode.pvi.vi_stat.vst_ino == inode {
                    return .open
                }
            }
        }
        return complete ? .closed : .unknown
    }

    private static func hasExited(_ pid: Int32) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    /// Les chemins ouverts sous `root` (normalisés).
    public static func paths(under root: String) -> Set<String> {
        let base = PathNormalizer.normalize(root)
        var found = Set<String>()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return found }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        guard filled > 0 else { return found }
        let me = getuid()
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdshortinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, infoSize) == infoSize, info.pbsi_uid == me else { continue }
            for path in openPaths(of: pid) where PathNormalizer.isWithin(path, base) {
                found.insert(PathNormalizer.normalize(path))
            }
        }
        return found
    }

    /// Les processus de l'utilisateur qui gardent un fichier ouvert sous `root`,
    /// pour dire qui empêche d'éjecter ou de formater un disque — le Finder dit
    /// seulement « le disque est utilisé ».
    public static func holders(under root: String) -> [OpenFileHolder] {
        let base = PathNormalizer.normalize(root)
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        guard filled > 0 else { return [] }
        let me = getuid()
        var holders: [OpenFileHolder] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 && pid != getpid() {
            var info = proc_bsdshortinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, infoSize) == infoSize, info.pbsi_uid == me else { continue }
            guard openPaths(of: pid).contains(where: { PathNormalizer.isWithin($0, base) }) else { continue }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            holders.append(OpenFileHolder(pid: pid, name: String(cString: name)))
        }
        return holders
    }

    static func openPaths(of pid: Int32) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let used = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(used) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, vnodeSize) == vnodeSize else { continue }
            let path = withUnsafeBytes(of: &vnode.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}

/// Un processus qui garde un fichier ouvert.
public struct OpenFileHolder: Sendable, Hashable {
    public let pid: Int32
    /// Le nom court du processus (`proc_name`) ; l'interface préfère celui de
    /// l'application quand il y en a une.
    public let name: String
}
