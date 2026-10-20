import Foundation

/// Ce qu'il est advenu d'un élément du panier.
public enum OutcomeResult: Sendable, Hashable, Codable {
    /// Supprimé définitivement (régénérable).
    case removed
    /// Parti à la corbeille ; restaurable tant qu'elle n'est pas vidée.
    case trashed
    /// Confié à un outil (git, simctl, tmutil) qui a confirmé.
    case delegated
    /// Remplacé par un clone de l'original.
    case cloned
    /// Copie locale évincée : le fichier reste dans le nuage.
    case evicted
    /// Compressé sur place par APFS, contenu vérifié.
    case compressed
    /// Supprimé par Photos : dans « Supprimés récemment » pendant 30 jours,
    /// restaurable depuis Photos, et l'espace n'est rendu qu'ensuite.
    case recentlyDeleted
    /// Laissé en place, avec la raison.
    case skipped(SkipReason)
    /// L'opération a échoué ; le message vient du système.
    case failed(message: String)

    public var succeeded: Bool {
        switch self {
        case .removed, .trashed, .delegated, .cloned, .evicted, .compressed, .recentlyDeleted: true
        case .skipped, .failed: false
        }
    }
}

/// Pourquoi un élément a été laissé au dernier moment.
public enum SkipReason: Sendable, Hashable, Codable {
    /// Il n'existe plus.
    case vanished
    /// Il a changé depuis l'analyse.
    case changedSinceScan
    /// Il est devenu protégé (un processus s'y est installé, une modification git…).
    case nowProtected(ProtectionReason)
    /// La garde de chemins l'a refusé.
    case refusedByGuard
    /// Annulé par l'utilisateur avant son tour.
    case cancelled

    public var localizationKey: String {
        switch self {
        case .vanished: "skip.vanished"
        case .changedSinceScan: "skip.changedSinceScan"
        case .nowProtected: "skip.nowProtected"
        case .refusedByGuard: "skip.refusedByGuard"
        case .cancelled: "skip.cancelled"
        }
    }
}

/// Qui a lancé un nettoyage.
///
/// L'app n'est plus seule à écrire au journal : `oust`, la commande des agents
/// IA, y ajoute ses lignes depuis un autre processus. L'Historique doit pouvoir
/// dire « ceci, ce n'est pas vous ».
public enum CleanupOrigin: Sendable, Hashable, Codable {
    case app
    /// Un agent IA, par `oust`. `name` : le processus qui l'a lancé
    /// (« claude », « codex »), quand on a pu le lire.
    case agent(name: String?)
}

/// Une ligne de l'historique : un élément traité.
public struct CleanupOutcome: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(sessionID.uuidString)|\(itemID)" }
    public var sessionID: UUID
    public var date: Date
    public var itemID: String
    public var title: String
    public var owner: String
    public var category: ItemCategory
    public var method: CleanupMethod
    public var paths: [String]
    public var result: OutcomeResult
    /// Octets rendus (ou qui le seront une fois la corbeille vidée).
    public var bytes: Int64
    /// Où chaque chemin a atterri dans la corbeille, dans le même ordre que `paths`.
    public var trashedTo: [String]
    /// `nil` dans les lignes écrites avant que l'origine existe : l'app était
    /// alors seule à nettoyer. Optionnelle pour que ces lignes se lisent encore.
    public var origin: CleanupOrigin?

    /// Vrai si un agent IA l'a nettoyé, par `oust`.
    public var isByAgent: Bool {
        if case .agent = origin { return true }
        return false
    }

    public init(sessionID: UUID, date: Date, item: CleanupItem, result: OutcomeResult,
                bytes: Int64, trashedTo: [String] = []) {
        self.sessionID = sessionID
        self.date = date
        self.itemID = item.id
        self.title = item.title
        self.owner = item.owner
        self.category = item.category
        self.method = item.method
        self.paths = item.paths.map(\.path)
        self.result = result
        self.bytes = bytes
        self.trashedTo = trashedTo
    }
}

/// Le bilan honnête d'un nettoyage (SPEC §6.2, étape 5).
public struct CleanupReport: Sendable, Hashable, Codable {
    public var sessionID: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var outcomes: [CleanupOutcome]
    /// Espace libre réel du volume avant et après, mesuré et non calculé.
    public var availableBefore: Int64?
    public var availableAfter: Int64?
    /// Compté comme libéré mais encore dans le dossier de transit au moment de
    /// mesurer : le volume le rendra une fois l'effacement fini.
    public var purging: Int64 = 0

