import Foundation
import OustCore
import OustSafety

/// Les caches de gestionnaires de paquets : régénérés au prochain téléchargement.
struct PackageCachesFinder {
    let context: RuleContext

    struct Entry {
        let path: String
        let title: String
        let rule: String
        let safety: SafetyClass
        let rebuild: RebuildCost
        /// Démon dont la présence protège le cache (Gradle).
        let daemon: String?

        init(_ path: String, _ title: String, rule: String, safety: SafetyClass = .safe,
             rebuild: RebuildCost = .automatic, daemon: String? = nil) {
            self.path = path
            self.title = title
            self.rule = rule
            self.safety = safety
            self.rebuild = rebuild
            self.daemon = daemon
        }
    }

    static let entries: [Entry] = [
        Entry(".npm/_cacache", "npm", rule: "cache.npm"),
        Entry(".npm/_npx", "npx", rule: "cache.npm"),
        Entry("Library/Caches/Yarn", "Yarn", rule: "cache.yarn"),
        Entry(".yarn/berry/cache", "Yarn Berry", rule: "cache.yarn"),
        Entry("Library/pnpm/store", "pnpm", rule: "cache.pnpm", safety: .rebuilds, rebuild: .command("pnpm install", minutes: 2)),
        Entry(".bun/install/cache", "Bun", rule: "cache.bun"),
        Entry("Library/Caches/pip", "pip", rule: "cache.pip"),
        Entry(".cache/uv", "uv", rule: "cache.pip"),
        Entry("Library/Caches/pypoetry", "Poetry", rule: "cache.pip"),
        Entry(".gradle/caches", "Gradle", rule: "cache.gradle", safety: .rebuilds,
              rebuild: .command("./gradlew build", minutes: 10), daemon: "GradleDaemon"),
        Entry(".gradle/wrapper/dists", "Gradle Wrapper", rule: "cache.gradle", safety: .rebuilds, rebuild: .download),
        Entry(".m2/repository", "Maven", rule: "cache.maven", safety: .review, rebuild: .download),
        Entry("Library/Caches/CocoaPods", "CocoaPods", rule: "cache.cocoapods"),
        Entry(".cargo/registry/cache", "Cargo", rule: "cache.cargo"),
        Entry("Library/Caches/go-build", "Go", rule: "cache.go"),
        Entry("Library/Caches/Homebrew", "Homebrew", rule: "cache.homebrew"),
        Entry(".pub-cache", "Dart / Flutter", rule: "cache.pub", safety: .rebuilds, rebuild: .command("flutter pub get", minutes: 2)),
        Entry("Library/Caches/ms-playwright", "Playwright", rule: "cache.browsers_test", safety: .rebuilds, rebuild: .download),
        Entry(".cache/puppeteer", "Puppeteer", rule: "cache.browsers_test", safety: .rebuilds, rebuild: .download),
    ]

    func find() async -> [Candidate] {
        let fileManager = FileManager.default
        var candidates: [Candidate] = []
        for entry in Self.entries {
            let url = context.path(entry.path)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            var item = CleanupItem(
                title: entry.title,
                detail: url.abbreviated(home: context.home),
                paths: [url],
                category: .packageCaches,
                owner: entry.title,
                ruleID: entry.rule,
                safety: entry.safety,
                method: .removeNow,
                rebuild: entry.rebuild
            )
            if let daemon = entry.daemon, await Self.daemonRunning(daemon) {
                item.protect(.daemonRunning(name: "Gradle"))
            }
            candidates.append(Candidate(item: item))
        }
        return candidates
    }

    /// Un démon Java ne se reconnaît pas à son nom d'exécutable : on cherche sa
    /// ligne de commande.
    static func daemonRunning(_ pattern: String) async -> Bool {
        await Command.run("/usr/bin/pgrep", ["-f", pattern], timeout: 5).status == 0
    }
}

/// Xcode : DerivedData, caches de modules, DeviceSupport, archives.
struct XcodeFinder {
    let context: RuleContext

