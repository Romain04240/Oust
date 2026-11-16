import OustCore

/// Ce qu'un agent peut nettoyer, et ce qu'il ne peut pas.
///
/// Plus étroit que ce que l'app permet à la main : un agent ne voit pas
/// l'interface, ne coche rien du regard, et ne tape pas de mot de passe.
public enum AgentVerdict: Sendable, Hashable {
    /// « Sûr » ou « se reconstruit » : nettoyable sur simple demande.
    case allowed
    /// « À examiner » : seulement avec `--allow-review` (`allowReview` en MCP).
    case needsReviewFlag
    case refused(AgentRefusal)

    /// Identifiant stable du JSON.
    public var code: String {
        switch self {
        case .allowed: "allowed"
        case .needsReviewFlag: "needsAllowReview"
        case .refused: "refused"
        }
    }
}

public enum AgentRefusal: String, Sendable, Hashable, Codable, CaseIterable {
    /// Protégé par Oust! (processus, git, application ouverte…) : jamais.
    case protected
    /// Illisible sans l'Accès complet au disque.
    case inaccessible
    /// Montré pour information, à faire soi-même (`Docker.raw`).
    case manualOnly
    /// Demanderait un mot de passe administrateur (snapshots Time Machine).
    case administrator
    /// Un parcours de l'app, qui ne se délègue pas (archivage vérifié).
    case notForAgents
    case unavailable

    public var localizationKey: String { "agent.refusal.\(rawValue)" }
}

public enum AgentPolicy {

    public static func verdict(for item: CleanupItem) -> AgentVerdict {
        if let refusal = refusal(for: item.method) { return .refused(refusal) }
        switch item.safety {
        case .protected: return .refused(.protected)
        case .inaccessible: return .refused(.inaccessible)
        case .review: return item.isSelectable ? .needsReviewFlag : .refused(.protected)
        case .safe, .rebuilds: return item.isSelectable ? .allowed : .refused(.protected)
        }
    }

    /// Vrai si l'agent peut nettoyer l'élément avec ce qu'il a demandé.
    public static func allows(_ item: CleanupItem, allowReview: Bool) -> Bool {
        switch verdict(for: item) {
        case .allowed: true
        case .needsReviewFlag: allowReview
        case .refused: false
        }
    }

    /// Les méthodes qu'un agent ne déclenche jamais.
    ///
    /// Sans `default`, à dessein : une méthode ajoutée au domaine ne compile pas
    /// ici tant qu'on n'a pas décidé si un agent peut s'en servir.
    public static func refusal(for method: CleanupMethod) -> AgentRefusal? {
        switch method {
        case .localSnapshot: .administrator
        // Une sauvegarde Time Machine ne se rattrape pas : Romain la choisit
        // lui-même dans le panneau du disque, jamais un agent.
        case .timeMachineBackup: .notForAgents
        case .manual: .manualOnly
        case .gitWorktreeRemove: .unavailable
        case .archive: .notForAgents
        // Une photo est du contenu personnel, et Photos demande lui-même
        // confirmation dans son invite : un agent ne la déclenche jamais.
        case .photoAsset: .notForAgents
        // Supprimé aussi dans le nuage et sur les autres appareils de
        // l'utilisateur : ce choix-là reste le sien.
        case .trashFromCloud: .notForAgents
        case .removeNow, .trash, .simulatorDevice, .simulatorRuntime, .firefoxHistory,
             .cloneOf, .evictLocalCopy, .compressInPlace, .uninstallVersion, .brewCleanup, .containerPrune:
            nil
        }
    }
}
