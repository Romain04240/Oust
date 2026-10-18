import Darwin
import Foundation
import OustCore
import OustSafety
import OustScan

/// Où un reste a été trouvé.
public enum LeftoverKind: String, Sendable, Hashable, Codable, CaseIterable {
    case applicationSupport
    case caches
    case preferences
    case savedState
    case container
    case groupContainer
    case launchAgent
    case logs
    case httpStorage
    case webKit
    case cookies
    case applicationScripts

    /// La règle qui porte l'explication (`rule.uninstall.<genre>.what`…).
    public var ruleID: String { "uninstall.\(rawValue)" }

    /// Ce qui se régénère (ou ne sert plus à rien sans l'application) est sûr ;
    /// ce qui peut contenir le travail de l'utilisateur est à examiner.
    var safety: SafetyClass {
        switch self {
        case .caches, .savedState, .logs, .httpStorage, .cookies, .launchAgent: .safe
        case .applicationSupport, .preferences, .container, .groupContainer, .webKit, .applicationScripts: .review
        }
    }

    var rebuild: RebuildCost {
        switch self {
        case .caches, .savedState, .logs, .httpStorage, .cookies, .launchAgent, .applicationScripts: .nothing
        case .applicationSupport, .preferences, .container, .groupContainer, .webKit: .irreversible
        }
    }
}

/// Ce qui relie un reste à son application. Rien de plus vague qu'une égalité.
public enum LeftoverMatch: String, Sendable, Hashable, Codable {
    /// Nommé d'après l'identifiant de bundle (ou celui d'un paquet embarqué).
    case bundleID
    /// Un conteneur dont `MCMMetadataIdentifier` est l'identifiant de l'application.
    case containerMetadata
    /// Un conteneur de groupe déclaré par la signature de l'application, et par
    /// aucune autre application installée.
    case applicationGroup
    /// Un agent `launchd` dont le programme vit dans le paquet.
    case launchAgentProgram
    /// Nommé exactement comme l'application, nom qu'aucune autre ne porte.
    case name
}

/// Un reste d'application : ce qu'elle a laissé dans `~/Library`.
public struct Leftover: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let kind: LeftoverKind
    public let match: LeftoverMatch
    public var sizes: Sizes
    public let fileID: UInt64
    public let modificationDate: Date?
    /// Pourquoi on ne peut pas le retirer, s'il y a une raison.
    public var protection: ProtectionReason?

    public init(url: URL, kind: LeftoverKind, match: LeftoverMatch, sizes: Sizes = .zero, fileID: UInt64 = 0,
                modificationDate: Date? = nil, protection: ProtectionReason? = nil) {
        self.url = url
        self.kind = kind
        self.match = match
        self.sizes = sizes
        self.fileID = fileID
        self.modificationDate = modificationDate
        self.protection = protection
    }

    /// Une correspondance par nom est la moins sûre : jamais mieux qu'« à examiner ».
    public var safety: SafetyClass {
        match == .name ? kind.safety.combined(with: .review) : kind.safety
    }

    /// Coché d'office quand on choisit de désinstaller : seulement ce qui ne
    /// sert plus à rien sans l'application et que rien ne relie à une autre
    /// (RULES.md, règle 4).
    public var isPreselected: Bool {
        protection == nil && safety == .safe
    }
}

/// Trouve les restes d'une application, en correspondance stricte.
///
/// La règle est simple et ne souffre pas d'exception : un reste porte
/// exactement l'identifiant de l'application (ou d'un paquet qu'elle embarque),
/// exactement son nom quand aucune autre application ne le porte, ou c'est son
/// conteneur selon `containermanagerd`, ou c'est un agent qui lance un programme
/// de son paquet. « Ressemble à » ne suffit jamais : `~/Library/Caches/Google`
/// n'appartient pas à « Google Chrome ».
public enum LeftoverFinder {

