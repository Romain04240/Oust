import AppKit
import Darwin
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

/// Les profils lisibles et les navigateurs dont l'inventaire reste indéterminé.
public struct BrowserProfileInventory: Sendable {
    public let profiles: [BrowserProfile]
    public let unavailableBrowsers: Set<BrowserKind>
}

public enum BrowserFinder {

    public static func profiles(home: URL) -> [BrowserProfile] {
        inventory(home: home).profiles
    }

    /// Un registre Firefox illisible n'est pas une preuve de retrait de ses profils.
    public static func inventory(home: URL) -> BrowserProfileInventory {
        var result: [BrowserProfile] = []
        var unavailable = Set<BrowserKind>()
        for browser in BrowserKind.allCases {
            if browser == .firefox {
                guard let entries = readableFirefoxProfiles(data: home.appendingPathComponent(browser.dataRoot)) else {
                    unavailable.insert(browser)
                    continue
                }
                guard let profiles = verifiedFirefoxProfiles(home: home, entries: entries) else {
                    unavailable.insert(browser)
                    continue
                }
                result += profiles
            } else {
                result += profiles(of: browser, home: home)
            }
        }
        return BrowserProfileInventory(profiles: result, unavailableBrowsers: unavailable)
    }

    private static func verifiedFirefoxProfiles(home: URL, entries: [(String, URL)]) -> [BrowserProfile]? {
        func existing(_ urls: [URL], type: FileAttributeType) -> [URL]? {
            var result: [URL] = []
            for url in urls {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == type else { return nil }
                    result.append(url)
                } catch {
                    if !isConfirmedMissing(error) { return nil }
                }
            }
            return result
        }
        let cache = home.appendingPathComponent(BrowserKind.firefox.cacheRoot)
        var profiles: [BrowserProfile] = []
        for (name, folder) in entries {
            guard let caches = existing([cache.appendingPathComponent(folder.lastPathComponent)], type: .typeDirectory),
                  let cookies = existing(["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"].map { folder.appendingPathComponent($0) }, type: .typeRegular),
                  let databases = existing([folder.appendingPathComponent("places.sqlite")], type: .typeRegular) else { return nil }
            profiles.append(BrowserProfile(browser: .firefox, name: name, folder: folder, caches: caches,
                history: [], cookies: cookies, historyDatabase: databases.first, historyReadable: true))
        }
        return profiles
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
            guard let entries = readableFirefoxProfiles(data: data) else { return [] }
            return verifiedFirefoxProfiles(home: home, entries: entries) ?? []

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
        readableFirefoxProfiles(data: data) ?? []
    }

    private static func isConfirmedMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(ENOENT) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isConfirmedMissing(underlying)
        }
        return error.domain == NSCocoaErrorDomain
            && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
    }

    private static func readableFirefoxProfiles(data: URL) -> [(String, URL)]? {
        let text: String
        do { text = try String(contentsOf: data.appendingPathComponent("profiles.ini"), encoding: .utf8) }
        catch { return isConfirmedMissing(error) ? [] : nil }
        var result: [(String, URL)] = []
        var recognized = false
        var profileSection = false
        var fields: [String: String] = [:]
        func finishProfile() -> Bool {
            guard profileSection else { return true }
            let relative = fields["IsRelative"]
            guard let path = fields["Path"], !path.isEmpty,
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  relative == nil || relative == "0" || relative == "1" else { return false }
            guard relative != "0" || path.hasPrefix("/") else { return false }
            let folder = relative == "0" ? URL(fileURLWithPath: path) : data.appendingPathComponent(path)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
            } catch { return isConfirmedMissing(error) }
            result.append((fields["Name"] ?? folder.lastPathComponent, folder))
            return true
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), finishProfile() else { return nil }
                let section = String(line.dropFirst().dropLast())
                profileSection = section.hasPrefix("Profile") && Int(section.dropFirst("Profile".count)) != nil
                if section.hasPrefix("Profile"), !profileSection { return nil }
                recognized = recognized || profileSection || section == "General" || section.hasPrefix("Install")
                fields = [:]
            } else {
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard recognized, pair.count == 2, !pair[0].isEmpty else { return nil }
                if profileSection {
                    if let previous = fields[pair[0]], previous != pair[1] { return nil }
                    fields[pair[0]] = pair[1]
                }
            }
        }
        return recognized && finishProfile() ? result : nil
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
