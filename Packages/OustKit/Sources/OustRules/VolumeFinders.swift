import Darwin
import Foundation
import OustCore
import OustSafety
import OustScan

/// Un autre disque que celui de démarrage, tel que les chercheurs le voient.
///
/// Romain, 18/10/2026 : « le second peut avoir des applications, des fichiers,
/// des doublons, des photos… il faut lui permettre de pouvoir analyser le disque
/// externe de la même manière qu'on analyse le disque principal ». Le dossier
/// personnel n'y est pas : les chercheurs qui ont un sens sur un disque
/// (`FinderKind.volumeFinders`) le parcourent depuis sa racine.
public struct VolumeScope: Sendable, Hashable {
    /// Le point de montage : `/Volumes/<disque>`.
    public var root: URL
    public var name: String
    /// `apfs`, `hfs`, `exfat`, `msdos`, `ntfs`…
    public var fileSystem: String
    /// Rien n'en partira : chaque élément est protégé, la raison affichée.
    public var isReadOnly: Bool
    /// La corbeille du disque est rangée par utilisateur (`.Trashes/<uid>`).
    public var userID: uid_t

    public init(root: URL, name: String, fileSystem: String, isReadOnly: Bool = false, userID: uid_t = getuid()) {
        self.root = root.standardizedFileURL
        self.name = name
        self.fileSystem = fileSystem.lowercased()
        self.isReadOnly = isReadOnly
        self.userID = userID
    }

    public var isAppleFileSystem: Bool { VolumeProtection.isAppleFileSystem(fileSystem) }
}

extension FinderKind {
    /// Ce qui a un sens sur un autre disque. Le reste (caches de paquets,
    /// Xcode, simulateurs, agents, navigateurs) vit dans le dossier personnel.
    public static let volumeFinders: [FinderKind] = [
        .projectArtifacts, .creative, .pro, .games, .volumeInstallers, .volumeTrash, .volumeTraces, .volumeKept,
    ]

    /// Les chercheurs qui ne trouvent rien sans disque choisi.
    public static let volumeOnly: Set<FinderKind> = [.volumeInstallers, .volumeTrash, .volumeTraces, .volumeKept]

    /// Ceux du disque de démarrage et du dossier personnel : ce que `oust`
    /// propose aux agents, qui n'analysent pas d'autre disque.
    public static var homeCases: [FinderKind] { allCases.filter { !volumeOnly.contains($0) } }
}

extension RuleEngine {
    /// Les petits fichiers que le parcours d'un autre disque doit retenir par
    /// leur nom : les marqueurs de projets, et sur un système de fichiers qui
    /// n'est pas celui de macOS, ses traces (`._*`, `.DS_Store`).
    public static func notableNames(fileSystem: String) -> Set<String> {
        var names = notableNames
        if !VolumeProtection.isAppleFileSystem(fileSystem) {
            names.formUnion([VolumeTraces.appleDoublePrefix + "*", VolumeTraces.desktopServices])
        }
        return names
    }
}

// MARK: - Parcours d'un disque

/// Un dossier du disque tel que les chercheurs le parcourent : d'après l'arbre
/// de l'analyse quand il le couvre, d'après le disque sinon (les tests, un
/// arbre périmé), sans jamais changer de volume (RULES.md, règle 10).
struct VolumeDirectory {
    let url: URL
    let node: TreeNode?

    /// Les sous-dossiers du volume, et les fichiers connus par leur nom. Un
    /// dossier que le parcours n'a pas ouvert (exclu, refusé) est nommé, pas
    /// ouvert ; un point de montage n'est même pas nommé.
    func listing(device: dev_t) -> (directories: [String], files: [String]) {
        if let node {
            guard node.status == .ok else { return ([], []) }
            let directories = node.children.filter { $0.status != .otherVolume && $0.status != .firmlink }.map(\.name)
            return (directories, node.files.map(\.name) + node.notableFiles)
        }
        var directories: [String] = []
        var files: [String] = []
        for name in Self.names(in: url.path) {
            var info = stat()
            guard lstat(url.appendingPathComponent(name).path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR where info.st_dev == device: directories.append(name)
            case S_IFDIR: continue
            default: files.append(name)
            }
        }
        return (directories.sorted(), files.sorted())
    }

