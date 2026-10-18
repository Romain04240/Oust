import Foundation
import OustCore

/// Un worktree tel que `git worktree list --porcelain` le décrit.
public struct WorktreeInfo: Sendable, Hashable {
    public let path: String
    public let head: String?
    public let branch: String?
    public let isMain: Bool
    public let isLocked: Bool
}

/// Ce qu'on perdrait en retirant un worktree.
public struct WorktreeState: Sendable, Hashable {
    /// Fichiers modifiés ou non suivis : `git worktree remove` refuserait, et on protège.
    public var uncommitted: Int
    /// Fichiers ignorés sensibles qui n'existent pas, identiques, dans le dépôt principal.
    public var uniqueSensitiveFiles: [String]
    public var isLocked: Bool
    /// La branche est contenue dans le HEAD du dépôt principal.
    public var isMerged: Bool?
    public var branch: String?
}

/// Les questions qu'Oust! pose à git, et rien d'autre.
public enum GitInspector {
    static let git = "/usr/bin/git"

    /// Le dépôt principal d'un worktree, lu dans son fichier `.git`
    /// (`gitdir: <dépôt>/.git/worktrees/<id>`). `nil` si ce n'est pas un worktree.
    public static func mainRepository(ofWorktree url: URL) -> URL? {
        let dotGit = url.appendingPathComponent(".git")
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
            return nil
        }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return URL(fileURLWithPath: String(gitdir[..<range.lowerBound]))
    }

    /// Le dossier d'administration du worktree dans le dépôt principal.
    public static func adminDirectory(ofWorktree url: URL) -> URL? {
        let dotGit = url.appendingPathComponent(".git")
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
            return nil
        }
        return URL(fileURLWithPath: line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces))
    }

    public static func worktrees(of repository: URL) async -> [WorktreeInfo] {
        let result = await Command.run(git, ["-C", repository.path, "worktree", "list", "--porcelain"], timeout: 20)
        guard result.succeeded else { return [] }
        return parseWorktreeList(result.output)
    }

    static func parseWorktreeList(_ output: String) -> [WorktreeInfo] {
        var infos: [WorktreeInfo] = []
        var path: String?
        var head: String?
        var branch: String?
        var locked = false
        func flush() {
            if let path {
                infos.append(WorktreeInfo(path: path, head: head, branch: branch, isMain: infos.isEmpty, isLocked: locked))
            }
            path = nil; head = nil; branch = nil; locked = false
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            else if line.hasPrefix("HEAD ") { head = String(line.dropFirst("HEAD ".count)) }
            else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "")
            }
            else if line.hasPrefix("locked") { locked = true }
        }
        flush()
        return infos
    }

    /// L'état d'un worktree, ou `nil` si git n'a pas pu répondre : dans ce cas
    /// l'appelant protège (RULES.md, règle 3).
    public static func state(ofWorktree url: URL) async -> WorktreeState? {
        guard let main = mainRepository(ofWorktree: url) else { return nil }
        // `--no-optional-locks` : sans lui, `git status` réécrit l'index pour y
        // rafraîchir ses dates. Oust! inspecte, il ne modifie pas un dépôt qu'il
        // n'a pas été chargé de nettoyer — fût-ce un octet de cache.
        let status = await Command.run(git, ["--no-optional-locks", "-C", url.path, "status", "--porcelain=v1",
                                             "--ignored=matching", "--untracked-files=all"], timeout: 60)
        guard status.succeeded else { return nil }

        var uncommitted = 0
        var ignored: [String] = []
        for line in status.output.split(separator: "\n") where line.count > 3 {
            let code = line.prefix(2)
            let file = String(line.dropFirst(3))
            if code == "!!" { ignored.append(file) } else { uncommitted += 1 }
        }

        let sensitive = ignored.filter(isSensitive)
        let unique = sensitive.filter { !existsIdentically($0, in: url, and: main) }

        let headResult = await Command.run(git, ["-C", url.path, "rev-parse", "HEAD"], timeout: 10)
        let branchResult = await Command.run(git, ["-C", url.path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 10)
        var merged: Bool?
        if headResult.succeeded {
            let head = headResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let ancestor = await Command.run(git, ["-C", main.path, "merge-base", "--is-ancestor", head, "HEAD"], timeout: 20)
            merged = ancestor.timedOut ? nil : (ancestor.status == 0)
        }

        let locked = adminDirectory(ofWorktree: url).map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("locked").path)
                || FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.lock").path)
        } ?? false

        return WorktreeState(
            uncommitted: uncommitted,
            uniqueSensitiveFiles: unique,
            isLocked: locked,
            isMerged: merged,
            branch: branchResult.succeeded ? branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
    }

    /// Un fichier ignoré qu'on regretterait : secrets, clés, bases locales.
    ///
    /// `git worktree remove` les efface sans rien dire, parce qu'ils sont
    /// ignorés. C'est exactement le genre de perte qu'Oust! doit empêcher
    /// (idée reprise de CleanMyAgent).
    public static func isSensitive(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if path.hasSuffix("/") { return false }
        let examples = [".example", ".sample", ".template", ".dist"]
        if name.hasPrefix(".env") { return !examples.contains { name.hasSuffix($0) } }
        let extensions = ["pem", "key", "p12", "pfx", "keystore", "jks", "sqlite", "sqlite3", "db", "mobileprovision"]
        if extensions.contains((name as NSString).pathExtension) { return true }
        let fragments = ["id_rsa", "id_ed25519", "keypair", "credentials", "secret", "service-account", "token"]
        return fragments.contains { name.contains($0) }
    }

    /// Le même fichier existe-t-il, identique, dans le dépôt principal ?
    static func existsIdentically(_ relative: String, in worktree: URL, and main: URL) -> Bool {
        let mine = worktree.appendingPathComponent(relative)
        let theirs = main.appendingPathComponent(relative)
        guard let a = try? Data(contentsOf: mine, options: .mappedIfSafe),
              let b = try? Data(contentsOf: theirs, options: .mappedIfSafe) else { return false }
        return a == b
    }

    /// Ce dossier contient-il des fichiers suivis par git ?
    ///
    /// Pour les noms ambigus (`build`, `dist`, `vendor`) : un `dist` versionné est
    /// du contenu, pas un artefact.
    public static func containsTrackedFiles(_ url: URL, repository: URL) async -> Bool? {
        let result = await Command.run(git, ["-C", repository.path, "ls-files", "--", url.path], timeout: 20)
        guard result.succeeded else { return nil }
        return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// La racine du dépôt git qui contient ce dossier, s'il y en a une.
    public static func repositoryRoot(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        let fileManager = FileManager.default
        while current.path != "/" {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }
}
