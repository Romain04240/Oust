import CryptoKit
import Darwin
import Foundation
import OustClean
import OustCore
import Synchronization

/// Une entrée de la copie, telle qu'elle a été vérifiée.
public struct ManifestEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case directory
        case file(size: Int64, sha256: String)
        case symlink(target: String)
    }

    public let relativePath: String
    public let kind: Kind
}

/// Une copie terminée et vérifiée.
public struct ArchiveCopy: Sendable {
    public let source: URL
    public let destination: URL
    public let entries: [ManifestEntry]
    public let bytes: Int64

    public var fileCount: Int {
        entries.filter { if case .file = $0.kind { true } else { false } }.count
    }
}

/// Pourquoi une copie a échoué. Dans tous les cas, l'original n'a pas bougé.
public enum ArchiveError: Error, Sendable, Hashable {
    case cancelled
    /// Un socket, un tube nommé, un périphérique : rien qu'une archive puisse garder.
    case unsupportedFile(path: String)
    /// Un autre volume est monté dans le projet.
    case crossesVolume(path: String)
    case readFailed(path: String, code: Int32)
    case copyFailed(path: String, code: Int32)
    /// La copie relue ne correspond pas à l'original (taille, empreinte, structure).
    case verificationFailed(path: String)
    /// L'original a changé pendant la copie.
    case sourceChanged(path: String)

    public var localizationKey: String {
        switch self {
        case .cancelled: "archive.error.cancelled"
        case .unsupportedFile: "archive.error.unsupportedFile"
        case .crossesVolume: "archive.error.crossesVolume"
        case .readFailed: "archive.error.readFailed"
        case .copyFailed: "archive.error.copyFailed"
        case .verificationFailed: "archive.error.verificationFailed"
        case .sourceChanged: "archive.error.sourceChanged"
        }
    }

    /// Le chemin concerné, relatif au projet.
    public var path: String? {
        switch self {
        case .cancelled: nil
        case .unsupportedFile(let path), .crossesVolume(let path), .readFailed(let path, _), .copyFailed(let path, _),
             .verificationFailed(let path), .sourceChanged(let path): path
        }
    }
}

/// L'avancement d'une archive, lisible depuis l'interface pendant la copie.
public final class ArchiveProgress: Sendable {
    private let copied = Atomic<Int64>(0)
    private let files = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)

    public init() {}

    public var copiedBytes: Int64 { copied.load(ordering: .relaxed) }
    public var copiedFiles: Int { files.load(ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }

    func add(bytes: Int64) {
        copied.add(bytes, ordering: .relaxed)
        files.add(1, ordering: .relaxed)
    }
}

/// Ce qu'il faudra écrire, mesuré avant de copier.
public struct ArchivePlan: Sendable, Hashable {
    /// La taille logique : sur le volume d'arrivée, rien n'est compressé ni partagé.
    public let logicalBytes: Int64
    public let largestFile: String?
    public let largestFileSize: Int64
    public let device: Int32

    /// Le volume d'un projet, pour refuser d'archiver sur le disque qu'on veut libérer.
    public static func device(of url: URL) -> Int32? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_dev : nil
    }

    /// Parcours rapide, sans rien lire des fichiers.
    public static func measure(_ project: URL) -> ArchivePlan? {
        var root = stat()
        guard lstat(project.path, &root) == 0 else { return nil }
        var bytes: Int64 = 0
        var largest: (String, Int64)?
        var stack = [project.path]
        while let directory = stack.popLast() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names {
                let path = directory + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR where info.st_dev == root.st_dev: stack.append(path)
                case S_IFREG:
                    bytes += Int64(info.st_size)
                    if Int64(info.st_size) > (largest?.1 ?? -1) { largest = (name, Int64(info.st_size)) }
                default: break
                }
            }
        }
        return ArchivePlan(logicalBytes: bytes, largestFile: largest?.0, largestFileSize: largest?.1 ?? 0,
                           device: root.st_dev)
    }
}

/// Copie un projet vers le volume d'archive et vérifie chaque octet.
///
/// Rien n'est jamais écrasé : la copie se fait dans un dossier de préparation au
/// nom réservé (`ArchiveStaging`), renommé seulement une fois tout vérifié. Une
/// copie interrompue ne peut donc pas passer pour une archive complète.
///
/// Chaque fichier passe par `copyfile(COPYFILE_ALL)`, comme dans le Finder :
/// attributs étendus, ACL, dates, fichiers compressés et liens symboliques sont
/// gardés tels quels, ce qu'une copie « à la main » ratait (un fichier compressé
/// recopié octet par octet puis muni de ses attributs devient illisible).
///
/// La vérification relit la copie après `F_FULLFSYNC` et avec `F_NOCACHE`. Le
/// cache unifié peut encore servir des pages restées en mémoire ; on sait au
/// moins qu'elles ont été écrites sur le disque avant d'être relues.
public struct ArchiveCopier: Sendable {
    /// Pour les tests : abîmer la copie juste avant sa vérification.
    let tamper: (@Sendable (URL) -> Void)?