    /// Le contenu d'un dossier par `readdir`. `FileManager` tait les fichiers
    /// AppleDouble (`._nom`) : ce sont justement ceux que l'on cherche.
    static func names(in path: String) -> [String] {
        guard let directory = opendir(path) else { return [] }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    func child(_ name: String) -> VolumeDirectory {
        VolumeDirectory(url: url.appendingPathComponent(name, isDirectory: true), node: node?.child(named: name))
    }
}

/// Les paquets dans lesquels on ne descend pas pour chercher des installeurs
/// ou des traces : ce qu'ils contiennent leur appartient.
enum VolumePackages {
    static let extensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "xpc", "photoslibrary", "musiclibrary",
        "tvlibrary", "fcpbundle", "imovielibrary", "logicx", "band", "xcarchive", "xcodeproj", "xcworkspace",
        "sparsebundle", "backupbundle", "lrdata", "cocatalog", "dvdmedia", "rtfd", "pages", "numbers", "key",
    ]

    static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && (extensions.contains(ext) || VolumeProtection.virtualMachinePackages.contains(ext))
    }
}

extension RuleContext {
    /// Chaque dossier du disque, en largeur, hors de ce qu'il ne faut jamais
    /// ouvrir : dossiers de service, corbeille du disque (son propre élément),
    /// transit d'Oust!, sauvegardes Time Machine. `enter` dit s'il faut
    /// descendre dans un dossier ; `visit` reçoit chaque dossier parcouru.
    func walkVolume(_ volume: VolumeScope, enter: (String, URL) -> Bool,
                    visit: (VolumeDirectory, _ directories: [String], _ files: [String]) -> Void) async {
        var info = stat()
        guard lstat(volume.root.path, &info) == 0 else { return }
        let device = info.st_dev
        let tree = await self.tree?()
        let rootNode = tree?.descendant(atPath: volume.root.path)
        var queue = [VolumeDirectory(url: volume.root, node: rootNode)]
        var head = 0
        while head < queue.count {
            let directory = queue[head]
            head += 1
            let (directories, files) = directory.listing(device: device)
            visit(directory, directories, files)
            for name in directories {
                if Self.neverOpened.contains(name) || VolumeProtection.serviceFolders.contains(name) { continue }
                if VolumeProtection.isTimeMachineName(name) || VolumeProtection.isPhotoLibrary(name) { continue }
                let child = directory.child(name)
                if VolumeProtection.isTimeMachineSparseBundle(child.url) { continue }
                if enter(name, child.url) { queue.append(child) }
            }
        }
    }

    /// Jamais ouverts par les chercheurs d'un disque.
    static let neverOpened: Set<String> = [VolumeProtection.volumeTrashFolder, ".oust-transit", ".Trash"]
}

// MARK: - Corbeille du disque

/// La corbeille du Mac sur ce disque : `.Trashes/<uid>` à sa racine.
///
/// Ce qu'on jette depuis un disque externe ne quitte pas ce disque : le Finder
/// le range dans ce dossier caché, et l'espace ne revient qu'une fois la
/// corbeille vidée. C'est souvent pourquoi un disque reste plein après un
/// grand ménage dans le Finder.
struct VolumeTrashFinder {
    let context: RuleContext

