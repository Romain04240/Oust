import CoreServices
import Darwin
import Foundation
import OustCore
import Security

/// Les applications installées dans `/Applications` et `~/Applications`.
public enum AppCatalog {

    /// Les deux dossiers d'applications que le Finder propose.
    public static func standardRoots(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Les paquets `.app` d'un dossier d'applications : au premier niveau, et dans
    /// un sous-dossier qui n'est pas lui-même un paquet (« Adobe Photoshop 2026/ »,
    /// « Utilitaires/ »). Plus bas, ce sont les assistants d'une application, pas
    /// des applications.
    public static func bundles(in roots: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            if seen.insert(url.standardizedFileURL.path).inserted { found.append(url) }
        }
        for root in roots {
            for entry in visibleChildren(of: root, fileManager) where !isSymbolicLink(entry) {
                if entry.pathExtension == "app" {
                    add(entry)
                } else if isDirectory(entry), !isPackage(entry) {
                    for nested in visibleChildren(of: entry, fileManager)
                    where nested.pathExtension == "app" && !isSymbolicLink(nested) {
                        add(nested)
                    }
                }
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Lit toutes les applications, sans les mesurer (la mesure vient ensuite).
    ///
    /// Les noms sûrs sont calculés sur l'ensemble : un nom que deux applications
    /// portent ne désigne plus aucune des deux.
    public static func installedApps(
        in roots: [URL],
        entitlements: (URL) -> [String] = Entitlements.applicationGroups(of:),
        lastUsed: (URL) -> Date? = Spotlight.lastUsedDate(of:)
    ) -> [InstalledApp] {
        let apps = bundles(in: roots).compactMap { read($0, entitlements: entitlements, lastUsed: lastUsed) }
        return withUniqueNames(apps)
    }

    /// Lit un paquet. `nil` si ce n'est pas un paquet d'application lisible.
    public static func read(
        _ url: URL,
        entitlements: (URL) -> [String] = Entitlements.applicationGroups(of:),
        lastUsed: (URL) -> Date? = Spotlight.lastUsedDate(of:)
    ) -> InstalledApp? {
        let contents = url.appendingPathComponent("Contents")
        guard let info = plist(contents.appendingPathComponent("Info.plist")) else { return nil }
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }

        let bundleID = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let fileName = url.deletingPathExtension().lastPathComponent
        let displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName
        let embedded = embeddedBundles(in: contents)
        let excluded = Exclusions.reason(bundleID: bundleID, name: displayName, fileName: fileName, embedded: embedded)

        // La signature n'est lue que pour les applications qu'on peut désinstaller :
        // celle de Xcode coûte plusieurs secondes et ne servirait à rien.
        let groups = excluded == nil || excluded == .passwordManager || excluded == .vpn ? entitlements(url) : []
        let names = [fileName, info["CFBundleName"] as? String, info["CFBundleDisplayName"] as? String]
            .compactMap { $0 }
        var uniqueNames: [String] = []
        for name in names where !uniqueNames.contains(name) { uniqueNames.append(name) }

        return InstalledApp(
            url: url,
            name: displayName,
            bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String,
            embeddedIDs: embedded.compactMap(\.identifier).filter { $0 != bundleID },
            applicationGroups: groups,
            names: uniqueNames,
            isAppStore: FileManager.default.fileExists(atPath: contents.appendingPathComponent("_MASReceipt").path),
            fileID: UInt64(status.st_ino),
            modificationDate: Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)),
            lastUsed: lastUsed(url),
            exclusion: excluded
        )
    }

    /// Retire les noms trop courts ou portés par plusieurs applications : une
    /// correspondance par nom n'est stricte que si le nom n'appartient qu'à une.
    static func withUniqueNames(_ apps: [InstalledApp]) -> [InstalledApp] {
        var owners: [String: Set<String>] = [:]
        for app in apps {
            for name in app.names { owners[name, default: []].insert(app.bundleID ?? app.id) }
        }
        return apps.map { app in
            let safe = app.names.filter { name in
                name.count >= 3 && !name.lowercased().hasPrefix("com.apple") && owners[name]?.count == 1
            }
            return InstalledApp(url: app.url, name: app.name, bundleID: app.bundleID, version: app.version,
                                embeddedIDs: app.embeddedIDs, applicationGroups: app.applicationGroups, names: safe,
                                isAppStore: app.isAppStore, fileID: app.fileID, modificationDate: app.modificationDate,
                                lastUsed: app.lastUsed, sizes: app.sizes, exclusion: app.exclusion)
        }
    }

    // MARK: Paquets embarqués

    /// Un paquet embarqué : extension, assistant, service XPC, extension système.
    struct EmbeddedBundle: Sendable, Hashable {
        let url: URL
        let identifier: String?
        /// `NSExtensionPointIdentifier` d'une extension (`.appex`).
        let extensionPoint: String?
        /// Une extension système qui déclare une extension réseau.
        let isNetworkExtension: Bool
        let isSystemExtension: Bool
    }

    /// Les paquets embarqués, sans descendre dans les frameworks ni plus bas que
    /// quatre niveaux : c'est là que vivent les assistants, et le reste d'un gros
    /// paquet (ressources d'un jeu) ne contient pas d'identifiant.
    static func embeddedBundles(in contents: URL) -> [EmbeddedBundle] {
        let bundleExtensions: Set<String> = ["app", "appex", "xpc", "systemextension"]
        guard let enumerator = FileManager.default.enumerator(
            at: contents, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var found: [EmbeddedBundle] = []
        for case let url as URL in enumerator {
            if enumerator.level > 4 { enumerator.skipDescendants(); continue }
            let ext = url.pathExtension
            if ext == "framework" || ext == "bundle" || ext == "plugin" || ext == "lproj" || isSymbolicLink(url) {
                enumerator.skipDescendants()
                continue
            }
            guard bundleExtensions.contains(ext) else { continue }
            enumerator.skipDescendants()
            let info = plist(url.appendingPathComponent("Contents/Info.plist")) ?? [:]
            let extensionInfo = info["NSExtension"] as? [String: Any]
            found.append(EmbeddedBundle(
                url: url,
                identifier: info["CFBundleIdentifier"] as? String,
                extensionPoint: extensionInfo?["NSExtensionPointIdentifier"] as? String,
                isNetworkExtension: info["NetworkExtension"] != nil,
                isSystemExtension: ext == "systemextension"
            ))
        }
        return found
    }

    // MARK: Outils

    static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func visibleChildren(of url: URL, _ fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                              options: [.skipsHiddenFiles])) ?? []
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }
}

/// Ce que la signature de code déclare, lu par Security et sans `codesign`.
public enum Entitlements {
    public static func applicationGroups(of url: URL) -> [String] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return [] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}

/// Ce que Spotlight sait de l'usage d'un fichier. Local : rien ne sort du Mac.
public enum Spotlight {
    public static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
