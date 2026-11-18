import CryptoKit
import Darwin
import Foundation
import OustCore
import OustScan
import Synchronization
import UniformTypeIdentifiers

/// Un fichier d'un groupe de doublons.
public struct DuplicateFile: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let logicalSize: Int64
    public let allocated: Int64
    /// Ce que sa suppression rendrait vraiment.
    public let privateSize: Int64
    public let modified: Date?
    public let created: Date?
    public internal(set) var privateSizeKnown = true
    var readIdentity: DuplicateReadIdentity?
}

/// Des fichiers au contenu identique, octet pour octet.
public struct DuplicateGroup: Sendable, Identifiable {
    public let id: String
    public let files: [DuplicateFile]
    /// Le fichier à garder, ou `nil` si aucune règle ne départage (égalité).
    public let keep: Int?
    /// Les copies proposées au retrait. Jamais toutes (SPEC §7).
    public let proposed: Set<Int>
    /// Ce que coche la sélection automatique, quand l'utilisateur l'a activée :
    /// le choix des règles, et à égalité celui de `SmartSelection.tieBreak`.
    /// Nil s'il n'y a rien à retirer.
    public let automatic: (keep: Int, remove: Set<Int>)?

    public var size: Int64 { files.first?.logicalSize ?? 0 }
    /// Ce que le retrait des copies proposées rendrait.
    public var reclaimable: Int64 { proposed.reduce(0) { $0 + files[$1].privateSize } }
    /// Ce que le groupe pourrait rendre au plus (tout sauf une copie).
    public var potential: Int64 {
        files.map(\.privateSize).sorted().dropLast().reduce(0, +)
    }
}

/// Réglages d'une recherche de doublons.
public struct DuplicateOptions: Sendable {
    public var roots: [URL]
    public var exclusions = DuplicateExclusions()
    public var minimumSize: Int64
    /// Jamais proposés au retrait : les originaux de référence.
    public var referenceFolders: [URL]
    /// Proposés en premier quand une copie existe ailleurs.
    public var preferredForRemoval: [URL]

    public init(roots: [URL], minimumSize: Int64 = 1_000_000, referenceFolders: [URL] = [],
                preferredForRemoval: [URL] = []) {
        self.roots = roots
        self.minimumSize = minimumSize
        self.referenceFolders = referenceFolders
        self.preferredForRemoval = preferredForRemoval
    }

    /// Téléchargements et Bureau : là où atterrissent les copies.
    public static func standard(home: URL) -> DuplicateOptions {
        DuplicateOptions(
            roots: [home],
            preferredForRemoval: [home.appendingPathComponent("Downloads"), home.appendingPathComponent("Desktop")]
        )
    }
}

/// L'avancement d'une recherche de doublons.
public final class DuplicateProgress: Sendable {
    private let cancelled = Atomic<Bool>(false)
    private let examined = Atomic<Int>(0)
    private let hashed = Atomic<Int>(0)
    public init() {}
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
    public func cancel() { cancelled.store(true, ordering: .relaxed) }
    public var filesExamined: Int { examined.load(ordering: .relaxed) }
    public var filesHashed: Int { hashed.load(ordering: .relaxed) }
    func didExamine() { examined.add(1, ordering: .relaxed) }
    func didHash() { hashed.add(1, ordering: .relaxed) }
}

/// La recherche (SPEC §7) : taille, puis identité, puis empreinte partielle,
/// puis empreinte complète. Chaque étape écarte ce qu'elle peut avant la
/// suivante, plus coûteuse.
public enum DuplicateFinder {

    /// Ce qui n'est jamais parcouru : bibliothèques gérées par une application,
    /// dossiers de construction, réglages.
    static let skippedFolders: Set<String> = [
        "Library", "node_modules", ".build", "DerivedData", "Pods", ".git", ".Trash", "Applications",
        ".npm", ".gradle", ".cache", ".cargo", ".pub-cache", ".claude", ".codex",
        // Sur un autre disque : les sauvegardes Time Machine, jamais proposées.
        "Backups.backupdb",
    ]
    /// Des paquets qu'une application tient, même quand elle n'est pas installée
    /// sur ce Mac pour que macOS les reconnaisse : retirer un média d'une
    /// bibliothèque Final Cut l'abîmerait.
    static let skippedExtensions: Set<String> = [
        "photoslibrary", "musiclibrary", "tvlibrary", "app", "xcarchive", "fcpbundle", "imovielibrary", "logicx",
        "band", "sparsebundle", "backupbundle", "utm", "pvm", "vmwarevm", "vbvm", "macvm",
    ]

