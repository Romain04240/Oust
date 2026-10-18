import Darwin
import Foundation

/// Les fichiers que les processus de l'utilisateur gardent ouverts, par `libproc`
/// (ce que fait `lsof`, sans le lancer).
///
/// Remplacer un fichier ouvert par un autre ne change rien pour le processus qui
/// le tient : il continue d'écrire dans l'ancien, que plus personne ne lira. La
/// compression sur place écarte donc tout ce qui est ouvert au moment de passer.
public enum OpenFiles {

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