    func find() async -> [Candidate] {
        var candidates: [Candidate] = []
        let fileManager = FileManager.default
        let developer = context.path("Library/Developer/Xcode")
        let xcodeRunning = context.processes.isRunning("Xcode")

        // DerivedData, rattaché à son projet.
        let derived = developer.appendingPathComponent("DerivedData")
        for folder in fileManager.children(of: derived) where fileManager.isDirectory(folder) {
            let name = folder.lastPathComponent
            if name.hasSuffix(".noindex") || name == "SDKExplicitPrecompiledModules" {
                var item = CleanupItem(title: name, detail: folder.abbreviated(home: context.home), paths: [folder],
                                       category: .xcode, owner: "Xcode", ruleID: "xcode.module_cache",
                                       safety: .rebuilds, method: .removeNow, rebuild: .automatic)
                if xcodeRunning { item.protect(.appRunning(name: "Xcode")) }
                candidates.append(Candidate(item: item))
                continue
            }
            let workspace = Self.workspacePath(of: folder)
            let projectName = name.split(separator: "-").dropLast().joined(separator: "-")
            let exists = workspace.map { fileManager.fileExists(atPath: $0) } ?? true
            var item = CleanupItem(
                title: projectName.isEmpty ? name : projectName,
                detail: workspace.map { URL(fileURLWithPath: $0).abbreviated(home: context.home) },
                paths: [folder],
                category: .xcode,
                owner: "DerivedData",
                ruleID: exists ? "xcode.derived_data" : "xcode.derived_data_orphan",
                safety: exists ? .rebuilds : .safe,
                notes: exists ? [] : [.orphan],
                method: .removeNow,
                rebuild: exists ? .command("xcodebuild", minutes: 5) : .nothing,
                activityScope: workspace.flatMap {
                    context.topLevelProject(containing: ($0 as NSString).deletingLastPathComponent)
                }
            )
            if let workspace,
               let process = context.busyProject(containing: (workspace as NSString).deletingLastPathComponent) {
                item.protect(.activeProcess(name: process.name))
            }
            candidates.append(Candidate(item: item))
        }

        // DeviceSupport : on garde la version la plus récente de chaque plateforme.
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let folder = developer.appendingPathComponent("\(platform) DeviceSupport")
            let entries = fileManager.children(of: folder).filter { fileManager.isDirectory($0) }
            let newest = entries.max {
                Self.version(in: $0.lastPathComponent).lexicographicallyPrecedes(Self.version(in: $1.lastPathComponent))
            }
            for entry in entries {
                var item = CleanupItem(title: entry.lastPathComponent, detail: platform, paths: [entry],
                                       category: .xcode, owner: "DeviceSupport", ruleID: "xcode.device_support",
                                       safety: .safe, method: .removeNow, rebuild: .download)
                if entry == newest { item.protect(.newestKept) }
                candidates.append(Candidate(item: item))
            }
        }

        // Archives : elles contiennent les dSYM des versions publiées.
        let archives = developer.appendingPathComponent("Archives")
        for day in fileManager.children(of: archives) where fileManager.isDirectory(day) {
            for archive in fileManager.children(of: day) where archive.pathExtension == "xcarchive" {
                candidates.append(Candidate(item: CleanupItem(
                    title: archive.deletingPathExtension().lastPathComponent,
                    detail: day.lastPathComponent,
                    paths: [archive], category: .xcode, owner: "Archives", ruleID: "xcode.archive",
                    safety: .review, method: .trash, rebuild: .irreversible
                )))
            }
        }