    public static func leftovers(of app: InstalledApp, among installed: [InstalledApp], home: URL) -> [Leftover] {
        guard app.isUninstallable, app.bundleID != nil else { return [] }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let pathGuard = PathGuard(home: home)
        let others = installed.filter { $0.id != app.id }

        // Ce que d'autres applications installées revendiquent aussi : un second
        // exemplaire de la même application, une suite qui partage un groupe.
        var claimedBy: [String: String] = [:]
        for other in others {
            for id in other.allIDs { claimedBy[id] = claimedBy[id] ?? other.name }
            for group in other.applicationGroups { claimedBy[group] = claimedBy[group] ?? other.name }
            for name in other.names { claimedBy[name] = claimedBy[name] ?? other.name }
        }

        var found: [String: Leftover] = [:]
        func consider(_ url: URL, _ kind: LeftoverKind, _ match: LeftoverMatch, key: String,
                      protection: ProtectionReason? = nil) {
            let name = url.lastPathComponent
            guard !name.lowercased().hasPrefix("com.apple."), found[url.path] == nil else { return }
            var info = stat()
            guard lstat(url.path, &info) == 0, pathGuard.allows(url) else { return }
            let shared = claimedBy[key].map { ProtectionReason.usedByAnotherApp(name: $0) }
            found[url.path] = Leftover(
                url: url, kind: kind, match: match, fileID: UInt64(info.st_ino),
                modificationDate: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                protection: shared ?? protection
            )
        }

        // Par identifiant : l'application et ses paquets embarqués.
        for id in app.allIDs {
            let byID: [(String, LeftoverKind)] = [
                ("Application Support/\(id)", .applicationSupport),
                ("Caches/\(id)", .caches),
                ("HTTPStorages/\(id)", .httpStorage),
                ("HTTPStorages/\(id).binarycookies", .httpStorage),
                ("WebKit/\(id)", .webKit),
                ("Cookies/\(id).binarycookies", .cookies),
                ("Logs/\(id)", .logs),
                ("Preferences/\(id).plist", .preferences),
                ("Saved Application State/\(id).savedState", .savedState),
                ("Application Scripts/\(id)", .applicationScripts),
            ]
            for (relative, kind) in byID {
                consider(library.appendingPathComponent(relative), kind, .bundleID, key: id)
            }
            for url in byHostPreferences(of: id, in: library) {
                consider(url, .preferences, .bundleID, key: id)
            }
        }

        // Les conteneurs : le nom du dossier ne suffit pas, containermanagerd
        // doit confirmer à qui il appartient.
        let containers = library.appendingPathComponent("Containers", isDirectory: true)
        for id in app.allIDs {
            let url = containers.appendingPathComponent(id, isDirectory: true)
            guard exists(url) else { continue }
            switch containerIdentifier(of: url) {
            case .some(let identifier) where identifier == id:
                consider(url, .container, .containerMetadata, key: id)
            case .some:
                continue
            case .none:
                // Illisible : macOS protège les données des autres applications.
                // On montre le conteneur, on n'y touche pas.
                consider(url, .container, .containerMetadata, key: id, protection: .needsFullDiskAccess)
            }
        }
        let groupContainers = library.appendingPathComponent("Group Containers", isDirectory: true)
        for group in app.applicationGroups {
            let url = groupContainers.appendingPathComponent(group, isDirectory: true)
            guard exists(url) else { continue }
            switch containerIdentifier(of: url) {
            case .some(let identifier) where identifier == group:
                consider(url, .groupContainer, .applicationGroup, key: group)
            case .some:
                continue
            case .none:
                consider(url, .groupContainer, .applicationGroup, key: group, protection: .needsFullDiskAccess)
            }
        }

        // Les agents qui lanceraient un programme disparu.
        for url in launchAgents(in: library) where launches(url, programInside: app.url) {
            consider(url, .launchAgent, .launchAgentProgram, key: app.bundleID ?? app.id)
        }

        // Par nom, en dernier : seulement les noms qu'aucune autre application ne porte.
        for name in app.names where !app.allIDs.contains(name) {
            for (folder, kind) in [("Application Support", LeftoverKind.applicationSupport), ("Caches", .caches),
                                   ("Logs", .logs)] {
                consider(library.appendingPathComponent(folder).appendingPathComponent(name), kind, .name, key: name)
            }
        }

        return found.values.sorted { lhs, rhs in
            lhs.kind == rhs.kind ? lhs.url.path < rhs.url.path
                : LeftoverKind.allCases.firstIndex(of: lhs.kind)! < LeftoverKind.allCases.firstIndex(of: rhs.kind)!
        }
    }

