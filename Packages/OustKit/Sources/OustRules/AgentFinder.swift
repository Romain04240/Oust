import Foundation
import OustCore
import OustSafety

/// Ce que laissent les agents de code : worktrees, historiques, dossiers de
/// travail (SPEC §4, « Agents IA »).
///
/// Le 18/10/2026 : 44 worktrees dans un seul projet (12 Go), 14 Go
/// d'historiques Claude, 56 Go dans `~/.codex`. Rien de tout cela n'est un
/// cache au sens strict ; tout se juge élément par élément.
struct AgentFinder {
    let context: RuleContext

    func find() async -> [Candidate] {
        var candidates: [Candidate] = []
        candidates += await worktrees()
        candidates += claudeHistories()
        candidates += codexSessions()
        candidates += codexWorkspaces()
        candidates += agentCaches()
        return candidates
    }

    // MARK: Worktrees

    /// Les dossiers de worktrees connus : `.claude/worktrees` dans chaque projet,
    /// et ceux que Codex et Cursor gardent chez eux.
    func worktreeFolders() -> [URL] {
        let fileManager = FileManager.default
        var folders: [URL] = []
        for root in context.projectRoots {
            for project in fileManager.children(of: root) where fileManager.isDirectory(project) {
                let claude = project.appendingPathComponent(".claude/worktrees")
                folders += fileManager.children(of: claude).filter { fileManager.isDirectory($0) }
            }
        }
        for shared in [".codex/worktrees", ".cursor/worktrees"] {
            let base = context.path(shared)
            for entry in fileManager.children(of: base) where fileManager.isDirectory(entry) {
                // Codex range parfois ses worktrees un niveau plus bas.
                if fileManager.fileExists(atPath: entry.appendingPathComponent(".git").path) {
                    folders.append(entry)
                } else {
                    folders += fileManager.children(of: entry).filter {
                        fileManager.fileExists(atPath: $0.appendingPathComponent(".git").path)
                    }
                }
            }
        }
        return folders.filter { GitInspector.mainRepository(ofWorktree: $0) != nil }
    }

    func worktrees() async -> [Candidate] {
        let folders = worktreeFolders()
        let allowed = await PathGuard(home: context.home).allowedWorktreesForAnalysis(Set(folders))
        return await withTaskGroup(of: Candidate?.self) { group in
            var results: [Candidate] = []
            var running = 0
            for folder in folders {
                // Huit `git status` à la fois : au-delà, on ralentit le disque pour rien.
                if running >= 8, let result = await group.next() {
                    running -= 1
                    if let result { results.append(result) }
                }
                group.addTask { await worktreeCandidate(folder, allowed: allowed.contains(folder)) }
                running += 1
            }
            for await result in group { if let result { results.append(result) } }
            return results
        }
    }

    func worktreeCandidate(_ folder: URL, allowed: Bool) async -> Candidate? {
        guard let main = GitInspector.mainRepository(ofWorktree: folder) else { return nil }
        let state = await GitInspector.state(ofWorktree: folder)
        let modified = folder.modificationDate
        let recent = modified.map { context.now.timeIntervalSince($0) < 86_400 } ?? false

        var notes: [ItemNote] = []
        if state?.isMerged == false {
            notes.append(.notMerged)
        }
        if recent {
            notes.append(.recentlyModified(days: 1))
        }

        var item = CleanupItem(
            id: "worktree|\(folder.path)",
            title: folder.lastPathComponent,
            detail: state?.branch,
            paths: [folder],
            category: .aiAgents,
            owner: main.lastPathComponent,
            ruleID: folder.path.contains("/.codex/") ? "agent.codex_worktree" : "agent.worktree",
            safety: .protected,
            notes: notes,
            method: .gitWorktreeRemove(repository: main.path),
            lastActivity: modified,
            rebuild: .command("git worktree add", minutes: 1),
            activityScope: folder
        )
        guard allowed else {
            item.protect(.systemPath)
            return Candidate(item: item, needsMeasure: false)
        }
        guard let state else {
            item.protect(.unknownState)
            return Candidate(item: item)
        }
        if let process = context.processes.busy(under: folder.path) { item.protect(.activeProcess(name: process.name)) }
        if state.uncommitted > 0 { item.protect(.uncommittedChanges(count: state.uncommitted)) }
        if state.isLocked { item.protect(.gitLocked) }
        if !state.uniqueSensitiveFiles.isEmpty { item.protect(.uniqueIgnoredFiles(state.uniqueSensitiveFiles)) }
        return Candidate(item: item)
    }