    public init(sessionID: UUID, startedAt: Date, finishedAt: Date, outcomes: [CleanupOutcome],
                availableBefore: Int64?, availableAfter: Int64?) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcomes = outcomes
        self.availableBefore = availableBefore
        self.availableAfter = availableAfter
    }

    /// Ce qui devrait être rendu tout de suite (supprimé, délégué, cloné, évincé, compressé).
    ///
    /// Sans Docker ni OrbStack : ce qu'ils retirent se libère dans leur disque
    /// virtuel, que le Mac ne récupère qu'au compactage. Le compter ici ferait
    /// passer l'écart pour la part des snapshots.
    public var expectedNow: Int64 {
        outcomes.filter { [.removed, .delegated, .cloned, .evicted, .compressed].contains($0.result) && $0.category != .containers }
            .reduce(0) { $0 + $1.bytes }
    }

    /// Ce qui attend qu'on vide la corbeille.
    public var pendingInTrash: Int64 {
        outcomes.filter { $0.result == .trashed }.reduce(0) { $0 + $1.bytes }
    }

    /// Ce qui attend dans « Supprimés récemment » de Photos : rendu au bout de
    /// 30 jours, ou quand on le vide dans Photos. Ni maintenant, ni avec la
    /// corbeille du Mac : le compter avec l'une ou l'autre serait faux.
    public var pendingInPhotos: Int64 {
        outcomes.filter { $0.result == .recentlyDeleted }.reduce(0) { $0 + $1.bytes }
    }

    /// Ce que le volume a réellement rendu, d'après sa capacité.
    public var measuredNow: Int64? {
        guard let before = availableBefore, let after = availableAfter else { return nil }
        return max(0, after - before)
    }

    /// La part attendue mais pas encore rendue : en pratique, ce que retiennent
    /// les snapshots Time Machine locaux, ou ce qu'APFS n'a pas encore récupéré.
    public var heldBack: Int64 {
        guard let measured = measuredNow else { return 0 }
        return max(0, expectedNow - purging - measured)
    }

    public var succeeded: [CleanupOutcome] { outcomes.filter(\.result.succeeded) }
    public var skippedOrFailed: [CleanupOutcome] { outcomes.filter { !$0.result.succeeded } }
}

/// Ce que le nettoyage raconte au fil de l'eau, pour l'animation en direct.
public enum CleanupEvent: Sendable {
    case began(total: Int, expectedBytes: Int64)
    case itemBegan(id: String)
    /// Une phase sans identifiants concerne la session entière. Un lot est
    /// annoncé ensemble : aucun avancement par date n'est inventé pendant tmutil.
    case phaseChanged(CleanupPhase, itemIDs: [String])
    case itemFinished(CleanupOutcome)
    case finished(CleanupReport)
}

public enum CleanupPhase: Sendable, Equatable {
    case preparing, revalidating, checkingSnapshotComponent
    case deletingSnapshots(count: Int), authorizingSnapshots(count: Int), verifyingSnapshots
    case deleting, journaling, measuring

    /// Une journalisation brève ne doit pas masquer une suppression parallèle
    /// qui dure encore. Les phases snapshots sont séquentielles dans leur lot.
    var priority: Int {
        switch self {
        case .preparing: 0
        case .journaling: 1
        case .revalidating: 2
        case .deleting: 3
        case .checkingSnapshotComponent, .deletingSnapshots, .authorizingSnapshots, .verifyingSnapshots: 4
        case .measuring: 5
        }
    }
}

/// Compteurs d'éléments terminés, sans rapport avec un pourcentage d'octets.
/// Les durées utilisent l'horloge monotone : une correction de l'heure système
/// ne fait jamais reculer le temps affiché.
public struct CleanupProgress: Sendable {
    public private(set) var total = 0
    public private(set) var completed = 0
    public private(set) var phase: CleanupPhase = .preparing
    public private(set) var startedAt: ContinuousClock.Instant
    public private(set) var phaseStartedAt: ContinuousClock.Instant
    private var sessionPhase: CleanupPhase = .preparing
    private var activePhases: [String: CleanupPhase] = [:]
    private var completedIDs: Set<String> = []

    public init(total: Int = 0, now: ContinuousClock.Instant = .now) {
        self.total = total
        self.startedAt = now
        self.phaseStartedAt = now
    }

    public mutating func receive(_ event: CleanupEvent, now: ContinuousClock.Instant = .now) {
        switch event {
        case .began(let total, _): self.total = total
        case .phaseChanged(let phase, let ids):
            if ids.isEmpty { sessionPhase = phase }
            else { for id in ids where !completedIDs.contains(id) { activePhases[id] = phase } }
        case .itemBegan(let id): activePhases[id] = .revalidating
        case .itemFinished(let outcome):
            activePhases.removeValue(forKey: outcome.itemID)
            completedIDs.insert(outcome.itemID)
            completed = completedIDs.count
        case .finished: break
        }
        let next = activePhases.values.max(by: { $0.priority < $1.priority }) ?? sessionPhase
        if next != phase {
            phase = next
            phaseStartedAt = now
        }
    }

    public func elapsed(at now: ContinuousClock.Instant = .now) -> Duration { max(.zero, startedAt.duration(to: now)) }
    public func phaseElapsed(at now: ContinuousClock.Instant = .now) -> Duration { max(.zero, phaseStartedAt.duration(to: now)) }
}
