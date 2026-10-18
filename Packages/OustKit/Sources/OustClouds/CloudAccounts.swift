import Foundation
import OustSafety

/// Un service de nuage qui synchronise des fichiers sur ce Mac.
///
/// Seuls ceux qu'on sait reconnaître : un File Provider inconnu peut aussi bien
/// être un téléphone branché (« O+Connect ») qu'un nuage, et supprimer « dans le
/// nuage et sur les autres appareils » n'y voudrait pas dire la même chose.
public enum CloudService: String, Sendable, Hashable, Codable, CaseIterable {
    case iCloudDrive
    case googleDrive
    case oneDrive
    case dropbox
    case box
    case pCloud
    case synologyDrive
    case nextcloud

    /// Le nom de marque, jamais traduit.
    public var displayName: String {
        switch self {
        case .iCloudDrive: "iCloud Drive"
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .dropbox: "Dropbox"
        case .box: "Box"
        case .pCloud: "pCloud"
        case .synologyDrive: "Synology Drive"
        case .nextcloud: "Nextcloud"
        }
    }

    public var symbol: String { self == .iCloudDrive ? "icloud" : "cloud" }

    /// Le service d'un dossier de `~/Library/CloudStorage`, d'après le début de
    /// son nom (`GoogleDrive-moi@exemple.fr`, `OneDrive-Personal`, `Dropbox`).
    public static func fileProvider(folder: String) -> CloudService? {
        let prefix = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        switch prefix {
        case "GoogleDrive": return .googleDrive
        case "OneDrive": return .oneDrive
        case "Dropbox": return .dropbox
        case "Box": return .box
        case "pCloudDrive", "pCloud": return .pCloud
        case "SynologyDrive": return .synologyDrive
        case "Nextcloud": return .nextcloud
        default: return nil
        }
    }
}

/// Un dossier d'un compte, tel que le Finder le montre dans le nuage.
public struct CloudRoot: Sendable, Hashable {
    public let url: URL
    /// Son nom dans le nuage : « Bureau », « Pages » ; nil pour la racine du compte.
    public let label: String?

    public init(url: URL, label: String? = nil) {
        self.url = url
        self.label = label
    }
}

/// Un compte d'un service : iCloud Drive, ou un Google Drive par adresse.
public struct CloudAccount: Sendable, Hashable, Identifiable {
    public let id: String
    public let service: CloudService
    /// L'adresse ou le nom du compte, quand le dossier le dit.
    public let account: String?
    public let roots: [CloudRoot]
    /// Relié à son service, ou non : lu par `connections(of:running:)` après
    /// `discover`, qui ne fait que lire des dossiers.
    public var connection: CloudConnection

    public init(id: String, service: CloudService, account: String?, roots: [CloudRoot],
                connection: CloudConnection = .connected) {
        self.id = id
        self.service = service
        self.account = account
        self.roots = roots
        self.connection = connection
    }

    /// Le dossier du compte dans `~/Library/CloudStorage` ; nil pour iCloud
    /// Drive, qui n'a pas d'app à ouvrir.
    var fileProviderRoot: URL? { service == .iCloudDrive ? nil : roots.first?.url }
}

/// Les comptes synchronisés sur ce Mac. Rien n'est demandé aux serveurs :
/// tout se lit dans les dossiers que les services ont posés ici (RULES.md,
/// règle 11).
public enum CloudAccounts {

    /// Un dossier de nuage vivant : macOS le dit « ubiquitaire ». Les anciens
    /// dossiers qu'un service laisse en se déconnectant
    /// (« GoogleDrive-x (10-07-2026 16:41) ») ne le sont plus.
    public static func isLive(_ url: URL) -> Bool {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// Le nom que le Finder donne au dossier iCloud d'une application
    /// (« Pages », « GoodNotes »), lu dans les métadonnées locales.
    public static func containerName(_ container: URL) -> String {
        let values = try? URL(fileURLWithPath: container.path).resourceValues(forKeys: [.ubiquitousItemContainerDisplayNameKey])
        if let name = values?.ubiquitousItemContainerDisplayName, !name.isEmpty { return name }
        return fallbackName(container.lastPathComponent)
    }

    /// « iCloud~md~obsidian » → « Obsidian », « com~apple~Pages » → « Pages ».
    static func fallbackName(_ folder: String) -> String {
        let last = folder.split(separator: "~").last.map(String.init) ?? folder
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    public static func discover(
        home: URL,
        isLive: (URL) -> Bool = CloudAccounts.isLive,
        containerName: (URL) -> String = CloudAccounts.containerName,
        displayName: (URL) -> String = { FileManager.default.displayName(atPath: $0.path) }
    ) -> [CloudAccount] {
        var accounts: [CloudAccount] = []
        let fileManager = FileManager.default
        let mobile = home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let drive = mobile.appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        if isDirectory(drive), isLive(drive) {
            var roots = [CloudRoot(url: drive)]
            // Le Bureau et les Documents, quand iCloud Drive les synchronise : le
            // dossier iCloud Drive n'en garde que des liens, qu'on ne suit pas.
            for name in ["Desktop", "Documents"] {
                let folder = home.appendingPathComponent(name, isDirectory: true)
                if isDirectory(folder), isLive(folder) { roots.append(CloudRoot(url: folder, label: displayName(folder))) }
            }
            // Les dossiers des applications que le Finder range sous iCloud Drive :
            // leur `Documents`, jamais ce qu'elles gardent pour elles (`Data`).
            let containers = (try? fileManager.contentsOfDirectory(atPath: mobile.path)) ?? []
            for name in containers.sorted() where !name.hasPrefix(".") && name != "com~apple~CloudDocs" {
                let lower = name.lowercased()
                if PathGuard.passwordManagerMarkers.contains(where: lower.contains) { continue }
                let container = mobile.appendingPathComponent(name, isDirectory: true)
                let documents = container.appendingPathComponent("Documents", isDirectory: true)
                guard isDirectory(documents) else { continue }
                roots.append(CloudRoot(url: documents, label: containerName(container)))
            }
            accounts.append(CloudAccount(id: "icloud", service: .iCloudDrive, account: nil, roots: roots))
        }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let folders = (try? fileManager.contentsOfDirectory(atPath: storage.path)) ?? []
        for name in folders.sorted() where !name.hasPrefix(".") {
            guard let service = CloudService.fileProvider(folder: name) else { continue }
            let folder = storage.appendingPathComponent(name, isDirectory: true)
            guard isDirectory(folder), isLive(folder) else { continue }
            let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
            accounts.append(CloudAccount(id: folder.path, service: service, account: parts.count > 1 ? parts[1] : nil,
                                         roots: [CloudRoot(url: folder)]))
        }
        return accounts
    }

    /// Ce que macOS dit de chaque compte : relié, app fermée, déconnecté
    /// (essai du 18/10/2026). Local et sans réseau : fileproviderd répond de sa
    /// base, en quelques centièmes de seconde par compte.
    public static func connections(
        of accounts: [CloudAccount], running: Set<String>,
        check: (URL, URL?, Set<String>) async -> CloudConnection = CloudConnectionCheck.connection
    ) async -> [CloudAccount] {
        var checked = accounts
        for index in checked.indices {
            guard let root = checked[index].roots.first?.url else { continue }
            checked[index].connection = await check(root, checked[index].fileProviderRoot, running)
        }
        return checked
    }

    /// Un vrai dossier, sans suivre de lien.
    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
