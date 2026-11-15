import Foundation

/// Comment un élément quitte le disque (SPEC §6.1).
///
/// Le choix suit la nature de l'élément et non une préférence globale : le
/// régénérable part tout de suite, le personnel va à la corbeille, et ce qu'un
/// outil sait gérer passe par l'outil.
public enum CleanupMethod: Sendable, Hashable, Codable {
    /// Suppression immédiate et définitive, réservée au régénérable.
    case removeNow
    /// Corbeille, avec l'emplacement d'origine au journal.
    case trash
    /// `git worktree remove` depuis le dépôt principal, puis `prune`.
    case gitWorktreeRemove(repository: String)
    /// `xcrun simctl delete <udid>`.
    case simulatorDevice(udid: String)
    /// `xcrun simctl runtime delete <identifiant>`.
    case simulatorRuntime(identifier: String)
    /// `tmutil deletelocalsnapshots <date>` en administrateur.
    case localSnapshot(date: String)
    /// `tmutil delete -d <destination> -t <horodatage>`, par le démon ou en
    /// administrateur : une sauvegarde d'un disque Time Machine branché. Jamais
    /// dans la corbeille : elle part du panneau du disque, par `BackupPruner`.
    case timeMachineBackup(destination: String, timestamp: String)
    /// Historique Firefox vidé en SQL : il partage son fichier avec les favoris.
    case firefoxHistory(database: String)
    /// Remplacer cette copie par un clone APFS de l'original : l'espace est
    /// rendu, le fichier reste.
    case cloneOf(original: String)
    /// Évincer la copie locale d'un fichier iCloud Drive ou d'un File Provider
    /// (Google Drive, Dropbox…) : le fichier reste dans le nuage et revient à
    /// l'ouverture. Rien n'est supprimé.
    case evictLocalCopy
    /// Compression transparente d'APFS, fichier par fichier : chaque fichier
    /// compressé est relu et comparé à l'original avant de le remplacer.
    case compressInPlace
    /// La commande de désinstallation de l'outil (`pyenv uninstall`,
    /// `rustup toolchain uninstall`), qui sait ce qu'elle doit défaire.
    case uninstallVersion(tool: VersionTool, executable: String, root: String, version: String)
    /// `brew cleanup` : les anciennes versions que Homebrew a d'abord listées à blanc.
    case brewCleanup(executable: String)
    /// Par la CLI du moteur (Docker Desktop, OrbStack) : `builder prune` pour le
    /// cache, `image rm` et `container rm` pour les identifiants relevés à l'analyse.
    case containerPrune(executable: String, scope: PruneScope, ids: [String])
    /// Montré pour information ; Oust! ne le supprime pas lui-même (`Docker.raw`).
    case manual
    /// Un projet copié et vérifié sur un disque externe : l'original part à la
    /// corbeille du Mac, si et seulement s'il est encore identique à la copie.
    case archive(copy: String)
    /// Un élément de la photothèque, supprimé par PhotoKit et jamais en touchant
    /// au paquet `.photoslibrary` : il passe 30 jours dans « Supprimés
    /// récemment », et macOS fait confirmer la suppression.
    case photoAsset(localIdentifier: String)
    /// Un fichier d'un nuage mis dans la corbeille du Mac par le Finder : le
    /// service le supprime alors aussi dans le nuage et sur les autres
    /// appareils. « Remettre » le fait revenir tant que la corbeille n'est pas
    /// vidée.
    case trashFromCloud

    public var isSnapshot: Bool {
        if case .localSnapshot = self { return true }
        return false
    }

    public var localizationKey: String {
        switch self {
        case .removeNow: "method.removeNow"
        case .trash: "method.trash"
        case .gitWorktreeRemove: "method.gitWorktreeRemove"
        case .simulatorDevice: "method.simulatorDevice"
        case .simulatorRuntime: "method.simulatorRuntime"
        case .localSnapshot: "method.localSnapshot"
        case .timeMachineBackup: "method.timeMachineBackup"
        case .firefoxHistory: "method.firefoxHistory"
        case .cloneOf: "method.cloneOf"
        case .evictLocalCopy: "method.evictLocalCopy"
        case .compressInPlace: "method.compressInPlace"
        case .uninstallVersion: "method.uninstallVersion"
        case .brewCleanup: "method.brewCleanup"
        case .containerPrune: "method.containerPrune"
        case .manual: "method.manual"
        case .archive: "method.archive"
        case .photoAsset: "method.photoAsset"
        case .trashFromCloud: "method.trashFromCloud"
        }
    }

    /// Vrai si l'espace revient sans attendre qu'on vide la corbeille.
    public var freesImmediately: Bool {
        switch self {
        // Une photo supprimée reste dans « Supprimés récemment » : l'espace ne
        // revient qu'au bout de 30 jours, ou quand on le vide dans Photos.
        case .trash, .manual, .archive, .photoAsset, .trashFromCloud: false
        default: true
        }
    }
}