        // Petits caches qui se régénèrent seuls.
        let extras: [(String, String, String)] = [
            ("Library/Developer/Xcode/iOS Device Logs", "iOS Device Logs", "xcode.logs"),
            ("Library/Developer/Xcode/DocumentationCache", "DocumentationCache", "xcode.logs"),
            ("Library/Developer/Xcode/UserData/Previews", "Previews", "xcode.previews"),
            ("Library/Caches/com.apple.dt.Xcode", "Caches Xcode", "xcode.logs"),
        ]
        for (path, title, rule) in extras {
            let url = context.path(path)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            var item = CleanupItem(title: title, detail: url.abbreviated(home: context.home), paths: [url],
                                   category: .xcode, owner: "Xcode", ruleID: rule, safety: .safe,
                                   method: .removeNow, rebuild: .automatic)
            if xcodeRunning, rule == "xcode.previews" { item.protect(.appRunning(name: "Xcode")) }
            candidates.append(Candidate(item: item))
        }
        return candidates
    }

    /// Le projet d'un dossier DerivedData, écrit par Xcode dans `info.plist`.
    static func workspacePath(of folder: URL) -> String? {
        let plist = folder.appendingPathComponent("info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return object["WorkspacePath"] as? String
    }

    /// « iPhone18,2 27.0.1 (24A446) » → [27, 0, 1].
    static func version(in name: String) -> [Int] {
        let pattern = /(\d+)\.(\d+)(?:\.(\d+))?\s*\(/
        guard let match = name.firstMatch(of: pattern) else { return [0] }
        return [Int(match.1) ?? 0, Int(match.2) ?? 0, Int(match.3 ?? "0") ?? 0]
    }
}

/// Simulateurs : appareils et runtimes, par `simctl` (SPEC §4).
struct SimulatorFinder {
    let context: RuleContext

    private struct DeviceList: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let dataPathSize: Int64?
        let lastUsedAt: String?
    }

    private struct Runtime: Decodable {
        let identifier: String
        let version: String?
        let platformIdentifier: String?
        let sizeBytes: Int64?
        let deletable: Bool?
        let runtimeIdentifier: String?
    }

    func find() async -> [Candidate] {
        var candidates: [Candidate] = []
        let dateFormatter = ISO8601DateFormatter()

        let devicesResult = await Command.run("/usr/bin/xcrun", ["simctl", "list", "-j", "devices"], timeout: 30)
        var usedRuntimes = Set<String>()
        if devicesResult.succeeded, let list = try? JSONDecoder().decode(DeviceList.self, from: devicesResult.stdout) {
            for (runtime, devices) in list.devices {
                let runtimeName = Self.runtimeName(runtime)
                if !devices.isEmpty { usedRuntimes.insert(runtime) }
                for device in devices {
                    let available = device.isAvailable ?? true
                    var item = CleanupItem(
                        id: "simulator|\(device.udid)",
                        title: device.name,
                        detail: runtimeName,
                        paths: [context.path("Library/Developer/CoreSimulator/Devices/\(device.udid)")],
                        category: .simulators,
                        owner: available ? runtimeName : "—",
                        ruleID: available ? "simulator.device" : "simulator.unavailable",
                        safety: available ? .review : .safe,
                        method: .simulatorDevice(udid: device.udid),
                        sizes: Sizes(private: device.dataPathSize ?? 0),
                        lastActivity: device.lastUsedAt.flatMap { dateFormatter.date(from: $0) },
                        rebuild: available ? .command("Xcode › Devices", minutes: 1) : .nothing
                    )
                    if device.state == "Booted" { item.protect(.booted) }
                    candidates.append(Candidate(item: item, needsMeasure: device.dataPathSize == nil))
                }
            }
        }

        let runtimesResult = await Command.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: 30)
        if runtimesResult.succeeded,
           let runtimes = try? JSONDecoder().decode([String: Runtime].self, from: runtimesResult.stdout) {
            for (_, runtime) in runtimes where runtime.deletable ?? true {
                let platform = (runtime.platformIdentifier ?? "").replacingOccurrences(of: "com.apple.platform.", with: "")
                let used = runtime.runtimeIdentifier.map(usedRuntimes.contains) ?? true
                let item = CleanupItem(
                    id: "runtime|\(runtime.identifier)",
                    title: "\(Self.platformName(platform)) \(runtime.version ?? "")",
                    detail: runtime.identifier,
                    paths: [],
                    category: .simulators,
                    owner: "Runtimes",
                    ruleID: "simulator.runtime",
                    safety: .review,
                    notes: used ? [] : [.orphan],
                    method: .simulatorRuntime(identifier: runtime.identifier),
                    sizes: Sizes(private: runtime.sizeBytes ?? 0),
                    rebuild: .download
                )
                candidates.append(Candidate(item: item, needsMeasure: false))
            }
        }
        return candidates
    }

    /// « com.apple.CoreSimulator.SimRuntime.iOS-27-0 » → « iOS 27.0 ».
    static func runtimeName(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return identifier }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }

    static func platformName(_ platform: String) -> String {
        switch platform {
        case "iphonesimulator": "iOS"
        case "appletvsimulator": "tvOS"
        case "watchsimulator": "watchOS"
        case "xrsimulator": "visionOS"
        default: platform
        }
    }
}
