import Darwin
import Foundation
import OustCore
import OustScan

/// Un dossier explicitement choisi, attaché à son emplacement et à son identité.
public struct DuplicateExclusion: Codable, Equatable, Identifiable, Sendable {
    public let url: URL
    private let volume: String
    private let inode: UInt64
    private let bornSeconds: Int
    private let bornNanoseconds: Int

    public var id: URL { url }

    public init?(folder: URL) {
        guard folder.isFileURL, folder.path != "/" else { return nil }
        let url = Self.systemPath(folder)
        guard let info = Self.directories(to: url)?.first,
              let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsLocalKey]),
              values.volumeIsLocal == true, let volume = values.volumeUUIDString else { return nil }
        self.url = url
        self.volume = volume
        self.inode = UInt64(info.st_ino)
        self.bornSeconds = info.st_birthtimespec.tv_sec
        self.bornNanoseconds = info.st_birthtimespec.tv_nsec
    }

    public var isCurrent: Bool { Self(folder: url) == self }

    fileprivate func matches(_ info: stat) -> Bool {
        inode == UInt64(info.st_ino) && bornSeconds == info.st_birthtimespec.tv_sec
            && bornNanoseconds == info.st_birthtimespec.tv_nsec
    }

    /// Seuls les alias historiques de macOS sont normalisés ici. Un lien dans
    /// un dossier choisi doit être détecté par lstat, jamais résolu.
    fileprivate static func systemPath(_ url: URL) -> URL {
        let path = url.path
        for prefix in ["/var", "/tmp", "/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
            return URL(fileURLWithPath: "/private" + path, isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    fileprivate static func directories(to url: URL) -> [stat]? {
        var path = "/"
        var result: [stat] = []
        let components = url.pathComponents.dropFirst()
        guard !components.contains("."), !components.contains("..") else { return nil }
        for component in [""] + components {
            if !component.isEmpty { path = (path as NSString).appendingPathComponent(component) }
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            result.append(info)
        }
        return result.reversed()
    }

    fileprivate func mayAffect(_ root: URL) -> Bool {
        let path = Self.systemPath(root).path
        // Le chemin enregistré peut désormais désigner un autre volume.
        if path == url.path || path.hasPrefix(url.path + "/") || url.path.hasPrefix(path == "/" ? "/" : path + "/") {
            return true
        }
        guard let rootVolume = try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { return true }
        return rootVolume == volume
    }
}

public struct DuplicateExclusions: Equatable, Sendable {
    public let folders: [DuplicateExclusion]
    public let isReadable: Bool
    package var analysisRoots: [AnalysisRoot] = []

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.folders == rhs.folders && lhs.isReadable == rhs.isReadable
            && lhs.analysisRoots.map(\.url) == rhs.analysisRoots.map(\.url)
            && lhs.analysisRoots.map(\.identity) == rhs.analysisRoots.map(\.identity)
    }

    public init(folders: [DuplicateExclusion] = [], isReadable: Bool = true) {
        self.folders = folders
        self.isReadable = isReadable
    }

    public func canSearch(_ roots: [URL]) -> Bool {
        isReadable && !folders.contains { folder in
            !folder.isCurrent && roots.contains(where: folder.mayAffect)
        }
    }

    func permitsDirectory(_ url: URL) -> Bool {
        guard isReadable else { return false }
        guard !folders.isEmpty else { return true }
        let path = DuplicateExclusion.systemPath(url)
        guard let ancestors = DuplicateExclusion.directories(to: path) else { return false }
        return !folders.contains { folder in
            path.path == folder.url.path || path.path.hasPrefix(folder.url.path + "/")
                || ancestors.contains(where: folder.matches)
        }
    }

    func permitsFile(_ url: URL) -> Bool {
        guard isReadable else { return false }
        guard !folders.isEmpty else { return true }
        var info = stat()
        return permitsDirectory(url.deletingLastPathComponent()) && lstat(url.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1
    }
}

/// Identité et version du fichier à lire, indépendantes du nom qui y mène.
struct DuplicateReadIdentity: Equatable, Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let birthSeconds: Int
    let birthNanoseconds: Int
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    var modified: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1e9) }
    var created: Date { Date(timeIntervalSince1970: Double(birthSeconds) + Double(birthNanoseconds) / 1e9) }
    var fileID: String { "\(device):\(inode)" }

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        birthSeconds = info.st_birthtimespec.tv_sec
        birthNanoseconds = info.st_birthtimespec.tv_nsec
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    func sameDirectory(as other: Self) -> Bool {
        device == other.device && inode == other.inode
            && birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds
    }
}

extension DuplicateExclusions {
    var requiresBoundRead: Bool { !isReadable || !folders.isEmpty || !analysisRoots.isEmpty }

    // SF_DATALESS is not consistently exposed by the Swift Darwin overlay.
    static let dataless: UInt32 = 0x4000_0000

