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
        let folders = await Task.detached(priority: .userInitiated) { discover(in: roots) }.value
        guard !folders.isEmpty else { return [] }

        let result = await Scanner.scan(folders, options: .measuring)
        let pathGuard = PathGuard(home: home)
        var candidates: [ProjectCandidate] = []
        for (url, node) in zip(folders, result.roots) {
            let modified = await Task.detached(priority: .utility) { sourceActivity(at: url) }.value
            guard modified == nil || modified! < cutoff else { continue }
            var info = stat()
            lstat(url.path, &info)
            var candidate = ProjectCandidate(url: url, lastModified: modified, sizes: node.total,
                                             fileCount: node.fileCount, fileID: UInt64(info.st_ino))
            candidate.blocker = await blocker(for: url, node: node, guard: pathGuard, processes: processes)
            if modified == nil, candidate.blocker == nil { candidate.blocker = .unknownState }
            candidates.append(candidate)
        }
        return candidates.sorted { $0.sizes.allocated > $1.sizes.allocated }
    }

    /// Les collections imbriquées et une racine qui est elle-même un projet
    /// sont reconnues. Aucun lien, paquet, nuage ou autre volume n'est traversé.
    static let generated: Set<String> = [".git", ".build", "node_modules", ".next", ".nuxt", ".venv", "venv",
        "DerivedData", "Pods", "__pycache__", ".gradle", ".swiftpm", "target", ".DS_Store"]
    static let markers: Set<String> = [".git", "Package.swift", "package.json", "pyproject.toml", "Cargo.toml",
        "pom.xml", "build.gradle", "build.gradle.kts", "composer.json", "pubspec.yaml", "project.yml",
        "CMakeLists.txt", "go.mod", "project.godot"]

    static func discover(in roots: [URL]) -> [URL] {
        let manager = FileManager.default
        var found: [URL] = []
        var seen = Set<String>()
        func visit(_ url: URL, device: dev_t, depth: Int) -> Bool {
            guard depth <= 5, !Task.isCancelled else { return false }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_dev == device, info.st_flags & UInt32(SF_DATALESS) == 0,
                  (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true else { return false }
            guard let entries = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
            let names = Set(entries.map(\.lastPathComponent))
            if !names.isDisjoint(with: markers) || names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".sln") }) {
                if seen.insert(url.path).inserted { found.append(url) }
                return true
            }
            var nested = false
            for entry in entries where !entry.lastPathComponent.hasPrefix(".")
                && !generated.contains(entry.lastPathComponent) {
                if visit(entry, device: device, depth: depth + 1) { nested = true }
            }
            if !nested, depth == 1, seen.insert(url.path).inserted {
                found.append(url)
                return true
            }
            return nested
        }
        for root in roots.map({ $0.standardizedFileURL }).sorted(by: { $0.path.count < $1.path.count }) {
            guard !found.contains(where: { PathNormalizer.isWithin(root.path, $0.path) }) else { continue }
            var info = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            _ = visit(root, device: info.st_dev, depth: 0)
        }
        return found
    }

    /// L'activité des sources, pas celle des téléchargements de dépendances ni
    /// des accès de git en arrière-plan. Ce n'est qu'un conseil : l'archivage
    /// revalide et copie encore l'intégralité, artefacts et fichiers cachés compris.
    static func sourceActivity(at url: URL) -> Date? {
        var root = stat()
        guard lstat(url.path, &root) == 0 else { return nil }
        var latest: Date?
        var stack = [url]
        while let directory = stack.popLast() {
            guard !Task.isCancelled,
                  let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
            for entry in entries where !generated.contains(entry.lastPathComponent) {
                var info = stat()
                guard lstat(entry.path, &info) == 0, info.st_dev == root.st_dev,
                      info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
                if info.st_mode & S_IFMT == S_IFLNK { continue }
                if info.st_mode & S_IFMT == S_IFDIR { stack.append(entry); continue }
                let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
                latest = max(latest ?? .distantPast, date)
            }
        }
        return latest ?? Date(timeIntervalSince1970: Double(root.st_mtimespec.tv_sec))
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
