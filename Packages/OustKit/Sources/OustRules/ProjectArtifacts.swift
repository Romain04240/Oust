import Foundation
import OustCore
import OustSafety
import OustScan

/// Ce qui se reconstruit dans un projet, reconnu à son fichier marqueur
/// (tables fusionnées de kondo, npkill et Mole ; SPEC §4).
struct ArtifactRule: Sendable {
    let folder: String
    /// Fichiers qui signent le type de projet. `*.ext` : n'importe quel fichier
    /// de cette extension.
    let markers: [String]
    let ruleID: String
    let safety: SafetyClass
    /// Nom qui peut aussi désigner du contenu (`build`, `dist`) : exige en plus
    /// qu'aucun fichier n'y soit suivi par git.
    let ambiguous: Bool
    let rebuild: @Sendable (_ project: URL) -> RebuildCost

    init(_ folder: String, markers: [String], rule ruleID: String, safety: SafetyClass = .rebuilds,
         ambiguous: Bool = false, rebuild: @escaping @Sendable (_ project: URL) -> RebuildCost) {
        self.folder = folder
        self.markers = markers
        self.ruleID = ruleID
        self.safety = safety
        self.ambiguous = ambiguous
        self.rebuild = rebuild
    }
}

enum ArtifactTable {
    static let node = ["package.json"]
    static let python = ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock"]
    static let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

    static func command(_ text: String, _ minutes: Int? = nil) -> @Sendable (URL) -> RebuildCost {
        { _ in .command(text, minutes: minutes) }
    }

    static let automatic: @Sendable (URL) -> RebuildCost = { _ in .automatic }

    /// La commande qui rend `node_modules`, d'après le fichier de verrouillage.
    static let nodeInstall: @Sendable (URL) -> RebuildCost = { project in
        let fileManager = FileManager.default
        let has = { (name: String) in fileManager.fileExists(atPath: project.appendingPathComponent(name).path) }
        if has("pnpm-lock.yaml") { return .command("pnpm install", minutes: 2) }
        if has("yarn.lock") { return .command("yarn install", minutes: 2) }
        if has("bun.lockb") || has("bun.lock") { return .command("bun install", minutes: 1) }
        if has("package-lock.json") { return .command("npm ci", minutes: 2) }
        return .command("npm install", minutes: 3)
    }

