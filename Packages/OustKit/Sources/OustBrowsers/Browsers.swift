import AppKit
import Foundation
import OustCore

/// Les navigateurs qu'Oust! sait nettoyer (SPEC §8).
public enum BrowserKind: String, Sendable, CaseIterable, Identifiable, Codable {
    case safari, chrome, arc, brave, edge, vivaldi, opera, firefox

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .arc: "Arc"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .firefox: "Firefox"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .arc: "company.thebrowser.Browser"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        case .firefox: "org.mozilla.firefox"
        }
    }

    /// Le dossier de données (profils), relatif au dossier personnel.
    var dataRoot: String {
        switch self {
        case .safari: "Library/Safari"
        case .chrome: "Library/Application Support/Google/Chrome"
        case .arc: "Library/Application Support/Arc/User Data"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge: "Library/Application Support/Microsoft Edge"
        case .vivaldi: "Library/Application Support/Vivaldi"
        case .opera: "Library/Application Support/com.operasoftware.Opera"
        case .firefox: "Library/Application Support/Firefox"
        }
    }

    /// Le dossier de cache hors profil, relatif au dossier personnel.
    var cacheRoot: String {
        switch self {
        case .safari: "Library/Caches/com.apple.Safari"
        case .chrome: "Library/Caches/Google/Chrome"
        case .arc: "Library/Caches/Arc/User Data"
        case .brave: "Library/Caches/BraveSoftware/Brave-Browser"
        case .edge: "Library/Caches/Microsoft Edge"
        case .vivaldi: "Library/Caches/Vivaldi"
        case .opera: "Library/Caches/com.operasoftware.Opera"
        case .firefox: "Library/Caches/Firefox/Profiles"
        }
    }

    var isChromium: Bool { ![.safari, .firefox].contains(self) }
}

/// Un profil de navigateur, avec ce qu'on peut y nettoyer.
public struct BrowserProfile: Sendable, Identifiable, Hashable {
    public var id: String { "\(browser.rawValue)|\(folder.path)" }
    public let browser: BrowserKind
    public let name: String
    public let folder: URL
    public let caches: [URL]
    public let history: [URL]
    public let cookies: [URL]
    /// Firefox : l'historique partage `places.sqlite` avec les favoris.
    public let historyDatabase: URL?
    /// Safari protège son historique derrière l'Accès complet au disque.
    public let historyReadable: Bool
}

/// Trouve les profils et en fait des éléments pour le panier.
public enum BrowserFinder {

    public static func profiles(home: URL) -> [BrowserProfile] {
        BrowserKind.allCases.flatMap { profiles(of: $0, home: home) }
    }

    static func profiles(of browser: BrowserKind, home: URL) -> [BrowserProfile] {
        let fileManager = FileManager.default
        let data = home.appendingPathComponent(browser.dataRoot)
        let cacheRoot = home.appendingPathComponent(browser.cacheRoot)
        let existing = { (urls: [URL]) in urls.filter { fileManager.fileExists(atPath: $0.path) } }

        switch browser {
        case .safari:
            let container = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library")
            let caches = existing([cacheRoot, container.appendingPathComponent("Caches")])
            let historyFile = data.appendingPathComponent("History.db")
            let readable = fileManager.isReadableFile(atPath: historyFile.path)
            let history = readable ? existing(["History.db", "History.db-wal", "History.db-shm"].map { data.appendingPathComponent($0) }) : []
            let cookies = existing([
                container.appendingPathComponent("Cookies/Cookies.binarycookies"),
                home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
            ])
            guard !caches.isEmpty || fileManager.fileExists(atPath: data.path) else { return [] }
            return [BrowserProfile(browser: .safari, name: "Safari", folder: data, caches: caches,
                                   history: history, cookies: cookies, historyDatabase: nil, historyReadable: readable)]

        case .firefox:
            return firefoxProfiles(data: data).map { name, folder in
                let id = folder.lastPathComponent
                return BrowserProfile(
                    browser: .firefox, name: name, folder: folder,
                    caches: existing([cacheRoot.appendingPathComponent(id)]),
                    history: [],
                    cookies: existing(["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"].map { folder.appendingPathComponent($0) }),
                    historyDatabase: existing([folder.appendingPathComponent("places.sqlite")]).first,
                    historyReadable: true
                )
            }

        default:
            return chromiumProfiles(data: data).map { name, folder in
                let profileID = folder.lastPathComponent
                let caches = existing([
                    cacheRoot.appendingPathComponent(profileID),
                    folder.appendingPathComponent("Code Cache"),
                    folder.appendingPathComponent("GPUCache"),
                    folder.appendingPathComponent("DawnCache"),
                    folder.appendingPathComponent("DawnGraphiteCache"),
                    folder.appendingPathComponent("DawnWebGPUCache"),
                    folder.appendingPathComponent("Service Worker/CacheStorage"),
                ])
                // Jamais `Login Data` (mots de passe) ni `Web Data` (cartes,
                // adresses), ni `Bookmarks`, ni `Favicons` (icônes des favoris).
                let history = existing(["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal",
                                        "Shortcuts", "Shortcuts-journal"].map { folder.appendingPathComponent($0) })
                let cookies = existing(["Network/Cookies", "Network/Cookies-journal", "Cookies", "Cookies-journal"]
                    .map { folder.appendingPathComponent($0) })
                return BrowserProfile(browser: browser, name: name, folder: folder, caches: caches, history: history,
                                      cookies: cookies, historyDatabase: nil, historyReadable: true)
            }
        }
    }