    func find() async -> [Candidate] {
        guard let volume = context.volume else { return [] }
        let trash = VolumeProtection.userTrash(on: volume.root, userID: volume.userID)
        var info = stat()
        guard lstat(trash.path, &info) == 0 else { return [] }
        let id = "trash|\(trash.path)"
        // Par `readdir` : sur un disque exFAT, la corbeille garde aussi le `._`
        // de chaque fichier jeté, que `FileManager` tairait.
        guard access(trash.path, R_OK | X_OK) == 0 else {
            var item = CleanupItem(id: id, title: volume.name, detail: trash.path, paths: [trash], category: .trash,
                                   owner: "Finder", ruleID: "trash.volume", safety: .review, method: .removeNow,
                                   rebuild: .irreversible)
            item.protect(.needsFullDiskAccess)
            return [Candidate(item: item, needsMeasure: false)]
        }
        let entries = VolumeDirectory.names(in: trash.path).filter { $0 != ".DS_Store" }.sorted()
            .map { trash.appendingPathComponent($0) }
        guard !entries.isEmpty else { return [] }
        return [Candidate(item: CleanupItem(
            id: id, title: volume.name, detail: "×\(entries.count)", paths: entries, category: .trash,
            owner: "Finder", ruleID: "trash.volume", safety: .review, method: .removeNow, rebuild: .irreversible
        ))]
    }
}

// MARK: - Installeurs

/// Les images disque et paquets d'installation rangés sur le disque.
///
/// « À examiner » : sur un disque externe, un installeur est parfois gardé
/// exprès, en archive. Rien n'est coché d'office (RULES.md, règle 4).
struct VolumeInstallersFinder {
    let context: RuleContext

    static let minimumSize: Int64 = 10_000_000

    func find() async -> [Candidate] {
        guard let volume = context.volume else { return [] }
        var candidates: [Candidate] = []
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        await context.walkVolume(volume, enter: { name, _ in
            !VolumePackages.isPackage(name) && !name.hasPrefix(".")
        }, visit: { directory, _, files in
            for name in files where UserContentFinder.installerExtensions.contains((name as NSString).pathExtension.lowercased()) {
                let url = directory.url.appendingPathComponent(name, isDirectory: false)
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      Int64(info.st_blocks) * 512 >= Self.minimumSize else { continue }
                let modified = (try? url.resourceValues(forKeys: keys))?.contentModificationDate
                candidates.append(Candidate(item: CleanupItem(
                    title: name, detail: directory.url.path, paths: [url], category: .systemDownloads,
                    owner: volume.name, ruleID: "volume.installer", safety: .review, method: .trash,
                    lastActivity: modified, rebuild: .download
                )))
            }
        })
        return candidates
    }
}

// MARK: - Traces de macOS

/// Les fichiers que macOS sème sur un système de fichiers qui n'est pas le sien
/// (exFAT, FAT, NTFS) : un `._nom` (AppleDouble) à côté de chaque fichier qui
/// porte des métadonnées, un `.DS_Store` dans chaque dossier ouvert dans le
/// Finder. Invisibles sur le Mac, ils encombrent le disque sous Windows ou sur
/// une télévision, et chacun prend au moins un bloc entier (128 Ko sur un
/// disque exFAT de 1 To).
///
/// Un `._nom` dont le fichier `nom` existe porte ses métadonnées (étiquettes,
/// commentaires, provenance, icône) : il va à la corbeille du Mac, d'où il se
/// restaure. Sans son fichier, il ne décrit plus rien : il part tout de suite,
/// comme les `.DS_Store`, que le Finder refait en rouvrant le dossier. Tout est
/// « à examiner » : rien n'est coché d'office.
enum VolumeTraces {
    static let appleDoublePrefix = "._"
    static let desktopServices = ".DS_Store"

    static func isProtectedCompanion(_ name: String) -> Bool {
        VolumeProtection.isTimeMachineName(name) || VolumeProtection.isPhotoLibrary(name)
            || VolumeProtection.isVirtualMachine(name) || VolumeProtection.serviceFolders.contains(name)
    }
}

struct VolumeTracesFinder {
    let context: RuleContext

