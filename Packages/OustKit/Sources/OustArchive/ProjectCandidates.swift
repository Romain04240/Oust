import Darwin
import Foundation
import OustCore
import OustSafety
import OustScan

/// Un projet qu'on pourrait archiver sur un disque externe.
public struct ProjectCandidate: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public var name: String { url.lastPathComponent }
    /// La modification la plus récente de tout ce que le projet contient.
    public let lastModified: Date?
    public let sizes: Sizes
    public let fileCount: Int
    public let fileID: UInt64
    /// Pourquoi on ne peut pas l'archiver, s'il y a une raison.
    public var blocker: ArchiveBlocker?

    public init(url: URL, lastModified: Date?, sizes: Sizes, fileCount: Int, fileID: UInt64 = 0,
                blocker: ArchiveBlocker? = nil) {
        self.url = url
        self.lastModified = lastModified
        self.sizes = sizes
        self.fileCount = fileCount
        self.fileID = fileID
        self.blocker = blocker
    }

    public var isArchivable: Bool { blocker == nil }
}

/// Ce qui empêche d'archiver un projet. Dans le doute, on n'archive pas
/// (RULES.md, règle 3) : une archive incomplète qui a pris la place de
/// l'original, c'est une perte.
public enum ArchiveBlocker: Sendable, Hashable {
    /// Un processus y travaille (agent, éditeur, compilation).
    case activeProcess(name: String)
    /// Le projet est le worktree d'un autre dépôt : le déplacer casserait ce dépôt.
    case isWorktree
    /// Le dépôt a des worktrees hors de son dossier, qui pointent vers lui.
    case externalWorktrees(count: Int)
    /// Une partie n'a pas pu être lue.
    case inaccessible
    /// Du contenu iCloud non téléchargé : impossible à copier sans le télécharger.
    case cloudOnly
    /// Un autre volume est monté à l'intérieur.
    case containsMountPoint
    /// La garde de chemins refuse cet emplacement.
    case systemPath
    /// L'état git n'a pas pu être établi.
    case unknownState

    public var localizationKey: String {
        switch self {
        case .activeProcess: "archive.blocker.activeProcess"
        case .isWorktree: "archive.blocker.isWorktree"
        case .externalWorktrees: "archive.blocker.externalWorktrees"
        case .inaccessible: "archive.blocker.inaccessible"
        case .cloudOnly: "archive.blocker.cloudOnly"
        case .containsMountPoint: "archive.blocker.containsMountPoint"
        case .systemPath: "archive.blocker.systemPath"
        case .unknownState: "archive.blocker.unknownState"
        }
    }

    public var argument: String? {
        switch self {
        case .activeProcess(let name): name
        case .externalWorktrees(let count): String(count)
        default: nil
        }
    }
}

/// Les projets restés sans modification depuis longtemps.
public enum ProjectCandidates {

    /// Les dossiers de premier niveau des racines de projets, mesurés, avec la
    /// date de leur dernière modification (la plus récente de tout leur contenu).
    ///
    /// `inactiveSince` : seuls les projets plus anciens sont rendus. Les autres
    /// ne sont même pas des candidats, l'interface n'a rien à en dire.
    public static func find(
        in roots: [URL],
        inactiveSince cutoff: Date,
        home: URL,
        processes: ProcessSnapshot = .current()
    ) async -> [ProjectCandidate] {
        let fileManager = FileManager.default
        var folders: [URL] = []
        var seen = Set<String>()
        for root in roots {
            let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                               options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if seen.insert(PathNormalizer.normalize(entry.resolvingSymlinksInPath().path)).inserted { folders.append(entry) }
            }
        }
        guard !folders.isEmpty else { return [] }

        let result = await Scanner.scan(folders, options: .measuring)
        let pathGuard = PathGuard(home: home)
        var candidates: [ProjectCandidate] = []
        for (url, node) in zip(folders, result.roots) {
            guard let modified = node.latestModification, modified < cutoff else { continue }
            var info = stat()
            lstat(url.path, &info)
            var candidate = ProjectCandidate(url: url, lastModified: modified, sizes: node.total,
                                             fileCount: node.fileCount, fileID: UInt64(info.st_ino))
            candidate.blocker = await blocker(for: url, node: node, guard: pathGuard, processes: processes)
            candidates.append(candidate)
        }
        return candidates.sorted { $0.sizes.allocated > $1.sizes.allocated }
    }

    /// La première raison de ne pas archiver, ou `nil`.
    static func blocker(for url: URL, node: TreeNode, guard pathGuard: PathGuard,
                        processes: ProcessSnapshot) async -> ArchiveBlocker? {
        guard pathGuard.allows(url) else { return .systemPath }
        if let process = processes.busy(under: url.path) ?? processes.running(inside: url.path) {
            return .activeProcess(name: process.name)
        }
        if let status = worstStatus(in: node) { return status }

        let dotGit = url.appendingPathComponent(".git")
        var info = stat()
        if lstat(dotGit.path, &info) == 0 {
            if info.st_mode & S_IFMT != S_IFDIR { return .isWorktree }
            let worktrees = await GitInspector.worktrees(of: url)
            // `git worktree list` qui ne répond pas sur un dépôt qui existe : on
            // ne sait pas qui pointe vers lui, on n'archive pas.
            guard !worktrees.isEmpty else { return .unknownState }
            let outside = worktrees.filter { !$0.isMain && !PathNormalizer.isWithin($0.path, url.path) }
            if !outside.isEmpty { return .externalWorktrees(count: outside.count) }
        }
        return nil
    }

    /// Un dossier illisible, iCloud ou un montage quelque part dans l'arborescence.
    static func worstStatus(in root: TreeNode) -> ArchiveBlocker? {
        var stack = [root]
        while let node = stack.popLast() {
            switch node.status {
            case .inaccessible: return .inaccessible
            case .dataless: return .cloudOnly
            case .otherVolume, .firmlink: return .containsMountPoint
            case .ok, .excluded: break
            }
            stack.append(contentsOf: node.children)
        }
        return nil
    }
}