    /// Les profils Chromium, nommés comme dans le navigateur (`Local State`).
    static func chromiumProfiles(data: URL) -> [(String, URL)] {
        let fileManager = FileManager.default
        var names: [String: String] = [:]
        if let json = try? Data(contentsOf: data.appendingPathComponent("Local State")),
           let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           let profile = object["profile"] as? [String: Any],
           let cache = profile["info_cache"] as? [String: Any] {
            for (key, value) in cache {
                names[key] = (value as? [String: Any])?["name"] as? String ?? key
            }
        }
        let folders = ((try? fileManager.contentsOfDirectory(atPath: data.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") || names[$0] != nil }
            .filter { fileManager.fileExists(atPath: data.appendingPathComponent($0).path) }
        return folders.sorted().map { (names[$0] ?? $0, data.appendingPathComponent($0)) }
    }

    /// Les profils Firefox, lus dans `profiles.ini`.
    static func firefoxProfiles(data: URL) -> [(String, URL)] {
        guard let text = try? String(contentsOf: data.appendingPathComponent("profiles.ini"), encoding: .utf8) else {
            return []
        }
        var result: [(String, URL)] = []
        var name: String?
        var path: String?
        var relative = true
        func flush() {
            if let path {
                let url = relative ? data.appendingPathComponent(path) : URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) { result.append((name ?? url.lastPathComponent, url)) }
            }
            name = nil; path = nil; relative = true
        }
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") { flush(); continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Name": name = parts[1]
            case "Path": path = parts[1]
            case "IsRelative": relative = parts[1] == "1"
            default: break
            }
        }
        flush()
        return result
    }

    /// Les éléments d'un profil : cache (sûr), historique et cookies (à examiner).
    public static func items(for profile: BrowserProfile, isRunning: Bool) -> [CleanupItem] {
        let owner = "\(profile.browser.displayName) · \(profile.name)"
        func item(_ kind: String, paths: [URL], safety: SafetyClass, method: CleanupMethod) -> CleanupItem? {
            guard !paths.isEmpty || method != .removeNow else { return nil }
            var item = CleanupItem(
                id: "browser.\(kind)|\(profile.id)",
                title: profile.browser.displayName,
                detail: profile.name,
                paths: paths,
                category: .browsers,
                owner: owner,
                ruleID: "browser.\(kind)",
                safety: safety,
                method: method,
                rebuild: kind == "cache" ? .automatic : .irreversible,
                activityScope: nil
            )
            // Un navigateur ouvert réécrit ses fichiers pendant qu'on les retire.
            if isRunning { item.protect(.appRunning(name: profile.browser.displayName)) }
            return item
        }

        var items: [CleanupItem] = []
        if let cache = item("cache", paths: profile.caches, safety: .safe, method: .removeNow) { items.append(cache) }
        if let database = profile.historyDatabase {
            if var history = item("history", paths: [database], safety: .review, method: .firefoxHistory(database: database.path)) {
                history.paths = [database]
                items.append(history)
            }
        } else if profile.historyReadable {
            if let history = item("history", paths: profile.history, safety: .review, method: .removeNow) { items.append(history) }
        } else if var locked = item("history", paths: [profile.folder], safety: .review, method: .removeNow) {
            locked.protect(.needsFullDiskAccess)
            items.append(locked)
        }
        if let cookies = item("cookies", paths: profile.cookies, safety: .review, method: .removeNow) { items.append(cookies) }
        return items
    }

    /// Le navigateur est-il ouvert ?
    @MainActor
    public static func isRunning(_ browser: BrowserKind) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).isEmpty
    }
}
