import Foundation
import OustCore
import OustDesignSystem
import OustLocalization
import OustRules

// MARK: - Le JSON des agents
//
// Ce qui suit est un contrat : les noms de champs et les valeurs de `kind`,
// `safety`, `verdict` et `result` ne changent pas sans changer le numéro de
// `schema` (README, « Pour les agents IA »). Les champs `label` et `message`,
// eux, sont des phrases localisées, à montrer et jamais à comparer.

/// Un élément trouvé, tel qu'un agent le reçoit.
public struct ItemReport: Codable, Sendable, Hashable {
    /// À repasser tel quel à `explain` et `clean`.
    public var id: String
    public var title: String
    public var detail: String?
    public var rule: String
    public var ruleTitle: String
    public var category: String
    public var owner: String
    public var paths: [String]
    /// `safe`, `rebuilds`, `review`, `protected`, `inaccessible`.
    public var safety: String
    public var safetyLabel: String
    public var method: MethodReport
    public var sizes: SizesReport
    public var rebuild: RebuildReport
    public var protections: [ReasonReport]
    public var notes: [ReasonReport]
    public var lastActivity: Date?
    /// Ce que l'app cocherait d'office (sûr, ou reconstruit et intact depuis une semaine).
    public var preselected: Bool
    /// Ce qu'un agent a le droit d'en faire.
    public var agent: VerdictReport

    init(_ item: CleanupItem, preselected: Bool, verdict: AgentVerdict) {
        id = item.id
        title = item.title
        detail = item.detail
        rule = item.ruleID
        ruleTitle = Describe.ruleTitle(item.ruleID)
        category = item.category.rawValue
        owner = item.owner
        paths = item.paths.map(\.path)
        safety = Keys.suffix(of: item.safety.localizationKey)
        safetyLabel = L10n.string(item.safety.localizationKey)
        method = MethodReport(item.method)
        sizes = SizesReport(item.sizes)
        rebuild = RebuildReport(item.rebuild)
        protections = item.protections.map { ReasonReport(kind: Keys.suffix(of: $0.localizationKey), argument: $0.argument,
                                                           label: Describe.protection($0)) }
        notes = item.notes.map { ReasonReport(kind: Keys.suffix(of: $0.localizationKey), argument: $0.argument,
                                              label: Describe.note($0)) }
        lastActivity = item.lastActivity
        self.preselected = preselected
        agent = VerdictReport(verdict)
    }
}

public struct MethodReport: Codable, Sendable, Hashable {
    /// `removeNow`, `trash`, `gitWorktreeRemove`, `simulatorDevice`… (SPEC §6.1).
    public var kind: String
    /// `immediate`, `macTrash`, `tool`, `keepsFiles`, `manual`.
    public var family: String
    public var label: String
    /// Faux pour la corbeille du Mac : l'espace revient quand on la vide.
    public var freesImmediately: Bool
    public var requiresAdministrator: Bool

    init(_ method: CleanupMethod) {
        kind = Keys.suffix(of: method.localizationKey)
        family = method.family.rawValue
        label = Describe.method(method)
        freesImmediately = method.freesImmediately
        requiresAdministrator = AgentPolicy.refusal(for: method) == .administrator
    }
}

public struct SizesReport: Codable, Sendable, Hashable {
    public var allocatedBytes: Int64
    /// Ce que le nettoyage rend vraiment (RULES.md, règle 9).
    public var freeableBytes: Int64
    /// Partagé avec un clone ou un snapshot : reste sur le disque.
    public var retainedBytes: Int64

    init(_ sizes: Sizes) {
        allocatedBytes = sizes.allocated
        freeableBytes = sizes.freeable
        retainedBytes = sizes.retained
    }
}

public struct RebuildReport: Codable, Sendable, Hashable {
    /// `nothing`, `automatic`, `command`, `download`, `irreversible`, `photosRecentlyDeleted`, `cloudTrash`.
    public var kind: String
    public var command: String?
    public var minutes: Int?
    public var label: String

    init(_ cost: RebuildCost) {
        switch cost {
        case .nothing: kind = "nothing"
        case .automatic: kind = "automatic"
        case .command(let text, let minutes):
            kind = "command"
            command = text
            self.minutes = minutes
        case .download: kind = "download"
        case .irreversible: kind = "irreversible"
        case .photosRecentlyDeleted: kind = "photosRecentlyDeleted"
        case .cloudTrash: kind = "cloudTrash"
        }
        label = Describe.rebuild(cost)
    }
}

public struct ReasonReport: Codable, Sendable, Hashable {
    public var kind: String
    public var argument: String?
    public var label: String
}

public struct VerdictReport: Codable, Sendable, Hashable {
    /// `allowed`, `needsAllowReview`, `refused`.
    public var verdict: String
    /// Pour `refused` : `protected`, `inaccessible`, `manualOnly`, `administrator`, `notForAgents`.
    public var reason: String?
    public var label: String

    init(_ verdict: AgentVerdict) {
        self.verdict = verdict.code
        switch verdict {
        case .allowed:
            label = L10n.string("agent.verdict.allowed")
        case .needsReviewFlag:
            label = L10n.string("agent.verdict.needsAllowReview")
        case .refused(let refusal):
            reason = refusal.rawValue
            label = L10n.string(refusal.localizationKey)
        }
    }
}

// MARK: - Analyse

public struct ScanReport: Codable, Sendable, Hashable {
    public var schema = "oust.scan/1"
    /// À repasser à `clean` ; `nil` si l'aperçu n'a pas pu être gardé (voir `warnings`).
    public var token: String?
    public var generatedAt: Date
    /// Après, le jeton ne permet plus de nettoyer : il faut analyser de nouveau.
    public var expiresAt: Date?
    public var scope: ScopeReport
    public var totals: ScanTotals
    /// Vrai quand `limit` a coupé la liste : le jeton ne couvre que ce qui est montré.
    public var truncated: Bool
    public var items: [ItemReport]
    public var warnings: [String]
}

