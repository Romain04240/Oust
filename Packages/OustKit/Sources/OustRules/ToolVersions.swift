import Foundation
import OustCore
import OustSafety

/// Les versions d'outils qui ne servent plus : Xcode, installeurs de macOS, Node
/// (nvm), Python (pyenv), JDK, NDK Android, toolchains Rust.
///
/// Une règle d'or : la version active ou par défaut est **toujours** gardée, et
/// quand on ne sait pas laquelle c'est, on garde tout (RULES.md, règle 3).
struct ToolVersionsFinder {
    let context: RuleContext

    func find() async -> [Candidate] {
        var candidates: [Candidate] = []
        let pins = ProjectPins.read(context)
        candidates += await xcodeVersions()
        candidates += macOSInstallers()
        candidates += nodeVersions(pins: pins)
        candidates += pythonVersions(pins: pins)
        candidates += await javaVersions()
        candidates += androidNDKs()
        candidates += rustToolchains(pins: pins)
        return candidates
    }

    // MARK: - Xcode

    /// Les copies de `/Applications/Xcode*.app` autres que celle que désigne
    /// `xcode-select -p`.
    func xcodeVersions() async -> [Candidate] {
        let fileManager = FileManager.default
        let apps = fileManager.children(of: context.applications).filter {
            $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" && !$0.isSymbolicLink
                && fileManager.isDirectory($0)
        }
        guard !apps.isEmpty else { return [] }

        let selected = await context.tools.run("/usr/bin/xcode-select", ["-p"], nil, 10)
        let active = selected.succeeded ? Self.appBundle(containing: selected.output) : nil
        let activeResolved = active.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        // `xcode-select` pointe vers les Command Line Tools, ou ne répond pas :
        // on ne sait pas quel Xcode sert, on garde le plus récent.
        let knowsActive = apps.contains { $0.resolvingSymlinksInPath().path == activeResolved }
        let newest = apps.max { Self.compare(Self.bundleVersion($0) ?? "", Self.bundleVersion($1) ?? "") }

        return apps.map { app in
            let version = Self.bundleVersion(app)
            var item = CleanupItem(
                title: version.map { "Xcode \($0)" } ?? app.deletingPathExtension().lastPathComponent,
                detail: app.path, paths: [app], category: .toolVersions, owner: "Xcode",
                ruleID: "version.xcode", safety: .review, method: .trash, rebuild: .download
            )
            let isActive = app.resolvingSymlinksInPath().path == activeResolved
            if isActive { item.protect(.activeVersion) }
            if !knowsActive, app == newest { item.protect(.newestKept) }
            if let process = context.processes.running(inside: app.path) { item.protect(.appRunning(name: process.name)) }
            // L'Xcode actif pèse ses 10 Go, mais on ne le propose pas : inutile
            // de parcourir ses centaines de milliers de fichiers pour le dire.
            return Candidate(item: item, needsMeasure: !isActive)
        }
    }

