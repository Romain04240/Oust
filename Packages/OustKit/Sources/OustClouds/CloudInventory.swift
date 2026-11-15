import Foundation
import OustCore
import OustScan

/// Un fichier d'un nuage, tel que ce Mac le voit.
public struct CloudEntry: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let accountID: String
    /// Son dossier dans le nuage, composant par composant (« Pages », « Factures ») ;
    /// vide à la racine du compte.
    public let folder: [String]
    /// La taille que compte le nuage.
    public let cloudSize: Int64
    /// Ce qu'il occupe sur ce Mac : rien quand le contenu est resté en ligne.
    public let localSize: Int64
    /// Ce que sa suppression rendrait sur ce Mac (règle 9 : la part privée).
    public let freeable: Int64
    public let modified: Date?
    public let fileID: UInt64
    /// Le contenu est resté dans le nuage : seul le fantôme est ici.
    public let isDataless: Bool
    public let isPackage: Bool
    public let containsSafariDownload: Bool

    public init(url: URL, accountID: String, folder: [String], cloudSize: Int64, localSize: Int64, freeable: Int64,
                modified: Date?, fileID: UInt64, isDataless: Bool, isPackage: Bool = false,
                containsSafariDownload: Bool = false) {
        self.url = url
        self.accountID = accountID
        self.folder = folder
        self.cloudSize = cloudSize
        self.localSize = localSize
        self.containsSafariDownload = containsSafariDownload || SafariDownloadPath.containsPackage(url.path)
        self.freeable = self.containsSafariDownload ? 0 : min(freeable, localSize)
        self.modified = modified
        self.fileID = fileID
        self.isDataless = isDataless
        self.isPackage = isPackage
    }

    public var name: String { url.lastPathComponent }

    /// Téléchargé : il occupe de la place ici en plus de celle du nuage.
    public var isOnThisMac: Bool { !isDataless && localSize > 0 }
}

/// Ce qu'un compte laisse voir sur ce Mac.
public struct CloudAccountSummary: Sendable, Hashable {
    public var files = 0
    public var cloudBytes: Int64 = 0
    public var localBytes: Int64 = 0
    public var downloadedFiles = 0
    /// Dossiers restés dans le nuage, dont le contenu n'est pas compté.
    public var unlistedFolders = 0
    public var unreadableFolders = 0

    public init() {}
}

/// Des fichiers qui portent le même nom et la même taille, dans un ou plusieurs
/// nuages.
///
/// « Évidents » seulement : sans télécharger, rien ne prouve que le contenu est
/// le même (SPEC §7 compare les octets, ce qu'on s'interdit ici).
public struct CloudDuplicateGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let size: Int64
    /// Du plus ancien au plus récent.
    public let files: [CloudEntry]

    /// Ce que garder une seule copie rendrait dans le nuage.
    public var cloudSavings: Int64 { size * Int64(max(0, files.count - 1)) }
}

/// Tout ce que les nuages de ce Mac laissent voir, et les listes qu'on en tire.
public struct CloudInventory: Sendable {
    public let accounts: [CloudAccount]
    public let files: [CloudEntry]
    public let summaries: [String: CloudAccountSummary]
    public let date: Date

    /// Ce qu'un parcours a rendu pour un dossier d'un compte.
    public struct Listing: Sendable {
        public let account: CloudAccount
        public let root: CloudRoot
        public let listing: CloudListing

        public init(account: CloudAccount, root: CloudRoot, listing: CloudListing) {
            self.account = account
            self.root = root
            self.listing = listing
        }
    }

    public init(accounts: [CloudAccount], listings: [Listing], date: Date = Date()) {
        var files: [CloudEntry] = []
        var summaries: [String: CloudAccountSummary] = [:]
        for account in accounts { summaries[account.id] = CloudAccountSummary() }
        for part in listings {
            var summary = summaries[part.account.id] ?? CloudAccountSummary()
            let base = part.root.url.standardizedFileURL.path
            for listed in part.listing.files {
                // Le dossier dans le nuage : le chemin sous la racine, précédé de son
                // nom (« Bureau », « Pages ») quand ce n'est pas celle du compte.
                let relative = listed.path.hasPrefix(base + "/") ? String(listed.path.dropFirst(base.count + 1)) : listed.path
                var folder = relative.split(separator: "/").dropLast().map(String.init)
                if let label = part.root.label { folder.insert(label, at: 0) }
                let file = CloudEntry(
                    url: URL(fileURLWithPath: listed.path), accountID: part.account.id, folder: folder,
                    cloudSize: listed.logicalSize, localSize: listed.isDataless ? 0 : listed.allocatedSize,
                    freeable: listed.isDataless ? 0 : (listed.privateSize ?? listed.allocatedSize),
                    modified: listed.modified, fileID: listed.fileID, isDataless: listed.isDataless,
                    isPackage: listed.isPackage, containsSafariDownload: listed.containsSafariDownload
                )
                files.append(file)
                summary.files += 1
                summary.cloudBytes += file.cloudSize
                summary.localBytes += file.localSize
                if file.isOnThisMac { summary.downloadedFiles += 1 }
            }
            summary.unlistedFolders += part.listing.unlistedFolders.count
            summary.unreadableFolders += part.listing.unreadableFolders.count
            summaries[part.account.id] = summary
        }
        self.accounts = accounts
        self.files = files
        self.summaries = summaries
        self.date = date
    }