    /// Mesure les restes ; liens physiques et clones comptés une fois.
    public static func measured(_ leftovers: [Leftover]) async -> [Leftover] {
        let measures = await Scanner.measure(leftovers.map(\.url))
        return leftovers.map { leftover in
            var measured = leftover
            measured.sizes = measures[leftover.url]?.sizes ?? .zero
            if measures[leftover.url]?.inaccessible == true, measured.protection == nil {
                measured.protection = .needsFullDiskAccess
            }
            return measured
        }
    }

    // MARK: Détails

    /// `~/Library/Preferences/ByHost/<id>.<identifiant matériel>.plist` : l'identifiant
    /// est un UUID ou une adresse matérielle, rien d'autre.
    static func byHostPreferences(of id: String, in library: URL) -> [URL] {
        let folder = library.appendingPathComponent("Preferences/ByHost", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let prefix = id + "."
        return names.filter { name in
            guard name.hasPrefix(prefix), name.hasSuffix(".plist") else { return false }
            let host = name.dropFirst(prefix.count).dropLast(".plist".count)
            return (12...36).contains(host.count) && host.allSatisfy { $0.isHexDigit || $0 == "-" }
        }
        .map { folder.appendingPathComponent($0) }
    }

    /// L'identifiant que `containermanagerd` attribue au conteneur, ou `nil` si
    /// on ne peut pas le lire.
    static func containerIdentifier(of container: URL) -> String? {
        let metadata = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: metadata),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        return plist["MCMMetadataIdentifier"] as? String
    }

    static func launchAgents(in library: URL) -> [URL] {
        let folder = library.appendingPathComponent("LaunchAgents", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".plist") }.map { folder.appendingPathComponent($0) }
    }

    /// Le programme de l'agent (`Program`, sinon le premier de `ProgramArguments`)
    /// est-il dans le paquet ?
    static func launches(_ plistURL: URL, programInside bundle: URL) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return false
        }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        guard let program, program.hasPrefix("/") else { return false }
        let bundlePath = bundle.standardizedFileURL.path
        let literal = URL(fileURLWithPath: program).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: program).resolvingSymlinksInPath().path
        return PathNormalizer.isWithin(literal, bundlePath) || PathNormalizer.isWithin(resolved, bundlePath)
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

// MARK: - Vers la corbeille

extension InstalledApp {
    /// L'application elle-même, comme élément de la corbeille d'Oust!. Toujours
    /// à la corbeille du Mac : elle se remet en place d'un « Remettre ».
    public func cleanupItem() -> CleanupItem {
        CleanupItem(
            id: "uninstall|\(url.path)", title: name, detail: url.deletingLastPathComponent().path, paths: [url],
            category: .applications, owner: name, ruleID: "uninstall.app", safety: .review,
            protections: exclusion == nil ? [] : [.systemPath], method: .trash, sizes: sizes,
            lastActivity: lastUsed ?? modificationDate, rebuild: .download,
            fingerprint: Fingerprint(modificationDate: modificationDate, fileID: fileID), activityScope: url
        )
    }
}

extension Leftover {
    /// Un reste comme élément de la corbeille d'Oust!. Son activité se lit dans le
    /// paquet de l'application : tant qu'elle tourne, on ne touche pas à ses
    /// affaires.
    public func cleanupItem(for app: InstalledApp) -> CleanupItem {
        CleanupItem(
            id: "uninstall|\(url.path)", title: url.lastPathComponent, detail: url.deletingLastPathComponent().path,
            paths: [url], category: .applications, owner: app.name, ruleID: kind.ruleID, safety: safety,
            protections: protection.map { [$0] } ?? [], method: .trash, sizes: sizes, lastActivity: modificationDate,
            rebuild: kind.rebuild, fingerprint: Fingerprint(modificationDate: modificationDate, fileID: fileID),
            activityScope: app.url
        )
    }
}