    func find() async -> [Candidate] {
        guard let volume = context.volume, !volume.isAppleFileSystem else { return [] }
        var orphans: [URL] = []
        var orphanSizes = Sizes.zero
        /// Ceux qui ont leur fichier, par dossier de premier niveau : de quoi
        /// garder les métadonnées d'un dossier et pas d'un autre.
        var described: [String: (paths: [URL], sizes: Sizes)] = [:]
        var stores: [URL] = []
        var storeSizes = Sizes.zero
        var latest: Date?

        func size(of url: URL) -> Int64? {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if modified > (latest ?? .distantPast) { latest = modified }
            return Int64(info.st_blocks) * 512
        }

        await context.walkVolume(volume, enter: { name, _ in
            !VolumePackages.isPackage(name)
        }, visit: { directory, directories, files in
            let present = Set(directories).union(files)
            for name in Set(files) {
                let url = directory.url.appendingPathComponent(name, isDirectory: false)
                if name == VolumeTraces.desktopServices {
                    guard let bytes = size(of: url) else { continue }
                    stores.append(url)
                    storeSizes += Sizes(private: bytes)
                    continue
                }
                guard name.hasPrefix(VolumeTraces.appleDoublePrefix), name.count > VolumeTraces.appleDoublePrefix.count
                else { continue }
                let companion = String(name.dropFirst(VolumeTraces.appleDoublePrefix.count))
                // Le `._` de ce qui est protégé l'est avec lui (sauvegarde,
                // photothèque, machine virtuelle) : la garde le refuserait.
                if VolumeTraces.isProtectedCompanion(companion) { continue }
                guard let bytes = size(of: url) else { continue }
                // Celui d'un `.DS_Store` part avec lui : le Finder le refait aussi.
                if companion == VolumeTraces.desktopServices {
                    stores.append(url)
                    storeSizes += Sizes(private: bytes)
                    continue
                }
                var info = stat()
                let exists = present.contains(companion)
                    || lstat(directory.url.appendingPathComponent(companion).path, &info) == 0
                if exists {
                    let group = topLevelFolder(of: directory.url, in: volume) ?? volume.name
                    described[group, default: ([], .zero)].paths.append(url)
                    described[group, default: ([], .zero)].sizes += Sizes(private: bytes)
                } else {
                    orphans.append(url)
                    orphanSizes += Sizes(private: bytes)
                }
            }
        })

        var candidates: [Candidate] = []
        if !orphans.isEmpty {
            candidates.append(trace(id: "volume.appledouble_orphan|\(volume.root.path)", detail: "×\(orphans.count)",
                                    paths: orphans.sorted { $0.path < $1.path }, sizes: orphanSizes, owner: volume.name,
                                    rule: "volume.appledouble_orphan", method: .removeNow, rebuild: .nothing,
                                    latest: latest))
        }
        for (group, found) in described.sorted(by: { $0.key < $1.key }) {
            let paths = found.paths.sorted { $0.path < $1.path }
            candidates.append(trace(id: "volume.appledouble|\(volume.root.path)|\(group)",
                                    detail: "\(group) · ×\(paths.count)", paths: paths, sizes: found.sizes,
                                    owner: volume.name, rule: "volume.appledouble", method: .trash,
                                    rebuild: .irreversible, latest: latest))
        }
        if !stores.isEmpty {
            candidates.append(trace(id: "volume.ds_store|\(volume.root.path)", detail: "×\(stores.count)",
                                    paths: stores.sorted { $0.path < $1.path }, sizes: storeSizes, owner: volume.name,
                                    rule: "volume.ds_store", method: .removeNow, rebuild: .automatic, latest: latest))
        }
        return candidates
    }

    /// Le dossier de premier niveau du disque qui contient `directory`.
    private func topLevelFolder(of directory: URL, in volume: VolumeScope) -> String? {
        let base = volume.root.path
        let path = directory.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        return path.dropFirst(base.count + 1).split(separator: "/").first.map(String.init)
    }

    private func trace(id: String, detail: String, paths: [URL], sizes: Sizes, owner: String, rule: String,
                       method: CleanupMethod, rebuild: RebuildCost, latest: Date?) -> Candidate {
        // Les tailles viennent d'ici, fichier par fichier : l'arbre range ces
        // petits fichiers parmi les « petits éléments » de leur dossier.
        Candidate(item: CleanupItem(
            id: id, title: paths.first?.lastPathComponent ?? rule, detail: detail, paths: paths, category: .diskTraces,
            owner: owner, ruleID: rule, safety: .review, method: method, sizes: sizes, lastActivity: latest,
            rebuild: rebuild
        ), needsMeasure: false)
    }
}

