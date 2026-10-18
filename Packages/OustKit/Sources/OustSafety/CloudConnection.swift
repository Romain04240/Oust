import Darwin
import FileProvider
import Foundation

/// Ce que macOS dit d'un compte de cloud : relié à son service, ou non.
///
/// Né de l'essai réel du 18/10/2026. Un compte Google Drive retiré de l'app,
/// son dossier resté sur le Mac, était montré comme vivant : `isUbiquitousItem`
/// le dit encore. Au moment de mettre un de ses fichiers à la corbeille, le
/// Finder affichait « Connexion à « Google Drive - … » impossible », une alerte
/// qui bloquait le nettoyage (50 s, jusqu'au clic sur OK). macOS ne dit
/// l'état d'un domaine qu'à l'app qui l'a créé : deux signaux locaux, sans
/// réseau, le remplacent.
public enum CloudConnection: Sendable, Hashable {
    case connected
    /// L'app du service est fermée. Google Drive, en se fermant, déclare ses
    /// comptes « temporairement déconnectés » (« Vous devez exécuter Google
    /// Drive pour synchroniser ces fichiers. ») ; rien n'y est supprimé sans
    /// elle (Romain, 18/10/2026).
    case appClosed
    /// macOS refuse d'identifier l'élément auprès de son service : le compte
    /// n'y est plus relié, ou l'élément ne lui est pas connu. La raison que
    /// donne macOS n'est pas reprise : pour un compte retiré de Google Drive,
    /// elle dit encore « Vous devez exécuter Google Drive », app ouverte.
    case disconnected

    public var isConnected: Bool { self == .connected }
}

public enum CloudConnectionCheck {

    /// L'état d'un compte ou d'un de ses fichiers. Relié d'abord : un compte
    /// retiré de l'app le reste, qu'elle soit ouverte ou non. Puis, pour un
    /// File Provider (`accountRoot`, le dossier du compte dans
    /// `~/Library/CloudStorage`), l'app du service. iCloud Drive n'a pas d'app
    /// à ouvrir : `accountRoot` nil.
    public static func connection(of url: URL, accountRoot: URL?, running: Set<String>) async -> CloudConnection {
        let identified = await identify(url)
        guard identified.isConnected, let accountRoot else { return identified }
        // Pas d'attribut, pas de service connu : dans le doute, rien n'y part
        // (RULES.md, règle 3).
        guard let provider = providerID(of: accountRoot) else { return .disconnected }
        return isHostRunning(provider: provider, running: running) ? .connected : .appClosed
    }

    /// macOS identifie-t-il cet élément auprès de son service ? fileproviderd
    /// répond de sa base, sans réseau ni téléchargement (0,02 s sur le Mac de
    /// Romain) ; pour un compte déconnecté, une `NSFileProviderError`
    /// (« serverUnreachable »). Toute autre erreur compte aussi comme un refus.
    public static func identify(_ url: URL) async -> CloudConnection {
        await withCheckedContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { item, _, error in
                continuation.resume(returning: item != nil && error == nil ? .connected : .disconnected)
            }
        }
    }

    /// Le File Provider d'un compte, d'après l'attribut que macOS pose sur son
    /// dossier. Le noyau refuse qu'un autre processus le pose (constaté le
    /// 18/10/2026) : un dossier ordinaire ne peut pas se faire passer pour un compte.
    public static func providerID(of accountRoot: URL) -> String? {
        let name = "com.apple.file-provider-domain-id"
        let size = getxattr(accountRoot.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(accountRoot.path, name, &buffer, size, 0, XATTR_NOFOLLOW) == size,
              let value = String(bytes: buffer, encoding: .utf8) else { return nil }
        return provider(fromDomainAttribute: value)
    }

    /// « com.google.drivefs.fpext » pour « com.google.drivefs.fpext/gdrive-1082… ».
    static func provider(fromDomainAttribute value: String) -> String? {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let provider = parts.first, !provider.isEmpty else { return nil }
        return String(provider)
    }

    /// L'app qui porte l'extension est-elle ouverte ? Apple veut que
    /// l'identifiant d'une extension commence par celui de son app
    /// (« com.google.drivefs » pour « com.google.drivefs.fpext »).
    public static func isHostRunning(provider: String, running: Set<String>) -> Bool {
        running.contains { !$0.isEmpty && provider.hasPrefix($0 + ".") }
    }
}

extension PathGuard {
    /// Le dossier du compte File Provider qui contient `url`
    /// (`~/Library/CloudStorage/GoogleDrive-moi@exemple.fr`), ou nil : iCloud
    /// Drive, ou hors des clouds.
    public func fileProviderAccount(of url: URL) -> URL? {
        let path = Self.normalize(url.path)
        let storage = cloudRoots[1]
        guard path.hasPrefix(storage), let folder = path.dropFirst(storage.count).split(separator: "/").first else { return nil }
        return URL(fileURLWithPath: storage + folder, isDirectory: true)
    }
}