    /// Parcourt chaque dossier de chaque compte, sans rien télécharger.
    public static func scan(_ accounts: [CloudAccount], progress: CloudListingProgress = CloudListingProgress(),
                            isCancelled: @escaping @Sendable () -> Bool = { false }) -> CloudInventory {
        var listings: [Listing] = []
        for account in accounts {
            for root in account.roots {
                if isCancelled() { break }
                let listing = CloudLister.list(root.url, isCancelled: isCancelled) { progress.add($0) }
                listings.append(Listing(account: account, root: root, listing: listing))
            }
        }
        return CloudInventory(accounts: accounts, listings: listings)
    }

    public func account(_ id: String) -> CloudAccount? { accounts.first { $0.id == id } }

    // MARK: Listes

    /// Les fichiers des comptes choisis (tous si `accounts` est vide).
    public func files(in accounts: Set<String>) -> [CloudEntry] {
        accounts.isEmpty ? files : files.filter { accounts.contains($0.accountID) }
    }

    /// Les plus gros, d'après ce qu'ils pèsent dans le nuage.
    public func largest(in accounts: Set<String> = [], minimumSize: Int64 = 0) -> [CloudEntry] {
        files(in: accounts).filter { $0.cloudSize >= minimumSize }
            .sorted { ($0.cloudSize, $1.url.path) > ($1.cloudSize, $0.url.path) }
    }

    /// Ceux qui n'ont pas été modifiés depuis `before`, du plus ancien au plus
    /// récent. Sans date, on ne peut pas dire « vieux » : on ne le prétend pas.
    public func oldest(in accounts: Set<String> = [], before: Date, minimumSize: Int64 = 0) -> [CloudEntry] {
        files(in: accounts)
            .filter { file in file.cloudSize >= minimumSize && file.modified.map { $0 < before } == true }
            .sorted { ($0.modified ?? .distantPast, $0.url.path) < ($1.modified ?? .distantPast, $1.url.path) }
    }

    /// Ceux qui occupent de la place ici, du plus lourd au plus léger.
    public func onThisMac(in accounts: Set<String> = [], minimumSize: Int64 = 0) -> [CloudEntry] {
        files(in: accounts).filter { $0.isOnThisMac && $0.localSize >= minimumSize }
            .sorted { ($0.localSize, $1.url.path) > ($1.localSize, $0.url.path) }
    }

    /// Les doublons évidents : même nom (casse et forme Unicode confondues) et
    /// même taille, d'au moins `minimumSize`. Les groupes qui rendraient le plus
    /// viennent en tête.
    public func duplicates(in accounts: Set<String> = [], minimumSize: Int64 = 1_000_000) -> [CloudDuplicateGroup] {
        struct Key: Hashable {
            let name: String
            let size: Int64
        }
        var groups: [Key: [CloudEntry]] = [:]
        for file in files(in: accounts) where !file.containsSafariDownload && file.cloudSize >= max(1, minimumSize) {
            groups[Key(name: Self.comparableName(file.name), size: file.cloudSize), default: []].append(file)
        }
        return groups.compactMap { key, files -> CloudDuplicateGroup? in
            guard files.count > 1 else { return nil }
            let ordered = files.sorted {
                ($0.modified ?? .distantPast, $0.url.path) < ($1.modified ?? .distantPast, $1.url.path)
            }
            return CloudDuplicateGroup(id: "\(key.name)|\(key.size)", name: ordered[0].name, size: key.size, files: ordered)
        }
        .sorted { ($0.cloudSavings, $1.id) > ($1.cloudSavings, $0.id) }
    }

    /// Un nom tel qu'on le compare : Google Drive l'écrit en forme composée,
    /// APFS le garde comme il l'a reçu, et « Facture.PDF » est bien « facture.pdf ».
    static func comparableName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: Totaux

    public func summary(of accounts: Set<String>) -> CloudAccountSummary {
        let ids = accounts.isEmpty ? Set(summaries.keys) : accounts
        var total = CloudAccountSummary()
        for id in ids {
            guard let one = summaries[id] else { continue }
            total.files += one.files
            total.cloudBytes += one.cloudBytes
            total.localBytes += one.localBytes
            total.downloadedFiles += one.downloadedFiles
            total.unlistedFolders += one.unlistedFolders
            total.unreadableFolders += one.unreadableFolders
        }
        return total
    }

    /// L'inventaire sans les fichiers qui viennent de partir, totaux compris.
    public func removing(_ paths: Set<String>) -> CloudInventory {
        guard !paths.isEmpty else { return self }
        var summaries = self.summaries
        var kept: [CloudEntry] = []
        for file in files {
            guard paths.contains(file.url.path) else {
                kept.append(file)
                continue
            }
            guard var summary = summaries[file.accountID] else { continue }
            summary.files -= 1
            summary.cloudBytes -= file.cloudSize
            summary.localBytes -= file.localSize
            if file.isOnThisMac { summary.downloadedFiles -= 1 }
            summaries[file.accountID] = summary
        }
        return CloudInventory(accounts: accounts, files: kept, summaries: summaries, date: date)
    }

    init(accounts: [CloudAccount], files: [CloudEntry], summaries: [String: CloudAccountSummary], date: Date) {
        self.accounts = accounts
        self.files = files
        self.summaries = summaries
        self.date = date
    }
}