    /// `tree` : l'arborescence de l'analyse. Ses feuilles (taille, inode,
    /// identifiant de clone) suffisent à trouver les candidats sans reparcourir
    /// le dossier personnel ; sans elle, ou si elle ne couvre pas un dossier,
    /// on le parcourt comme avant.
    public static func find(_ options: DuplicateOptions, tree: TreeNode? = nil,
                            progress: DuplicateProgress = DuplicateProgress()) async -> [DuplicateGroup] {
        // Lire un fichier iCloud non téléchargé pour son empreinte le ferait
        // télécharger : jamais, analyse lancée ou non.
        Scanner.configureProcessIOPolicy()
        guard options.exclusions.canSearch(options.roots) else { return [] }
        let candidates = tree.flatMap { collect(options, from: $0, progress: progress) }
            ?? collect(options, progress: progress)

        // 1. Même taille, sinon rien à comparer.
        let bySize = Dictionary(grouping: candidates, by: \.logicalSize).values.filter { $0.count > 1 }

        var groups: [DuplicateGroup] = []
        for sameSize in bySize {
            guard !progress.isCancelled else { return [] }
            // 2. Liens physiques et clones complets : déjà un seul contenu sur le
            //    disque, en retirer un ne rend rien. On garde un représentant.
            let distinct = collapseShared(sameSize)
            guard distinct.count > 1 else { continue }

            // 3. Empreinte partielle (tête et queue), puis 4. complète.
            let partial = await hashGroups(distinct, progress: progress) {
                guard !progress.isCancelled else { return nil }
                let file = $0
                if options.exclusions.requiresBoundRead {
                    return try options.exclusions.withRead(file.url, expected: file.readIdentity) { handle, size in
                        try partialHash(handle, size: size)
                    }
                }
                return try partialHash(file.url, size: file.logicalSize)
            }
            for samePartial in partial.values where samePartial.count > 1 {
                let full = await hashGroups(samePartial, progress: progress) {
                    guard !progress.isCancelled else { return nil }
                    let file = $0
                    if options.exclusions.requiresBoundRead {
                        return try options.exclusions.withRead(file.url, expected: file.readIdentity) { handle, _ in
                            try fullHash(handle)
                        }
                    }
                    return try fullHash(file.url)
                }
                for (hash, identical) in full where identical.count > 1 {
                    let files = identical.compactMap { scanned -> DuplicateFile? in
                        if options.exclusions.requiresBoundRead {
                            guard let identity = scanned.readIdentity,
                                  let storage = options.exclusions.storage(of: scanned.url, expected: identity) else { return nil }
                            return DuplicateFile(url: scanned.url, logicalSize: identity.size,
                                                 allocated: storage.allocated, privateSize: storage.privateSize ?? 0,
                                                 modified: identity.modified, created: identity.created,
                                                 privateSizeKnown: storage.privateSize != nil, readIdentity: identity)
                        }
                        return DuplicateFile(url: scanned.url, logicalSize: scanned.logicalSize,
                                             allocated: scanned.allocated > 0 ? scanned.allocated : allocatedSize(scanned.url),
                                             privateSize: Scanner.privateSize(of: scanned.url) ?? scanned.allocated,
                                             modified: scanned.modified, created: scanned.created ?? birthDate(scanned.url))
                    }.sorted { $0.url.path < $1.url.path }
                    guard files.count > 1 else { continue }
                    let selection = SmartSelection(options: options)
                    let choice = selection.choose(files)
                    let automatic = choice.keep.map { (keep: $0, remove: choice.remove) } ?? selection.tieBreak(files)
                    groups.append(DuplicateGroup(id: hash, files: files, keep: choice.keep, proposed: choice.remove,
                                                 automatic: automatic.flatMap { $0.remove.isEmpty ? nil : $0 }))
                }
            }
        }
        guard !progress.isCancelled, options.exclusions.canSearch(options.roots) else { return [] }
        return groups.sorted { $0.potential > $1.potential }
    }

    // MARK: Étapes

    struct Scanned: Sendable, Hashable {
        let url: URL
        let logicalSize: Int64
        let allocated: Int64
        let fileID: String?
        let contentKey: DuplicateContentKey?
        let modified: Date?
        let created: Date?
        let readIdentity: DuplicateReadIdentity?
    }