    public init() {
        self.tamper = nil
    }

    init(tamper: @escaping @Sendable (URL) -> Void) {
        self.tamper = tamper
    }

    /// Le résultat d'une tentative : la copie, ou l'erreur et ce qu'il reste à
    /// retirer (le dossier de préparation, s'il a été créé).
    public struct Attempt: Sendable {
        public let result: Result<ArchiveCopy, ArchiveError>
        public let staging: URL?
    }

    /// Copie `project` dans `folder`. Bloquant : à appeler hors du pool coopératif.
    public func copy(_ project: URL, into folder: URL, appleDouble: Bool, progress: ArchiveProgress) -> Attempt {
        let rootPath = project.standardizedFileURL.path
        var root = stat()
        guard lstat(rootPath, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else {
            return Attempt(result: .failure(.readFailed(path: "", code: errno)), staging: nil)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return Attempt(result: .failure(.copyFailed(path: "", code: EACCES)), staging: nil)
        }
        let staging = folder.appendingPathComponent(ArchiveStaging.name(for: project.lastPathComponent), isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else {
            return Attempt(result: .failure(.copyFailed(path: "", code: errno)), staging: nil)
        }
        do {
            let entries = try copyTree(from: rootPath, device: root.st_dev, to: staging.path, progress: progress)
            try verifyTree(staging.path, against: entries, appleDouble: appleDouble)
            let final = try promote(staging, in: folder, name: project.lastPathComponent)
            let bytes = entries.reduce(Int64(0)) { total, entry in
                if case .file(let size, _) = entry.kind { total + size } else { total }
            }
            return Attempt(result: .success(ArchiveCopy(source: project, destination: final, entries: entries, bytes: bytes)),
                           staging: nil)
        } catch let error as ArchiveError {
            return Attempt(result: .failure(error), staging: staging)
        } catch {
            return Attempt(result: .failure(.copyFailed(path: "", code: EIO)), staging: staging)
        }
    }

    // MARK: Copie

    private func copyTree(from rootPath: String, device: Int32, to stagingPath: String,
                          progress: ArchiveProgress) throws -> [ManifestEntry] {
        var entries: [ManifestEntry] = []
        var directories: [(source: String, destination: String)] = [(rootPath, stagingPath)]
        var pending = [""]
        while let relativeDirectory = pending.popLast() {
            let sourceDirectory = relativeDirectory.isEmpty ? rootPath : rootPath + "/" + relativeDirectory
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: sourceDirectory).sorted()
            } catch {
                throw ArchiveError.readFailed(path: relativeDirectory, code: EACCES)
            }
            for name in names {
                if progress.isCancelled { throw ArchiveError.cancelled }
                let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
                let source = rootPath + "/" + relative
                let destination = stagingPath + "/" + relative
                var info = stat()
                guard lstat(source, &info) == 0 else { throw ArchiveError.readFailed(path: relative, code: errno) }
                guard info.st_dev == device else { throw ArchiveError.crossesVolume(path: relative) }

                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    guard mkdir(destination, 0o700) == 0 else { throw ArchiveError.copyFailed(path: relative, code: errno) }
                    entries.append(ManifestEntry(relativePath: relative, kind: .directory))
                    directories.append((source, destination))
                    pending.append(relative)

                case S_IFREG:
                    entries.append(try copyFile(source, to: destination, relative: relative, before: info))
                    progress.add(bytes: Int64(info.st_size))

                case S_IFLNK:
                    let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
                    guard copyfile(source, destination, nil, flags) == 0 else {
                        throw ArchiveError.copyFailed(path: relative, code: errno)
                    }
                    guard let target = Self.linkTarget(source), Self.linkTarget(destination) == target else {
                        throw ArchiveError.verificationFailed(path: relative)
                    }
                    entries.append(ManifestEntry(relativePath: relative, kind: .symlink(target: target)))

                default:
                    throw ArchiveError.unsupportedFile(path: relative)
                }
            }
        }
        // Les dates et droits des dossiers en dernier, du plus profond au plus haut :
        // y créer un fichier les changerait, et un dossier en lecture seule
        // refuserait ses enfants.
        for (source, destination) in directories.reversed() {
            let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
            guard copyfile(source, destination, nil, flags) == 0 else {
                throw ArchiveError.copyFailed(path: String(source.dropFirst(rootPath.count)), code: errno)
            }
        }
        return entries
    }

    private func copyFile(_ source: String, to destination: String, relative: String,
                          before: stat) throws -> ManifestEntry {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
        guard copyfile(source, destination, nil, flags) == 0 else {
            throw ArchiveError.copyFailed(path: relative, code: errno)
        }
        tamper?(URL(fileURLWithPath: destination))

        let original: String
        do { original = try Self.sha256(of: source, uncached: false) }
        catch { throw ArchiveError.readFailed(path: relative, code: (error as? POSIXError)?.code.rawValue ?? EIO) }
        let copied: String
        do { copied = try Self.sha256(of: destination, uncached: true) }
        catch { throw ArchiveError.verificationFailed(path: relative) }

        var after = stat()
        guard lstat(source, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw ArchiveError.sourceChanged(path: relative)
        }
        var written = stat()
        guard lstat(destination, &written) == 0, written.st_size == before.st_size, copied == original else {
            throw ArchiveError.verificationFailed(path: relative)
        }
        return ManifestEntry(relativePath: relative, kind: .file(size: Int64(before.st_size), sha256: original))
    }

    // MARK: Vérification

    /// La copie entière, relue : chaque entrée attendue est là, du bon type et de
    /// la bonne taille, et rien d'autre — sauf les fichiers `._` que macOS ajoute
    /// sur un volume qui ne garde pas les attributs étendus.
    private func verifyTree(_ stagingPath: String, against entries: [ManifestEntry], appleDouble: Bool) throws {
        var expected: [String: ManifestEntry.Kind] = [:]
        for entry in entries { expected[entry.relativePath] = entry.kind }
        var seen = 0
        var pending = [""]
        while let relativeDirectory = pending.popLast() {
            let directory = relativeDirectory.isEmpty ? stagingPath : stagingPath + "/" + relativeDirectory
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                throw ArchiveError.verificationFailed(path: relativeDirectory)
            }
            for name in names {
                let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
                guard let kind = expected[relative] else {
                    if appleDouble && name.hasPrefix("._") { continue }
                    throw ArchiveError.verificationFailed(path: relative)
                }
                var info = stat()
                guard lstat(directory + "/" + name, &info) == 0 else { throw ArchiveError.verificationFailed(path: relative) }
                switch (kind, info.st_mode & S_IFMT) {
                case (.directory, S_IFDIR):
                    pending.append(relative)
                case (.file(let size, _), S_IFREG) where Int64(info.st_size) == size:
                    break
                case (.symlink(let target), S_IFLNK) where Self.linkTarget(directory + "/" + name) == target:
                    break
                default:
                    throw ArchiveError.verificationFailed(path: relative)
                }
                seen += 1
            }
        }
        guard seen == entries.count else { throw ArchiveError.verificationFailed(path: "") }
    }

    /// Donne à la copie vérifiée son nom définitif, sans jamais écraser : « Projet »,
    /// sinon « Projet 2 », « Projet 3 »…
    private func promote(_ staging: URL, in folder: URL, name: String) throws -> URL {
        for index in 1...999 {
            let candidate = folder.appendingPathComponent(index == 1 ? name : "\(name) \(index)", isDirectory: true)
            if renamex_np(staging.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let code = errno
            if code == EEXIST { continue }
            // Un volume qui ne connaît pas RENAME_EXCL (certains exFAT) : on vérifie
            // à la main, la fenêtre est minuscule et la copie nous appartient.
            if code == ENOTSUP || code == EINVAL {
                var info = stat()
                if lstat(candidate.path, &info) == 0 { continue }
                if rename(staging.path, candidate.path) == 0 { return candidate }
            }
            throw ArchiveError.copyFailed(path: "", code: code)
        }
        throw ArchiveError.copyFailed(path: "", code: EEXIST)
    }

    // MARK: Outils

    /// L'empreinte SHA-256 du contenu. `uncached` : vider vers le disque puis
    /// relire sans remplir le cache.
    static func sha256(of path: String, uncached: Bool) throws -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if uncached {
            if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
            _ = fcntl(fd, F_NOCACHE, 1)
        }
        var hasher = SHA256()
        let size = 1 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = read(fd, buffer.baseAddress, size)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func linkTarget(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(path, &buffer, buffer.count - 1)
        guard length >= 0 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