public struct ScopeReport: Codable, Sendable, Hashable {
    public var finders: [String]
    /// Vide : tout ce que les chercheurs couvrent.
    public var paths: [String]
}

public struct ScanTotals: Codable, Sendable, Hashable {
    /// Tout ce qui a été trouvé, montré ou non.
    public var items: Int
    public var shown: Int
    /// Ce que l'app annoncerait en titre : sélectionnable, hors VM et images Docker.
    public var freeableBytes: Int64
    /// Ce qu'un agent peut nettoyer sans drapeau.
    public var allowedBytes: Int64
    /// Ce qui demande `allowReview` en plus.
    public var needsAllowReviewBytes: Int64
}

// MARK: - Explication

public struct ExplainReport: Codable, Sendable, Hashable {
    public var schema = "oust.explain/1"
    public var id: String
    public var rule: String
    public var title: String
    /// Ce que c'est.
    public var what: String
    /// Comment ça revient.
    public var back: String
    /// Ce qu'Oust! en fera ; `nil` sans aperçu récent de l'élément.
    public var method: String?
    /// Pourquoi c'est protégé.
    public var protections: [String]
    /// L'élément tel que le dernier aperçu l'a montré.
    public var item: ItemReport?
}

// MARK: - Nettoyage

public struct CleanReport: Codable, Sendable, Hashable {
    public var schema = "oust.clean/1"
    public var dryRun: Bool
    public var token: String
    public var startedAt: Date
    public var finishedAt: Date
    public var outcomes: [OutcomeReport]
    public var totals: CleanTotals
}

public struct OutcomeReport: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var paths: [String]
    /// `removed`, `trashed`, `delegated`, `cloned`, `evicted`, `compressed`,
    /// `skipped`, `failed` ; `wouldClean` à blanc.
    public var result: String
    /// Pour `skipped` : `vanished`, `changedSinceScan`, `nowProtected`, `refusedByGuard`, `cancelled`.
    public var reason: String?
    public var label: String
    public var bytes: Int64
    /// Où chaque chemin a atterri dans la corbeille du Mac.
    public var trashedTo: [String]

    init(_ outcome: CleanupOutcome) {
        id = outcome.itemID
        title = outcome.title
        paths = outcome.paths
        label = Describe.outcome(outcome.result)
        bytes = outcome.bytes
        trashedTo = outcome.trashedTo
        switch outcome.result {
        case .removed: result = "removed"
        case .trashed: result = "trashed"
        case .delegated: result = "delegated"
        case .cloned: result = "cloned"
        case .evicted: result = "evicted"
        case .compressed: result = "compressed"
        case .recentlyDeleted: result = "recentlyDeleted"
        case .skipped(let skip):
            result = "skipped"
            reason = Keys.suffix(of: skip.localizationKey)
        case .failed: result = "failed"
        }
    }

    /// À blanc : ce que le nettoyage ferait.
    init(wouldClean item: ItemReport) {
        id = item.id
        title = item.title
        paths = item.paths
        result = "wouldClean"
        label = item.method.label
        bytes = item.sizes.freeableBytes
        trashedTo = []
    }

    /// Disparu entre l'aperçu et le nettoyage : rien n'a été fait.
    init(vanished item: ItemReport) {
        id = item.id
        title = item.title
        paths = item.paths
        result = "skipped"
        reason = Keys.suffix(of: SkipReason.vanished.localizationKey)
        label = Describe.skip(.vanished)
        bytes = 0
        trashedTo = []
    }

    public var succeeded: Bool {
        ["removed", "trashed", "delegated", "cloned", "evicted", "compressed", "wouldClean"].contains(result)
    }
}

public struct CleanTotals: Codable, Sendable, Hashable {
    public var requested: Int
    public var succeeded: Int
    public var skipped: Int
    public var failed: Int
    /// Rendu tout de suite (supprimé, confié à l'outil…), ou qui le serait à blanc.
    public var freedNowBytes: Int64
    /// Dans la corbeille du Mac : rendu quand on la vide.
    public var pendingInTrashBytes: Int64
    /// Ce que le volume a réellement rendu, mesuré avant et après.
    public var measuredFreedBytes: Int64?
    /// Attendu mais pas encore rendu : en pratique, retenu par les snapshots.
    public var heldBackBytes: Int64
}

// MARK: - Erreurs

public struct ErrorReport: Codable, Sendable, Hashable {
    public var schema = "oust.error/1"
    public var error: Body

    public struct Body: Codable, Sendable, Hashable {
        /// Identifiant stable (voir `AgentError.code`).
        public var code: String
        public var message: String
        public var exitCode: Int32
        /// Les éléments en cause, s'il y en a.
        public var items: [ErrorItem]
    }

    public struct ErrorItem: Codable, Sendable, Hashable {
        public var id: String
        public var reason: String?
        public var label: String?
    }

    init(_ error: AgentError) {
        self.error = Body(code: error.code, message: error.message, exitCode: error.exitCode.rawValue,
                          items: error.items)
    }
}

enum Keys {
    /// `method.removeNow` → `removeNow` : la clé du catalogue sert d'identifiant.
    static func suffix(of key: String) -> String {
        key.split(separator: ".", maxSplits: 1).last.map(String.init) ?? key
    }
}

extension JSONEncoder {
    /// Le même encodage partout : clés triées, dates ISO 8601, barres obliques telles quelles.
    static func agent(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static func agent() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