    static func collect(_ options: DuplicateOptions, progress: DuplicateProgress) -> [Scanned] {
        if !options.exclusions.analysisRoots.isEmpty {
            var files: [Scanned] = []
            options.exclusions.walkBound(cancelled: { progress.isCancelled }, descend: {
                !skippedFolders.contains($0.lastPathComponent) && !skippedExtensions.contains($0.pathExtension.lowercased())
            }) { url, info in
                guard info.st_size >= options.minimumSize,
                      let identity = DuplicateExclusions.regularIdentity(info) else { return }
                progress.didExamine()
                files.append(Scanned(url: url, logicalSize: identity.size, allocated: Int64(info.st_blocks) * 512,
                                     fileID: identity.fileID,
                                     contentKey: options.exclusions.cloneKey(of: url, identity: identity),
                                     modified: identity.modified, created: identity.created, readIdentity: identity))
            }
            return files
        }
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileResourceIdentifierKey,
            .fileContentIdentifierKey, .mayShareFileContentKey, .contentModificationDateKey, .creationDateKey,
            .isDirectoryKey,
        ]
        var result: [Scanned] = []
        for root in options.roots where options.exclusions.permitsDirectory(root) {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                guard !progress.isCancelled else { return [] }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if !options.exclusions.permitsDirectory(url) || skippedFolders.contains(url.lastPathComponent) || skippedExtensions.contains(url.pathExtension) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard options.exclusions.permitsFile(url), values.isRegularFile == true, let size = values.fileSize, Int64(size) >= options.minimumSize else {
                    continue
                }
                let identity = options.exclusions.requiresBoundRead ? options.exclusions.readIdentity(url) : nil
                guard !options.exclusions.requiresBoundRead || identity?.size == Int64(size) else { continue }
                progress.didExamine()
                result.append(Scanned(
                    url: url,
                    logicalSize: Int64(size),
                    allocated: Int64(values.totalFileAllocatedSize ?? size),
                    fileID: identity?.fileID ?? values.fileResourceIdentifier.map { "\($0)" },
                    contentKey: contentKey(url, identity: identity, exclusions: options.exclusions,
                                           fallbackID: values.mayShareFileContent == true ? values.fileContentIdentifier : nil),
                    modified: values.contentModificationDate,
                    created: values.creationDate,
                    readIdentity: identity
                ))
            }
        }
        return result
    }

    /// Les candidats d'après l'arborescence, avec les mêmes exclusions que le
    /// parcours du disque. `nil` si un des dossiers n'y figure pas.
    ///
    /// Les fichiers iCloud non téléchargés n'occupent rien et ne sont donc pas
    /// des feuilles : ils échappent aux doublons, ce qui vaut mieux que de les
    /// télécharger pour les comparer.
    static func collect(_ options: DuplicateOptions, from tree: TreeNode, progress: DuplicateProgress) -> [Scanned]? {
        var result: [Scanned] = []
        var packages: [String: Bool] = [:]
        func isPackage(_ name: String) -> Bool {
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty else { return false }
            if let known = packages[ext] { return known }
            let package = UTType(filenameExtension: ext)?.conforms(to: .package) ?? false
            packages[ext] = package
            return package
        }
        for root in options.roots where options.exclusions.permitsDirectory(root) {
            guard let node = tree.descendant(atPath: root.standardizedFileURL.path), node.status == .ok else { return nil }
            var stack: [(TreeNode, URL)] = [(node, root.standardizedFileURL)]
            while let (directory, url) = stack.popLast() {
                guard !progress.isCancelled else { return [] }
                for leaf in directory.files where leaf.logicalSize >= options.minimumSize && !leaf.name.hasPrefix(".") {
                    guard !progress.isCancelled else { return [] }
                    let file = url.appendingPathComponent(leaf.name, isDirectory: false)
                    let identity = options.exclusions.requiresBoundRead ? options.exclusions.readIdentity(file) : nil
                    guard !options.exclusions.requiresBoundRead
                        || (identity?.size == leaf.logicalSize && identity?.inode == leaf.fileID) else { continue }
                    progress.didExamine()
                    result.append(Scanned(
                        url: file,
                        logicalSize: leaf.logicalSize,
                        allocated: leaf.sizes.allocated,
                        fileID: identity?.fileID ?? String(leaf.fileID),
                        // Même identifiant de flux de données : clones l'un de l'autre.
                        contentKey: contentKey(file, identity: identity, exclusions: options.exclusions,
                                               fallbackID: leaf.cloneID != 0 ? Int64(bitPattern: leaf.cloneID) : nil),
                        modified: leaf.modified,
                        created: nil,
                        readIdentity: identity
                    ))
                }
                for child in directory.children where child.status == .ok {
                    let name = child.name
                    if name.hasPrefix(".") || skippedFolders.contains(name) { continue }
                    if skippedExtensions.contains((name as NSString).pathExtension) || isPackage(name) { continue }
                    let folder = url.appendingPathComponent(name, isDirectory: true)
                    if options.exclusions.permitsDirectory(folder) { stack.append((child, folder)) }
                }
            }
        }
        return result
    }

    /// L'arborescence compte zéro un clone ou un lien déjà compté ailleurs ; pour
    /// un fichier d'un groupe, on veut ce qu'il occupe lui-même.
    static func allocatedSize(_ url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }

    /// La date de création, lue seulement pour les fichiers d'un groupe : elle
    /// départage l'original de ses copies.
    static func birthDate(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec)
                    + Double(info.st_birthtimespec.tv_nsec) / 1e9)
    }

    static func contentKey(_ url: URL, identity: DuplicateReadIdentity?, exclusions: DuplicateExclusions,
                           fallbackID: Int64?) -> DuplicateContentKey? {
        if let identity { return exclusions.cloneKey(of: url, identity: identity) }
        return fallbackID.map { DuplicateContentKey(device: nil, identifier: $0) }
    }

    /// Un seul représentant par inode, et par contenu APFS partagé.
    static func collapseShared(_ files: [Scanned]) -> [Scanned] {
        var seenInodes = Set<String>()
        var seenContent = Set<DuplicateContentKey>()
        return files.filter { file in
            if let id = file.fileID, !seenInodes.insert(id).inserted { return false }
            if let content = file.contentKey, !seenContent.insert(content).inserted { return false }
            return true
        }
    }

    static func hashGroups(_ files: [Scanned], progress: DuplicateProgress,
                           hash: @escaping @Sendable (Scanned) throws -> String?) async -> [String: [Scanned]] {
        await withTaskGroup(of: (String, Scanned)?.self) { group in
            var result: [String: [Scanned]] = [:]
            var running = 0
            for file in files {
                guard !progress.isCancelled else { break }
                if running >= 4, let next = await group.next() {
                    running -= 1
                    if let (key, value) = next { result[key, default: []].append(value) }
                }
                group.addTask {
                    defer { progress.didHash() }
                    guard let key = try? hash(file) else { return nil }
                    return (key, file)
                }
                running += 1
            }
            for await next in group { if let (key, value) = next { result[key, default: []].append(value) } }
            return result
        }
    }

    /// 16 Ko de tête et 16 Ko de queue : écarte l'immense majorité des faux
    /// candidats sans lire les fichiers entiers.
    static func partialHash(_ url: URL, size: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try partialHash(handle, size: size)
    }

    private static func partialHash(_ handle: FileHandle, size: Int64) throws -> String {
        var hasher = SHA256()
        let chunk = 16 * 1024
        hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
        if size > Int64(chunk * 2) {
            try handle.seek(toOffset: UInt64(size) - UInt64(chunk))
            hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Le contenu entier, par blocs de 1 Mo.
    static func fullHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try fullHash(handle)
    }

    private static func fullHash(_ handle: FileHandle) throws -> String {
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Quelle copie garder (SPEC §7), dans l'esprit de Duplicate File Finder.
///
/// Les règles s'appliquent dans l'ordre ; la première qui départage gagne.
/// **Égalité = aucune sélection** : mieux vaut laisser choisir que deviner.
public struct SmartSelection: Sendable {
    let options: DuplicateOptions

    public init(options: DuplicateOptions) {
        self.options = options
    }

    public func choose(_ files: [DuplicateFile]) -> (keep: Int?, remove: Set<Int>) {
        guard files.count > 1 else { return (nil, []) }
        let indices = Array(files.indices)

        // 1. Les dossiers de référence ne sont jamais proposés.
        let protected = Set(indices.filter { isInside(files[$0].url, options.referenceFolders) })

        // 2. Téléchargements et Bureau d'abord, s'il existe une copie ailleurs.
        let preferred = Set(indices.filter { isInside(files[$0].url, options.preferredForRemoval) })
        if !preferred.isEmpty && preferred.count < files.count {
            let keep = indices.filter { !preferred.contains($0) }
            return finish(keep: keep, remove: preferred.subtracting(protected), files: files)
        }

        // 3. Les noms de copie (« copie », « copy », « (2) »…).
        let copies = Set(indices.filter { Self.looksLikeCopy(files[$0].url) })
        if !copies.isEmpty && copies.count < files.count {
            let keep = indices.filter { !copies.contains($0) }
            return finish(keep: keep, remove: copies.subtracting(protected), files: files)
        }

        // 4. Le plus ancien est l'original, s'il est seul à l'être.
        let dated = indices.compactMap { index in files[index].created.map { (index, $0) } }
        if dated.count == files.count, let oldest = dated.min(by: { $0.1 < $1.1 }),
           dated.filter({ abs($0.1.timeIntervalSince(oldest.1)) < 1 }).count == 1 {
            return finish(keep: [oldest.0], remove: Set(indices).subtracting([oldest.0]).subtracting(protected), files: files)
        }

        // Égalité : rien n'est proposé.
        return (nil, [])
    }

    /// À égalité, pour la sélection automatique que l'utilisateur a demandée
    /// (18/10/2026) : on garde le plus ancien, puis le chemin le plus court,
    /// l'emplacement d'origine le plus probable. Un dossier de référence garde
    /// la priorité et n'est jamais proposé. Nil s'il ne reste rien à retirer.
    public func tieBreak(_ files: [DuplicateFile]) -> (keep: Int, remove: Set<Int>)? {
        guard files.count > 1 else { return nil }
        let indices = Array(files.indices)
        let protected = Set(indices.filter { isInside(files[$0].url, options.referenceFolders) })
        let candidates = protected.isEmpty ? indices : protected.sorted()
        guard let keep = candidates.min(by: { Self.isMoreOriginal(files[$0], than: files[$1]) }) else { return nil }
        let remove = Set(indices).subtracting(protected).subtracting([keep])
        return remove.isEmpty ? nil : (keep, remove)
    }

    static func isMoreOriginal(_ a: DuplicateFile, than b: DuplicateFile) -> Bool {
        if let createdA = a.created, let createdB = b.created, abs(createdA.timeIntervalSince(createdB)) >= 1 {
            return createdA < createdB
        }
        let (pathA, pathB) = (a.url.path, b.url.path)
        return pathA.count != pathB.count ? pathA.count < pathB.count : pathA < pathB
    }

    private func finish(keep candidates: [Int], remove: Set<Int>, files: [DuplicateFile]) -> (keep: Int?, remove: Set<Int>) {
        // Parmi les copies gardées, la plus ancienne fait référence.
        let keep = candidates.min { (files[$0].created ?? .distantFuture) < (files[$1].created ?? .distantFuture) }
        guard let keep else { return (nil, []) }
        // Jamais toutes les copies.
        let remove = remove.subtracting([keep])
        return remove.count < files.count ? (keep, remove) : (nil, [])
    }

    private func isInside(_ url: URL, _ folders: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return folders.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// « Rapport copie.pdf », « Copy of photo.jpg », « image (2).png », « film 2.mkv ».
    public static func looksLikeCopy(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let suffixes = [" copy", " copie", " kopie", " copia", " копия", " kopya"]
        if suffixes.contains(where: { name.hasSuffix($0) || name.range(of: $0 + " ") != nil && name.last?.isNumber == true }) {
            return true
        }
        if ["copy of ", "copie de ", "kopie van ", "copia de "].contains(where: name.hasPrefix) { return true }
        if name.range(of: #" \(\d{1,3}\)$"#, options: .regularExpression) != nil { return true }
        if name.range(of: #" \d$"#, options: .regularExpression) != nil { return true }
        return false
    }
}

extension DuplicateGroup {
    /// Les copies proposées, prêtes pour le panier.
    ///
    /// `asClones` : au lieu de les jeter, les remplacer par des clones de l'original.
    public func cleanupItems(asClones: Bool = false) -> [CleanupItem] {
        guard let keep else { return [] }
        let original = files[keep]
        return proposed.sorted().map { index in
            let file = files[index]
            return CleanupItem(
                id: "duplicate|\(file.url.path)",
                title: file.url.lastPathComponent,
                detail: file.url.deletingLastPathComponent().path,
                paths: [file.url],
                category: .duplicates,
                owner: original.url.lastPathComponent,
                ruleID: "duplicate.copy",
                safety: .review,
                method: asClones ? .cloneOf(original: original.url.path) : .trash,
                sizes: Sizes(allocated: file.allocated, freeable: file.privateSize),
                lastActivity: file.modified,
                rebuild: .irreversible,
                fingerprint: Fingerprint(modificationDate: file.modified, fileID: nil)
            )
        }
    }
}
