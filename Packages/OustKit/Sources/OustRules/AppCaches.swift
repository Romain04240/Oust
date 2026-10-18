import Foundation
import OustCore
import OustSafety

/// Les caches des applications, une par une : `~/Library/Caches/<bundle-id>`.
///
/// Jamais ceux d'Apple (le système les gère, et certains portent des données que
/// macOS ne régénère pas sans bruit), jamais ceux des gestionnaires de mots de
/// passe (on ne touche pas, même de loin, à ce qui entoure des secrets), jamais
/// ceux qu'une autre règle couvre déjà (navigateurs, outils de développement).
/// Protégés tant que l'application est ouverte : elle y écrit.
struct AppCachesFinder {
    let context: RuleContext

    /// Préfixes d'identifiants écartés d'office.
    static let excludedPrefixes = [
        "com.apple.",
        // Navigateurs : leur section les traite, navigateur fermé exigé (SPEC §8).
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
        "com.operasoftware.", "org.mozilla.", "company.thebrowser.", "app.zen-browser.",
        // Déjà comptés par les agents (`agent.cache`) : pas deux fois (RULES.md, règle 9).
        "com.openai.codex", "com.openai.chat",
        // Oust! lui-même.
        "fr.meaillais.oust",
    ]

    /// Gestionnaires de mots de passe, reconnus à leur nom quel que soit l'éditeur.
    static let passwordManagerMarkers = [
        "1password", "agilebits", "bitwarden", "lastpass", "dashlane", "keepass", "enpass", "sinew",
        "keeper", "nordpass", "roboform", "strongbox", "proton.pass", "protonpass", "passwords", "secrets",
        "keychain", "authenticator", "passbolt", "psono", "minimalist.pass",
    ]

    func find() async -> [Candidate] {
        let caches = context.path("Library/Caches")
        let fileManager = FileManager.default
        return fileManager.children(of: caches).compactMap { folder -> Candidate? in
            let name = folder.lastPathComponent
            guard fileManager.isDirectory(folder), !folder.isSymbolicLink, Self.isBundleIdentifier(name),
                  !Self.isExcluded(name) else { return nil }
            let appName = context.applicationName(name) ?? name
            var item = CleanupItem(
                title: appName, detail: name, paths: [folder], category: .appCaches, owner: appName,
                ruleID: "cache.app", safety: .safe, method: .removeNow, rebuild: .automatic
            )
            if let running = context.runningApps.first(where: { AppOwnership.cache(name, belongsTo: $0) }) {
                // Une extension (« …SetappAgent.FinderSyncExt ») n'a pas d'application à
                // elle : on nomme celle du cache, déjà trouvée.
                item.protect(.appRunning(name: context.applicationName(running) ?? appName))
            }
            return Candidate(item: item, minimumAllocated: 1_000_000)
        }
    }

    /// « com.spotify.client » oui, « Homebrew » ou « pip » non : leurs règles
    /// existent déjà, et un nom sans point ne dit pas à quelle application il est.
    static func isBundleIdentifier(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9_-]+)+/) != nil
    }

    static func isExcluded(_ name: String) -> Bool {
        let lower = name.lowercased()
        if excludedPrefixes.contains(where: { lower.hasPrefix($0.lowercased()) }) { return true }
        return passwordManagerMarkers.contains { lower.contains($0) }
    }

}