    // MARK: Historiques Claude Code

    /// Un historique par projet : les sessions plus vieilles que la rétention,
    /// ou toutes si le projet n'existe plus. Les sessions des dernières 24 heures
    /// ne sont jamais proposées : une conversation est peut-être en cours.
    func claudeHistories() -> [Candidate] {
        let fileManager = FileManager.default
        let base = context.path(".claude/projects")
        var candidates: [Candidate] = []
        let retention = Double(context.historyRetentionDays) * 86_400

        for project in fileManager.children(of: base) where fileManager.isDirectory(project) {
            let files = fileManager.children(of: project)
            let sessions = files.filter { $0.pathExtension == "jsonl" }
            guard !sessions.isEmpty else { continue }
            let workingDirectory = sessions.lazy.compactMap(Self.workingDirectory(ofSession:)).first
            let orphan = workingDirectory.map { !fileManager.fileExists(atPath: $0) } ?? false

            var selected: [URL] = []
            var latest: Date?
            for session in sessions {
                guard let modified = session.modificationDate else { continue }
                let age = context.now.timeIntervalSince(modified)
                guard age > 86_400 else { continue }
                if orphan || age > retention {
                    selected.append(session)
                    // Les sous-agents et fichiers associés vivent dans un dossier du même nom.
                    let companion = project.appendingPathComponent(session.deletingPathExtension().lastPathComponent)
                    if fileManager.isDirectory(companion) { selected.append(companion) }
                    if modified > (latest ?? .distantPast) { latest = modified }
                }
            }
            guard !selected.isEmpty else { continue }
            let name = workingDirectory.map { ($0 as NSString).lastPathComponent } ?? project.lastPathComponent
            candidates.append(Candidate(item: CleanupItem(
                id: "claude-history|\(project.path)",
                title: name,
                detail: "\(selected.filter { $0.pathExtension == "jsonl" }.count) sessions",
                paths: selected,
                category: .aiAgents,
                owner: "Claude Code",
                ruleID: orphan ? "agent.claude_history_orphan" : "agent.claude_history",
                safety: .review,
                notes: orphan ? [.orphan] : [],
                method: .trash,
                lastActivity: latest,
                rebuild: .irreversible
            )))
        }
        return candidates
    }