extension CleanupMethod {
    /// L'identifiant PhotoKit d'un élément de la photothèque.
    public var photoAssetID: String? {
        if case .photoAsset(let id) = self { return id }
        return nil
    }
}

/// Ce qu'on retient d'un élément au moment de l'analyse, pour vérifier juste
/// avant de le supprimer qu'il n'a pas changé entre-temps (RULES.md, règle 2).
public struct Fingerprint: Sendable, Hashable, Codable {
    public var modificationDate: Date?
    public var fileID: UInt64?

    public init(modificationDate: Date?, fileID: UInt64?) {
        self.modificationDate = modificationDate
        self.fileID = fileID
    }
}

/// Un élément que l'utilisateur peut (ou non) envoyer au panier.
public struct CleanupItem: Identifiable, Sendable, Hashable {
    public static let incompleteSafariDownloadRuleID = "downloads.safari_incomplete"

    /// Stable d'une analyse à l'autre : la règle et le premier chemin.
    public let id: String
    /// Nom d'un dossier, d'un projet, d'un modèle : jamais traduit.
    /// nil distingue une mesure APFS indisponible d'une taille privée réellement nulle.
    public var measuredSnapshotBytes: Int64?
    public var title: String
    /// Ligne secondaire non traduite (chemin raccourci, version).
    public var detail: String?
    public var paths: [URL]
    public var category: ItemCategory
    /// Ce par quoi on regroupe à l'écran : un projet, un outil, un agent.
    public var owner: String
    /// Identifiant de la règle, qui porte l'explication (`rule.<id>.what`…).
    public var ruleID: String
    public var safety: SafetyClass
    public var protections: [ProtectionReason]
    public var notes: [ItemNote]
    public var method: CleanupMethod
    public var sizes: Sizes
    public var lastActivity: Date?
    public var rebuild: RebuildCost
    public var fingerprint: Fingerprint?
    /// Le dossier dont l'activité protège l'élément : le projet entier pour un
    /// artefact, le worktree pour un worktree. Revérifié juste avant d'agir.
    public var activityScope: URL?

    public init(
        id: String? = nil,
        title: String,
        detail: String? = nil,
        paths: [URL],
        category: ItemCategory,
        owner: String,
        ruleID: String,
        safety: SafetyClass,
        protections: [ProtectionReason] = [],
        notes: [ItemNote] = [],
        method: CleanupMethod,
        sizes: Sizes = .zero,
        lastActivity: Date? = nil,
        rebuild: RebuildCost,
        fingerprint: Fingerprint? = nil,
        activityScope: URL? = nil
    ) {
        self.id = id ?? "\(ruleID)|\(paths.first?.path ?? title)"
        self.title = title
        self.detail = detail
        self.paths = paths
        self.category = category
        self.owner = owner
        self.ruleID = ruleID
        // Une raison de protéger suffit : la classe s'aligne, quelle que soit
        // celle que la règle proposait.
        self.safety = protections.isEmpty ? safety : safety.combined(with: .protected)
        self.protections = protections
        self.notes = notes
        self.method = method
        self.sizes = sizes
        self.lastActivity = lastActivity
        self.rebuild = rebuild
        self.fingerprint = fingerprint
        self.activityScope = activityScope
    }

    /// Peut entrer dans le panier.
    public var isSelectable: Bool {
        !isIncompleteSafariDownload && safety < .protected && method != .manual
    }

    public var isIncompleteSafariDownload: Bool { ruleID == Self.incompleteSafariDownloadRuleID }

    /// Compte dans le total affiché en titre : une VM n'est pas du « vide à faire ».
    public var countsInHeadline: Bool {
        !notes.contains(.managedSeparately)
    }

    /// Ajoute une protection et réaligne la classe.
    public mutating func protect(_ reason: ProtectionReason) {
        guard !protections.contains(reason) else { return }
        protections.append(reason)
        safety = safety.combined(with: .protected)
    }
}

/// Qui coche quoi d'office (RULES.md, règle 4).
public struct PreselectionPolicy: Sendable, Hashable {
    /// En dessous, un élément « se reconstruit » est affiché mais pas coché :
    /// quelqu'un y travaille peut-être encore.
    public var recencyDays: Int

    public init(recencyDays: Int = 7) {
        self.recencyDays = recencyDays
    }

    public func preselects(_ item: CleanupItem, now: Date = Date()) -> Bool {
        guard item.isSelectable else { return false }
        switch item.safety {
        case .safe:
            return true
        case .rebuilds:
            guard let last = item.lastActivity else { return false }
            return now.timeIntervalSince(last) >= Double(recencyDays) * 86_400
        case .review, .protected, .inaccessible:
            return false
        }
    }
}