    static let rules: [ArtifactRule] = [
        ArtifactRule("node_modules", markers: node, rule: "artifact.node_modules", rebuild: nodeInstall),
        ArtifactRule(".next", markers: node, rule: "artifact.framework_build", rebuild: command("npm run build", 2)),
        ArtifactRule(".nuxt", markers: node, rule: "artifact.framework_build", rebuild: command("npm run build", 2)),
        ArtifactRule(".output", markers: node, rule: "artifact.framework_build", rebuild: command("npm run build", 2)),
        ArtifactRule(".svelte-kit", markers: node, rule: "artifact.framework_build", rebuild: command("npm run build", 1)),
        ArtifactRule(".astro", markers: node, rule: "artifact.framework_build", rebuild: command("npm run build", 1)),
        ArtifactRule(".angular", markers: node, rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".turbo", markers: node, rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".parcel-cache", markers: node, rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".vite", markers: node, rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".nx", markers: node, rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".swc", markers: node, rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".expo", markers: node, rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule("coverage", markers: node + python, rule: "artifact.coverage", safety: .safe, rebuild: command("npm test")),
        ArtifactRule(".nyc_output", markers: node, rule: "artifact.coverage", safety: .safe, rebuild: command("npm test")),
        ArtifactRule("dist", markers: node, rule: "artifact.output", ambiguous: true, rebuild: command("npm run build", 2)),
        ArtifactRule("build", markers: node, rule: "artifact.output", ambiguous: true, rebuild: command("npm run build", 2)),
        ArtifactRule("storybook-static", markers: node, rule: "artifact.output", rebuild: command("npm run build-storybook", 2)),

        ArtifactRule(".build", markers: ["Package.swift"], rule: "artifact.swiftpm", rebuild: command("swift build", 5)),
        ArtifactRule("Pods", markers: ["Podfile"], rule: "artifact.pods", rebuild: command("pod install", 3)),
        ArtifactRule("DerivedData", markers: ["*.xcodeproj", "*.xcworkspace"], rule: "artifact.xcode_local",
                     rebuild: command("xcodebuild", 5)),
        ArtifactRule("build", markers: ["*.xcodeproj", "project.yml"], rule: "artifact.output", ambiguous: true,
                     rebuild: command("xcodebuild", 5)),

        ArtifactRule(".dart_tool", markers: ["pubspec.yaml"], rule: "artifact.flutter", rebuild: command("flutter pub get", 1)),
        ArtifactRule("build", markers: ["pubspec.yaml"], rule: "artifact.output", ambiguous: true, rebuild: command("flutter build", 5)),

        ArtifactRule(".gradle", markers: gradle, rule: "artifact.gradle", rebuild: command("./gradlew build", 5)),
        ArtifactRule("build", markers: gradle, rule: "artifact.output", ambiguous: true, rebuild: command("./gradlew build", 5)),
        ArtifactRule(".cxx", markers: gradle, rule: "artifact.gradle", rebuild: command("./gradlew build", 5)),
        ArtifactRule(".externalNativeBuild", markers: gradle, rule: "artifact.gradle", rebuild: command("./gradlew build", 5)),

        ArtifactRule("target", markers: ["Cargo.toml"], rule: "artifact.rust", rebuild: command("cargo build", 5)),
        ArtifactRule("target", markers: ["pom.xml", "build.sbt"], rule: "artifact.output", ambiguous: true, rebuild: command("mvn package", 5)),

        ArtifactRule(".venv", markers: python, rule: "artifact.python_env", rebuild: command("uv sync / pip install", 2)),
        ArtifactRule("venv", markers: python, rule: "artifact.python_env", rebuild: command("pip install -r requirements.txt", 2)),
        ArtifactRule(".pytest_cache", markers: python, rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".mypy_cache", markers: python, rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".ruff_cache", markers: python, rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".tox", markers: python, rule: "artifact.python_env", rebuild: command("tox", 3)),
        ArtifactRule(".nox", markers: python, rule: "artifact.python_env", rebuild: command("nox", 3)),
        ArtifactRule("htmlcov", markers: python, rule: "artifact.coverage", safety: .safe, rebuild: command("pytest --cov")),

        ArtifactRule("vendor", markers: ["composer.json"], rule: "artifact.vendor", rebuild: command("composer install", 2)),
        ArtifactRule("_build", markers: ["mix.exs"], rule: "artifact.output", rebuild: command("mix compile", 3)),
        ArtifactRule("deps", markers: ["mix.exs"], rule: "artifact.vendor", rebuild: command("mix deps.get", 2)),
        ArtifactRule(".stack-work", markers: ["stack.yaml"], rule: "artifact.output", rebuild: command("stack build", 10)),
        ArtifactRule("dist-newstyle", markers: ["cabal.project"], rule: "artifact.output", rebuild: command("cabal build", 10)),
        ArtifactRule("zig-cache", markers: ["build.zig"], rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".zig-cache", markers: ["build.zig"], rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule("zig-out", markers: ["build.zig"], rule: "artifact.output", rebuild: command("zig build", 2)),
        ArtifactRule("obj", markers: ["*.csproj", "*.fsproj"], rule: "artifact.output", ambiguous: true, rebuild: command("dotnet build", 3)),
        ArtifactRule("bin", markers: ["*.csproj", "*.fsproj"], rule: "artifact.output", ambiguous: true, rebuild: command("dotnet build", 3)),
        ArtifactRule(".terraform", markers: [".terraform.lock.hcl"], rule: "artifact.vendor", rebuild: command("terraform init", 1)),
        ArtifactRule(".terragrunt-cache", markers: ["terragrunt.hcl"], rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
        ArtifactRule(".godot", markers: ["project.godot"], rule: "artifact.build_cache", safety: .safe, rebuild: automatic),
    ]

    /// Tous les marqueurs, pour que le parcours les retienne même petits
    /// (`ScanOptions.notableNames`).
    static var markerNames: Set<String> {
        Set(rules.flatMap(\.markers))
    }

    /// Toujours régénérés, où qu'ils soient : regroupés par projet.
    static let anywhere: Set<String> = ["__pycache__", ".ipynb_checkpoints"]

    /// Dossiers dans lesquels on ne descend jamais pour chercher des projets.
    static let neverDescend: Set<String> = [
        ".git", ".hg", ".svn", ".claude", ".codex", ".cursor", ".idea", ".vscode", ".Trash",
        "Library", "Applications", ".swiftpm", "Backups.backupdb",
    ]
}

/// Cherche les artefacts de construction dans les dossiers de projets.
struct ProjectArtifactsFinder {
    let context: RuleContext
    let maxDepth = 6

    /// Un dossier tel que le chercheur le voit : les noms qu'il contient, et
    /// ceux de ses sous-dossiers où descendre.
    struct Listing {
        var names: Set<String>
        var subdirectories: [String]
        var extensions: Set<String> {
            Set(names.compactMap { name in
                let ext = (name as NSString).pathExtension
                return ext.isEmpty ? nil : "*." + ext
            })
        }
    }

    func find() async -> [Candidate] {
        var candidates: [Candidate] = []
        var anywhereGroups: [String: (project: URL, paths: [URL])] = [:]
        var ambiguous: [(Candidate, URL)] = []
        // L'arborescence de l'analyse, si elle couvre les dossiers de projets :
        // elle sait déjà quels dossiers et quels marqueurs s'y trouvent, sans
        // relire des dizaines de milliers de dossiers (3,5 s ramenées à 0,07 s
        // sur le Mac de Romain, le 18/10/2026).
        let tree = await context.tree?()

        for root in context.projectRoots {
            var queue: [(url: URL, depth: Int, node: TreeNode?)] = [(root, 0, tree?.descendant(atPath: root.path))]
            var head = 0
            while head < queue.count {
                let (directory, depth, node) = queue[head]
                head += 1
                guard let listing = node.map(Self.listing(of:)) ?? Self.listing(of: directory) else { continue }
                let names = listing.names
                let extensions = listing.extensions

                for name in listing.subdirectories {
                    let entry = directory.appendingPathComponent(name, isDirectory: true)
                    if ArtifactTable.anywhere.contains(name) {
                        let project = projectRoot(of: directory, under: root)
                        anywhereGroups[project.path, default: (project, [])].paths.append(entry)
                        continue
                    }
                    if let rule = ArtifactTable.rules.first(where: { rule in
                        rule.folder == name && rule.markers.contains { names.contains($0) || extensions.contains($0) }
                    }) {
                        let candidate = makeCandidate(entry, project: directory, rule: rule)
                        if rule.ambiguous {
                            ambiguous.append((candidate, directory))
                        } else {
                            candidates.append(candidate)
                        }
                        continue
                    }
                    if name == "node_modules" { continue }
                    if ArtifactTable.neverDescend.contains(name) { continue }
                    if name.hasPrefix(".") { continue }
                    if ["app", "xcodeproj", "xcworkspace", "photoslibrary", "bundle", "framework", "sparsebundle",
                        "backupbundle", "fcpbundle", "utm", "pvm", "vmwarevm"]
                        .contains((name as NSString).pathExtension) {
                        continue
                    }
                    if depth + 1 <= maxDepth {
                        queue.append((entry, depth + 1, node.flatMap { $0.child(named: name) }))
                    }
                }
            }
        }

        // Noms ambigus : seulement si git confirme qu'aucun fichier n'y est suivi.
        // Huit `git ls-files` à la fois : un à un, ils faisaient l'essentiel du
        // temps de ce chercheur.
        candidates += await withTaskGroup(of: Candidate?.self) { group in
            var confirmed: [Candidate] = []
            var running = 0
            for (candidate, project) in ambiguous {
                if running >= 8, let result = await group.next() {
                    running -= 1
                    if let result { confirmed.append(result) }
                }
                group.addTask {
                    guard let repository = GitInspector.repositoryRoot(containing: project) else { return nil }
                    let tracked = await GitInspector.containsTrackedFiles(candidate.item.paths[0], repository: repository)
                    return tracked == false ? candidate : nil
                }
                running += 1
            }
            for await result in group { if let result { confirmed.append(result) } }
            return confirmed.sorted { $0.item.id < $1.item.id }
        }

        for (_, group) in anywhereGroups.sorted(by: { $0.key < $1.key }) {
            var item = CleanupItem(
                id: "artifact.pycache|\(group.project.path)",
                title: "__pycache__",
                detail: group.paths.count > 1 ? "×\(group.paths.count)" : nil,
                paths: group.paths,
                category: .projectArtifacts,
                owner: ownerName(group.project),
                ruleID: "artifact.pycache",
                safety: .safe,
                method: .removeNow,
                rebuild: .automatic,
                activityScope: group.project
            )
            if let process = context.busyProject(containing: group.project.path) {
                item.protect(.activeProcess(name: process.name))
            }
            candidates.append(Candidate(item: item))
        }
        return candidates
    }

    /// D'après l'arborescence : les sous-dossiers parcourus, les gros fichiers,
    /// et les petits fichiers que le parcours a retenus pour leur nom (les
    /// marqueurs, `ArtifactTable.markerNames`).
    static func listing(of node: TreeNode) -> Listing? {
        guard node.status == .ok, node.children.count + node.ownFileCount < 20_000 else { return nil }
        var names = Set(node.notableFiles)
        names.formUnion(node.files.map(\.name))
        names.formUnion(node.children.map(\.name))
        let subdirectories = node.children.filter { $0.status == .ok }.map(\.name)
        return Listing(names: names, subdirectories: subdirectories)
    }

    /// D'après le disque, quand l'arborescence ne couvre pas ce dossier.
    static func listing(of directory: URL) -> Listing? {
        let fileManager = FileManager.default
        let entries = fileManager.children(of: directory)
        guard entries.count < 20_000 else { return nil }
        let subdirectories = entries.filter { !$0.isSymbolicLink && fileManager.isDirectory($0) }.map(\.lastPathComponent)
        return Listing(names: Set(entries.map(\.lastPathComponent)), subdirectories: subdirectories)
    }

    private func makeCandidate(_ url: URL, project: URL, rule: ArtifactRule) -> Candidate {
        var item = CleanupItem(
            title: url.lastPathComponent,
            detail: url.deletingLastPathComponent().abbreviated(home: context.home),
            paths: [url],
            category: .projectArtifacts,
            owner: ownerName(project),
            ruleID: rule.ruleID,
            safety: rule.safety,
            method: .removeNow,
            rebuild: rule.rebuild(project),
            activityScope: context.topLevelProject(containing: project.path) ?? project
        )
        // Un agent, une compilation ou un éditeur dans le projet : on n'y touche pas.
        if let process = context.busyProject(containing: project.path) {
            item.protect(.activeProcess(name: process.name))
        }
        return Candidate(item: item)
    }

    /// Le projet de premier niveau sous la racine (« boutique », « meteo »).
    private func projectRoot(of directory: URL, under root: URL) -> URL {
        let relative = directory.path.dropFirst(root.path.count).split(separator: "/")
        guard let first = relative.first else { return directory }
        return root.appendingPathComponent(String(first))
    }

    private func ownerName(_ project: URL) -> String {
        for root in context.projectRoots where project.path.hasPrefix(root.path + "/") {
            let relative = project.path.dropFirst(root.path.count + 1)
            return String(relative.split(separator: "/").first ?? Substring(project.lastPathComponent))
        }
        return project.lastPathComponent
    }
}