    /// Le dossier de travail d'une session, lu dans ses premières lignes.
    static func workingDirectory(ofSession url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(40) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let cwd = object["cwd"] as? String else { continue }
            return cwd
        }
        return nil
    }

    // MARK: Codex

    /// Les sessions Codex, regroupées par mois, au-delà de la rétention.
    func codexSessions() -> [Candidate] {
        let fileManager = FileManager.default
        let base = context.path(".codex/sessions")
        let retention = Double(context.historyRetentionDays) * 86_400
        var candidates: [Candidate] = []
        for year in fileManager.children(of: base) where fileManager.isDirectory(year) {
            for month in fileManager.children(of: year) where fileManager.isDirectory(month) {
                var selected: [URL] = []
                var latest: Date?
                for day in fileManager.children(of: month) where fileManager.isDirectory(day) {
                    for session in fileManager.children(of: day) {
                        guard let modified = session.modificationDate,
                              context.now.timeIntervalSince(modified) > retention else { continue }
                        selected.append(session)
                        if modified > (latest ?? .distantPast) { latest = modified }
                    }
                }
                guard !selected.isEmpty else { continue }
                candidates.append(Candidate(item: CleanupItem(
                    id: "codex-sessions|\(month.path)",
                    title: "\(year.lastPathComponent)-\(month.lastPathComponent)",
                    detail: "\(selected.count) sessions",
                    paths: selected,
                    category: .aiAgents,
                    owner: "Codex",
                    ruleID: "agent.codex_sessions",
                    safety: .review,
                    method: .trash,
                    lastActivity: latest,
                    rebuild: .irreversible
                )))
            }
        }
        return candidates
    }

    /// Ce que Codex sait de lui-même : on n'y touche jamais.
    static let codexKnown: Set<String> = [
        "sessions", "archived_sessions", "plugins", "log", "logs", "memories", "prompts", "skills", "packages",
        "worktrees", "rules", "vendor_imports", "tmp", ".tmp", "cache", "shell_snapshots", "auth.json",
        "config.toml", "version.json", "history.jsonl", "AGENTS.md", "generated_images", "agents", "bin",
    ]

    /// Les gros dossiers qu'un agent Codex a créés pour un projet (staging,
    /// builds de publication) : 23 Go le 18/10/2026, modifiés la nuit même.
    func codexWorkspaces() -> [Candidate] {
        let fileManager = FileManager.default
        let base = context.path(".codex")
        var candidates: [Candidate] = []
        for entry in fileManager.children(of: base) where fileManager.isDirectory(entry) {
            let name = entry.lastPathComponent
            guard !name.hasPrefix("."), !Self.codexKnown.contains(name) else { continue }
            var item = CleanupItem(
                id: "codex-workspace|\(entry.path)",
                title: name,
                detail: entry.abbreviated(home: context.home),
                paths: [entry],
                category: .aiAgents,
                owner: "Codex",
                ruleID: "agent.codex_workspace",
                safety: .review,
                method: .trash,
                lastActivity: entry.modificationDate,
                rebuild: .irreversible
            )
            if let modified = entry.modificationDate, context.now.timeIntervalSince(modified) < 86_400 {
                item.protect(.inUse)
            }
            if let process = context.processes.busy(under: entry.path) { item.protect(.activeProcess(name: process.name)) }
            candidates.append(Candidate(item: item))
        }
        let images = base.appendingPathComponent("generated_images")
        if fileManager.isDirectory(images) {
            candidates.append(Candidate(item: CleanupItem(
                title: "generated_images", detail: images.abbreviated(home: context.home), paths: [images],
                category: .aiAgents, owner: "Codex", ruleID: "agent.codex_images", safety: .review,
                method: .trash, lastActivity: images.modificationDate, rebuild: .irreversible
            )))
        }
        return candidates
    }

    /// Caches d'exécution des agents : retéléchargés au besoin.
    func agentCaches() -> [Candidate] {
        let entries: [(String, String)] = [
            (".cache/codex-runtimes", "Codex runtimes"),
            ("Library/Caches/com.openai.codex", "Codex"),
            ("Library/Caches/com.openai.chat", "ChatGPT"),
            ("Library/Caches/claude-cli-nodejs", "Claude Code"),
            ("Library/Application Support/Cursor/Cache", "Cursor"),
            ("Library/Application Support/Cursor/CachedData", "Cursor"),
            ("Library/Application Support/Windsurf/Cache", "Windsurf"),
        ]
        let fileManager = FileManager.default
        return entries.compactMap { path, title in
            let url = context.path(path)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return Candidate(item: CleanupItem(
                title: title, detail: url.abbreviated(home: context.home), paths: [url], category: .aiAgents,
                owner: title, ruleID: "agent.cache", safety: .safe, method: .removeNow, rebuild: .automatic
            ))
        }
    }
}