// MARK: - Ce qui reste protégé

/// Ce qu'un disque porte et qu'Oust! montre sans jamais le proposer : les
/// sauvegardes Time Machine, les photothèques et les machines virtuelles. Leur
/// taille dit où est passé l'espace ; leur protection dit pourquoi il y reste.
struct VolumeKeptFinder {
    let context: RuleContext

    func find() async -> [Candidate] {
        guard let volume = context.volume else { return [] }
        var candidates: [Candidate] = []
        var info = stat()
        guard lstat(volume.root.path, &info) == 0 else { return [] }
        let device = info.st_dev
        let tree = await context.tree?()
        var queue = [VolumeDirectory(url: volume.root, node: tree?.descendant(atPath: volume.root.path))]
        var head = 0
        while head < queue.count {
            let directory = queue[head]
            head += 1
            let (directories, files) = directory.listing(device: device)
            for name in directories {
                let child = directory.child(name)
                if let candidate = kept(name: name, url: child.url, volume: volume, isDirectory: true) {
                    candidates.append(candidate)
                    continue
                }
                if RuleContext.neverOpened.contains(name) || VolumeProtection.serviceFolders.contains(name)
                    || name.hasPrefix(".") || VolumePackages.isPackage(name) {
                    continue
                }
                queue.append(child)
            }
            for name in files {
                let url = directory.url.appendingPathComponent(name, isDirectory: false)
                if let candidate = kept(name: name, url: url, volume: volume, isDirectory: false) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    private func kept(name: String, url: URL, volume: VolumeScope, isDirectory: Bool) -> Candidate? {
        // Le `._` d'une sauvegarde ou d'une photothèque n'en est pas une.
        if name.hasPrefix(VolumeTraces.appleDoublePrefix) { return nil }
        if VolumeProtection.isTimeMachineName(name) || (isDirectory && VolumeProtection.isTimeMachineSparseBundle(url)) {
            var item = CleanupItem(title: name, detail: url.deletingLastPathComponent().path, paths: [url],
                                   category: .protectedOnDisk, owner: "Time Machine", ruleID: "volume.time_machine",
                                   safety: .protected, method: .manual, rebuild: .irreversible)
            item.protect(.timeMachine)
            // Jamais mesuré : les sauvegardes HFS+ font des liens physiques de
            // dossiers, et le parcours les compterait une fois par sauvegarde.
            // Le parcours ne les ouvre pas (`ScanOptions.excludedPaths`).
            let measured = name != VolumeProtection.timeMachineFolder
            return Candidate(item: item, needsMeasure: measured)
        }
        if isDirectory, VolumeProtection.isPhotoLibrary(name) {
            var item = CleanupItem(title: (name as NSString).deletingPathExtension, detail: url.deletingLastPathComponent().path,
                                   paths: [url], category: .protectedOnDisk, owner: "Photos",
                                   ruleID: "volume.photo_library", safety: .protected, method: .manual,
                                   rebuild: .irreversible)
            item.protect(.photoLibrary)
            return Candidate(item: item)
        }
        if VolumeProtection.isVirtualMachine(name) {
            // Une image de disque nue n'est une machine virtuelle qu'au-delà de
            // quelques mégaoctets ; un paquet l'est toujours.
            var item = CleanupItem(title: (name as NSString).deletingPathExtension, detail: url.deletingLastPathComponent().path,
                                   paths: [url], category: .virtualMachines, owner: "VM", ruleID: "vm.image",
                                   safety: .protected, notes: [.managedSeparately], method: .manual,
                                   rebuild: .irreversible)
            item.protect(.virtualMachine)
            return Candidate(item: item, minimumAllocated: isDirectory ? 0 : 1_000_000)
        }
        return nil
    }
}