    /// « /Applications/Xcode-beta.app/Contents/Developer » → « /Applications/Xcode-beta.app ».
    static func appBundle(containing path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: ".app/", options: .caseInsensitive) ?? trimmed.range(of: ".app", options: [.caseInsensitive, .anchored, .backwards]) else {
            return nil
        }
        return String(trimmed[..<range.lowerBound]) + ".app"
    }

    // MARK: - Installeurs de macOS

    /// « Install macOS Sequoia.app » : plusieurs gigaoctets qu'on garde par oubli
    /// après la mise à jour.
    func macOSInstallers() -> [Candidate] {
        FileManager.default.children(of: context.applications)
            .filter { $0.lastPathComponent.hasPrefix("Install macOS") && $0.pathExtension == "app" && !$0.isSymbolicLink }
            .map { app in
                var item = CleanupItem(
                    title: app.deletingPathExtension().lastPathComponent,
                    detail: Self.bundleVersion(app), paths: [app], category: .systemDownloads, owner: "macOS",
                    ruleID: "version.macos_installer", safety: .review, method: .trash,
                    lastActivity: app.modificationDate, rebuild: .download
                )
                if let process = context.processes.running(inside: app.path) { item.protect(.appRunning(name: process.name)) }
                return Candidate(item: item)
            }
    }

    // MARK: - Node (nvm)

    func nodeVersions(pins: ProjectPins) -> [Candidate] {
        let root = context.path(".nvm")
        let versionsFolder = root.appendingPathComponent("versions/node")
        let fileManager = FileManager.default
        let versions = fileManager.children(of: versionsFolder)
            .filter { $0.lastPathComponent.hasPrefix("v") && fileManager.isDirectory($0) && !$0.isSymbolicLink }
        guard !versions.isEmpty else { return [] }
        let names = versions.map(\.lastPathComponent)

        let aliases = root.appendingPathComponent("alias")
        let stored = (try? String(contentsOf: aliases.appendingPathComponent("default"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isSystem = stored == "system"
        let defaultVersion = stored.flatMap { Self.resolveNvmAlias($0, installed: names, aliases: aliases) }
        // Un alias par défaut illisible : on ne sait pas quelle version sert.
        let unknown = !isSystem && defaultVersion == nil

        return versions.map { folder in
            let name = folder.lastPathComponent
            var item = CleanupItem(
                title: "Node \(name)", detail: folder.abbreviated(home: context.home), paths: [folder],
                category: .toolVersions, owner: "nvm", ruleID: "version.nvm", safety: .rebuilds,
                method: .removeNow, rebuild: .command("nvm install \(name)", minutes: 1)
            )
            if name == defaultVersion { item.protect(.activeVersion) }
            if unknown { item.protect(.unknownState) }
            if let process = context.processes.running(inside: folder.path) { item.protect(.activeProcess(name: process.name)) }
            if let project = pins.node.first(where: { Self.resolveNvmAlias($0.version, installed: names, aliases: aliases) == name }) {
                item.notes.append(.usedByProject(name: project.project))
                item.safety = item.safety.combined(with: .review)
            }
            return Candidate(item: item)
        }
    }

    /// Ce que désigne un alias nvm : « 22 », « v22.3.0 », « lts/* », « node », un
    /// alias à soi. `nil` si on ne sait pas le dire.
    static func resolveNvmAlias(_ alias: String, installed: [String], aliases: URL, depth: Int = 0) -> String? {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard depth < 6, !alias.isEmpty else { return nil }
        let sorted = installed.sorted { compare($0, $1) }
        if alias == "node" || alias == "stable" { return sorted.last }
        let bare = alias.hasPrefix("v") ? String(alias.dropFirst()) : alias
        if bare.first?.isNumber == true, bare.allSatisfy({ $0.isNumber || $0 == "." }) {
            if installed.contains("v\(bare)") { return "v\(bare)" }
            return sorted.last { $0.hasPrefix("v\(bare).") }
        }
        // `lts/*` et `lts/jod` sont des fichiers sous `alias/lts/`, comme les alias à soi.
        guard !alias.contains(".."), !alias.hasPrefix("/") else { return nil }
        let file = aliases.appendingPathComponent(alias)
        guard let target = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return resolveNvmAlias(target, installed: installed, aliases: aliases, depth: depth + 1)
    }

    // MARK: - Python (pyenv)

    func pythonVersions(pins: ProjectPins) -> [Candidate] {
        let root = context.path(".pyenv")
        let fileManager = FileManager.default
        // Les liens de `versions/` sont les environnements de pyenv-virtualenv :
        // ils vivent dans leur version, qu'on traite d'un bloc.
        let versions = fileManager.children(of: root.appendingPathComponent("versions"))
            .filter { fileManager.isDirectory($0) && !$0.isSymbolicLink }
        guard !versions.isEmpty else { return [] }

        let installed = versions.map(\.lastPathComponent)
        let versionsFolder = root.appendingPathComponent("versions")
        // `pyenv global` : le fichier `version`, une version par ligne. Absent,
        // c'est le Python du système, et aucune version de pyenv n'est la globale.
        // Illisible, ou désignant une version introuvable : on ne sait pas, on garde tout.
        let versionFile = root.appendingPathComponent("version")
        var global = Set<String>()
        var unknown = false
        if FileManager.default.fileExists(atPath: versionFile.path) {
            if let text = try? String(contentsOf: versionFile, encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    let name = line.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !name.hasPrefix("#"), name != "system" else { continue }
                    if let base = Self.resolvePyenv(name, installed: installed, versions: versionsFolder) {
                        global.insert(base)
                    } else {
                        unknown = true
                    }
                }
            } else {
                unknown = true
            }
        }
        let executable = context.tools.locate([
            root.appendingPathComponent("bin/pyenv").path, "/opt/homebrew/bin/pyenv", "/usr/local/bin/pyenv",
        ])

        return versions.map { folder in
            let name = folder.lastPathComponent
            let method: CleanupMethod = executable.map {
                .uninstallVersion(tool: .pyenv, executable: $0, root: root.path, version: name)
            } ?? .removeNow
            var item = CleanupItem(
                title: "Python \(name)", detail: folder.abbreviated(home: context.home), paths: [folder],
                category: .toolVersions, owner: "pyenv", ruleID: "version.pyenv", safety: .rebuilds,
                method: method, rebuild: .command("pyenv install \(name)", minutes: 5)
            )
            if global.contains(name) { item.protect(.activeVersion) }
            if unknown { item.protect(.unknownState) }
            if let process = context.processes.running(inside: folder.path) { item.protect(.activeProcess(name: process.name)) }
            if let project = pins.python.first(where: {
                Self.resolvePyenv($0.version, installed: installed, versions: versionsFolder) == name
            }) {
                item.notes.append(.usedByProject(name: project.project))
                item.safety = item.safety.combined(with: .review)
            }
            let environments = fileManager.children(of: folder.appendingPathComponent("envs")).filter { fileManager.isDirectory($0) }
            if !environments.isEmpty {
                // Des environnements à soi, avec leurs paquets : on ne coche pas d'office.
                item.notes.append(.hasEnvironments(count: environments.count))
                item.safety = item.safety.combined(with: .review)
            }
            return Candidate(item: item)
        }
    }

    /// La version installée que désigne un nom, comme `pyenv version-name` :
    /// « 3.12.4 », « 3.12 » (la 3.12.x la plus récente), « python-3.12 », ou le nom
    /// d'un environnement virtuel, ramené à la version qui le porte.
    static func resolvePyenv(_ requested: String, installed: [String], versions: URL) -> String? {
        let name = requested.hasPrefix("python-") ? String(requested.dropFirst("python-".count)) : requested
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        if installed.contains(name) { return name }
        // Un environnement de pyenv-virtualenv : `versions/<nom>` est un lien vers
        // `versions/<base>/envs/<nom>`.
        let link = versions.appendingPathComponent(name)
        if link.isSymbolicLink {
            let target = link.resolvingSymlinksInPath().pathComponents
            if let envs = target.lastIndex(of: "envs"), envs > 0, installed.contains(target[envs - 1]) {
                return target[envs - 1]
            }
        }
        if let base = installed.first(where: {
            FileManager.default.isDirectory(versions.appendingPathComponent("\($0)/envs/\(name)"))
        }) {
            return base
        }
        return installed.filter { $0.hasPrefix(name + ".") }.max { compare($0, $1) }
    }

    // MARK: - Java

    /// Les JDK que Gradle télécharge (`~/.gradle/jdks`) et ceux du système
    /// (`/Library/Java/JavaVirtualMachines`). Le JDK par défaut
    /// (`/usr/libexec/java_home`) est gardé.
    func javaVersions() async -> [Candidate] {
        let fileManager = FileManager.default
        let home = await context.tools.run("/usr/libexec/java_home", [], nil, 10)
        let defaultHome = home.succeeded ? home.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let isDefault = { (jdk: URL) -> Bool in
            guard let defaultHome, !defaultHome.isEmpty else { return false }
            return PathNormalizer.isWithin(URL(fileURLWithPath: defaultHome).resolvingSymlinksInPath().path,
                                           jdk.resolvingSymlinksInPath().path)
        }
        var candidates: [Candidate] = []

        let gradle = context.path(".gradle/jdks")
        for entry in fileManager.children(of: gradle) where !entry.isSymbolicLink {
            let name = entry.lastPathComponent
            if name.hasSuffix(".lock") || name == "CACHEDIR.TAG" { continue }
            if fileManager.isDirectory(entry) {
                var item = CleanupItem(
                    title: name, detail: entry.abbreviated(home: context.home), paths: [entry],
                    category: .toolVersions, owner: "Gradle", ruleID: "version.jdk_gradle", safety: .rebuilds,
                    method: .removeNow, rebuild: .download
                )
                if isDefault(entry) { item.protect(.activeVersion) }
                // Un démon Gradle lancé avec ce JDK a son exécutable dedans.
                if let process = context.processes.running(inside: entry.path) { item.protect(.activeProcess(name: process.name)) }
                candidates.append(Candidate(item: item))
            } else if ["gz", "zip", "tgz"].contains(entry.pathExtension.lowercased()) {
                // L'archive téléchargée, déjà décompressée à côté.
                candidates.append(Candidate(item: CleanupItem(
                    title: name, detail: entry.abbreviated(home: context.home), paths: [entry],
                    category: .toolVersions, owner: "Gradle", ruleID: "version.jdk_gradle", safety: .safe,
                    method: .removeNow, rebuild: .download
                )))
            }
        }

        // Les JDK du système appartiennent à root : les retirer demande un mot de
        // passe administrateur, qu'Oust! ne demande que pour les snapshots
        // (RULES.md, règle 7). On les montre, on dit comment faire.
        let system = context.systemLibrary.appendingPathComponent("Java/JavaVirtualMachines")
        for jdk in fileManager.children(of: system) where jdk.pathExtension == "jdk" && !jdk.isSymbolicLink {
            var item = CleanupItem(
                title: jdk.deletingPathExtension().lastPathComponent, detail: jdk.path, paths: [jdk],
                category: .toolVersions, owner: "Java", ruleID: "version.jdk_system", safety: .review,
                method: .manual, rebuild: .download
            )
            if isDefault(jdk) { item.protect(.activeVersion) }
            candidates.append(Candidate(item: item))
        }
        return candidates
    }

    // MARK: - NDK Android

    func androidNDKs() -> [Candidate] {
        let fileManager = FileManager.default
        let sdk = context.path("Library/Android/sdk")
        let versions = fileManager.children(of: sdk.appendingPathComponent("ndk"))
            .filter { fileManager.isDirectory($0) && !$0.isSymbolicLink }
        var folders = versions
        // L'ancien emplacement unique, remplacé par `ndk/<version>` depuis 2019.
        let legacy = sdk.appendingPathComponent("ndk-bundle")
        if fileManager.isDirectory(legacy), !legacy.isSymbolicLink { folders.append(legacy) }
        // Le plus récent des `ndk/<version>`, ou `ndk-bundle` s'il est le seul.
        let newest = versions.max { Self.compare($0.lastPathComponent, $1.lastPathComponent) } ?? folders.first

        return folders.map { folder in
            var item = CleanupItem(
                title: "NDK \(folder.lastPathComponent)", detail: folder.abbreviated(home: context.home), paths: [folder],
                category: .toolVersions, owner: "Android", ruleID: "version.ndk", safety: .rebuilds,
                method: .removeNow, rebuild: .download
            )
            if folder == newest { item.protect(.newestKept) }
            if let process = context.processes.running(inside: folder.path) { item.protect(.activeProcess(name: process.name)) }
            return Candidate(item: item)
        }
    }

    // MARK: - Rust (rustup)

    func rustToolchains(pins: ProjectPins) -> [Candidate] {
        let fileManager = FileManager.default
        let root = context.path(".rustup")
        let toolchains = fileManager.children(of: root.appendingPathComponent("toolchains"))
            .filter { fileManager.isDirectory($0) && !$0.isSymbolicLink }
        guard !toolchains.isEmpty else { return [] }

        let settings = RustupSettings.read(root.appendingPathComponent("settings.toml"))
        let executable = context.tools.locate([
            context.path(".cargo/bin/rustup").path, "/opt/homebrew/bin/rustup", "/usr/local/bin/rustup",
        ])
        let projectPins = pins.rust + settings.overrides.map {
            ProjectPins.Pin(project: URL(fileURLWithPath: $0.path).lastPathComponent, version: $0.toolchain)
        }

        return toolchains.map { folder in
            let name = folder.lastPathComponent
            let method: CleanupMethod = executable.map {
                .uninstallVersion(tool: .rustup, executable: $0, root: root.path, version: name)
            } ?? .removeNow
            var item = CleanupItem(
                title: name, detail: folder.abbreviated(home: context.home), paths: [folder],
                category: .toolVersions, owner: "rustup", ruleID: "version.rustup", safety: .rebuilds,
                method: method, rebuild: .command("rustup toolchain install \(name)", minutes: 2)
            )
            if let defaultToolchain = settings.defaultToolchain {
                if Self.toolchain(name, matches: defaultToolchain) { item.protect(.activeVersion) }
            } else {
                // Pas de toolchain par défaut lisible : on ne sait pas ce qui sert.
                item.protect(.unknownState)
            }
            if let process = context.processes.running(inside: folder.path) { item.protect(.activeProcess(name: process.name)) }
            if let project = projectPins.first(where: { Self.toolchain(name, matches: $0.version) }) {
                item.notes.append(.usedByProject(name: project.project))
                item.safety = item.safety.combined(with: .review)
            }
            return Candidate(item: item)
        }
    }

    /// « stable-aarch64-apple-darwin » répond à « stable » comme à son nom complet.
    static func toolchain(_ name: String, matches requested: String) -> Bool {
        name == requested || name.hasPrefix(requested + "-")
    }

    // MARK: - Outils

    /// `CFBundleShortVersionString` d'une application.
    static func bundleVersion(_ app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// Ordre des versions, composante par composante : « 9.2 » < « 10.1 »,
    /// « 27.1.12297006 » < « 29.0.13113456 ». Vrai si `lhs` précède `rhs`.
    static func compare(_ lhs: String, _ rhs: String) -> Bool {
        let parts = { (text: String) -> [Int] in
            text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let left = parts(lhs)
        let right = parts(rhs)
        if left == right { return lhs < rhs }
        return left.lexicographicallyPrecedes(right)
    }
}

/// Les versions que les projets demandent : `.nvmrc`, `.node-version`,
/// `.python-version`, `rust-toolchain(.toml)`, à la racine de chaque projet.
struct ProjectPins: Sendable {
    struct Pin: Sendable {
        let project: String
        let version: String
    }

    var node: [Pin] = []
    var python: [Pin] = []
    var rust: [Pin] = []

    static func read(_ context: RuleContext) -> ProjectPins {
        var pins = ProjectPins()
        let fileManager = FileManager.default
        for root in context.projectRoots {
            for project in fileManager.children(of: root) where fileManager.isDirectory(project) {
                let name = project.lastPathComponent
                let first = { (file: String) -> String? in
                    (try? String(contentsOf: project.appendingPathComponent(file), encoding: .utf8))?
                        .split(whereSeparator: \.isNewline).first
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .flatMap { $0.isEmpty ? nil : $0 }
                }
                for file in [".nvmrc", ".node-version"] {
                    if let version = first(file) { pins.node.append(Pin(project: name, version: version)) }
                }
                if let versions = try? String(contentsOf: project.appendingPathComponent(".python-version"), encoding: .utf8) {
                    for line in versions.split(whereSeparator: \.isNewline) {
                        let version = line.trimmingCharacters(in: .whitespaces)
                        if !version.isEmpty { pins.python.append(Pin(project: name, version: version)) }
                    }
                }
                if let channel = first("rust-toolchain"), !channel.hasPrefix("[") {
                    pins.rust.append(Pin(project: name, version: channel))
                }
                if let toml = try? String(contentsOf: project.appendingPathComponent("rust-toolchain.toml"), encoding: .utf8),
                   let channel = RustupSettings.value(of: "channel", in: toml) {
                    pins.rust.append(Pin(project: name, version: channel))
                }
            }
        }
        return pins
    }
}

/// Ce qu'on lit de `~/.rustup/settings.toml`, sans dépendance TOML : deux
/// clés et une table suffisent.
struct RustupSettings: Sendable {
    var defaultToolchain: String?
    var overrides: [(path: String, toolchain: String)] = []

    static func read(_ url: URL) -> RustupSettings {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return RustupSettings() }
        var settings = RustupSettings(defaultToolchain: value(of: "default_toolchain", in: text))
        var inOverrides = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOverrides = line == "[overrides]"
                continue
            }
            guard inOverrides, let equal = line.firstIndex(of: "=") else { continue }
            let key = unquote(String(line[..<equal]))
            let value = unquote(String(line[line.index(after: equal)...]))
            if !key.isEmpty, !value.isEmpty { settings.overrides.append((key, value)) }
        }
        return settings
    }

    /// La valeur d'une clé de premier niveau : `default_toolchain = "stable-…"`.
    static func value(of key: String, in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key), let equal = line.firstIndex(of: "=") else { continue }
            guard line[..<equal].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = unquote(String(line[line.index(after: equal)...]))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func unquote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