    func readIdentity(_ url: URL) -> DuplicateReadIdentity? {
        guard isReadable, url.isFileURL, !url.path.isEmpty,
              let parent = openParent(of: url) else { return nil }
        defer { close(parent.fd) }
        return Self.fileIdentity(parent.fd, name: parent.name)
    }

    /// Le lecteur reçoit le descripteur ouvert, jamais une adresse à rouvrir.
    func withRead<T>(_ url: URL, expected: DuplicateReadIdentity?, beforeOpen: () -> Void = {},
                     _ read: (FileHandle, Int64) throws -> T?) rethrows -> T? {
        guard isReadable, url.isFileURL, let expected, let parent = openParent(of: url) else { return nil }
        defer { close(parent.fd) }
        guard Self.fileIdentity(parent.fd, name: parent.name) == expected else { return nil }
        beforeOpen()
        let fd = openat(parent.fd, parent.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }

        func stillAdmitted() -> Bool {
            var opened = stat()
            guard fstat(fd, &opened) == 0, Self.regularIdentity(opened) == expected,
                  parent.root?.matchesMount(of: fd, stat: opened) != false,
                  let current = openParent(of: url) else { return false }
            defer { close(current.fd) }
            return current.chain.elementsEqual(parent.chain) { $0.sameDirectory(as: $1) }
                && Self.fileIdentity(current.fd, name: current.name) == expected
                && canSearch([url.deletingLastPathComponent()])
        }

        guard stillAdmitted(), let value = try read(handle, expected.size), stillAdmitted() else { return nil }
        return value
    }

    func storage(of url: URL, expected: DuplicateReadIdentity?)
    -> (allocated: Int64, privateSize: Int64?, fullCloneID: UInt64?)? {
        withRead(url, expected: expected) { handle, _ in
            let fd = handle.fileDescriptor
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            let allocated = Int64(info.st_blocks) * 512
            let sharing = Scanner.blockSharing(fileDescriptor: fd, allocated: allocated)
            return (allocated, sharing.privateSize, sharing.fullCloneID)
        }
    }

    func cloneKey(of url: URL, identity: DuplicateReadIdentity) -> DuplicateContentKey? {
        guard let cloneID = storage(of: url, expected: identity)?.fullCloneID else { return nil }
        return DuplicateContentKey(device: identity.device, identifier: Int64(bitPattern: cloneID))
    }

    private func openParent(of url: URL) -> (fd: Int32, name: String, chain: [DuplicateReadIdentity], root: AnalysisRoot?)? {
        let parent = DuplicateExclusion.systemPath(url.deletingLastPathComponent())
        let pieces = parent.pathComponents.dropFirst()
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != "..",
              !pieces.contains("."), !pieces.contains(".."), parent.path.hasPrefix("/") else { return nil }
        if !analysisRoots.isEmpty {
            guard let root = analysisRoots.filter({ $0.contains(parent) }).max(by: { $0.url.path.count < $1.url.path.count })
            else { return nil }
            var chain: [DuplicateReadIdentity] = []
            guard let fd = root.openDirectory(parent, allowing: { url, info in
                guard permitsBoundDirectory(url, info) else { return false }
                chain.append(DuplicateReadIdentity(info))
                return true
            }) else { return nil }
            return (fd, name, chain, root)
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = open("/", flags)
        guard fd >= 0 else { return nil }
        var chain: [DuplicateReadIdentity] = []
        var walked = "/"
        for piece in [""] + pieces {
            if !piece.isEmpty {
                let next = openat(fd, piece, flags)
                close(fd)
                guard next >= 0 else { return nil }
                fd = next
                walked = (walked as NSString).appendingPathComponent(piece)
            }
            var info = stat()
            guard fstat(fd, &info) == 0,
                  !folders.contains(where: { $0.url.path == walked || $0.matches(info) }) else {
                close(fd)
                return nil
            }
            chain.append(DuplicateReadIdentity(info))
        }
        return (fd, name, chain, nil)
    }

    func permitsBoundDirectory(_ url: URL, _ info: stat) -> Bool {
        isReadable && info.st_flags & Self.dataless == 0 && !folders.contains { folder in
            url.path == folder.url.path || url.path.hasPrefix(folder.url.path + "/") || folder.matches(info)
        }
    }

    private static func fileIdentity(_ parent: Int32, name: String) -> DuplicateReadIdentity? {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return regularIdentity(info)
    }

    static func regularIdentity(_ info: stat) -> DuplicateReadIdentity? {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_flags & dataless == 0 else { return nil }
        return DuplicateReadIdentity(info)
    }
}

/// Un identifiant de flux APFS n'est unique qu'à l'intérieur d'un volume.
struct DuplicateContentKey: Hashable {
    let device: dev_t?
    let identifier: Int64
}
