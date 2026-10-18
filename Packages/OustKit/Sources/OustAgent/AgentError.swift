import Foundation
import OustLocalization
import OustRules

/// Les codes de sortie de `oust`, stables et documentés (README).
public enum AgentExitCode: Int32, Sendable, CaseIterable {
    case success = 0
    /// Une erreur inattendue, ou le journal impossible à écrire.
    case failure = 1
    /// Commande, option ou valeur inconnue.
    case usage = 2
    /// Un identifiant que l'aperçu ne connaît pas.
    case notFound = 3
    /// Un élément qu'un agent n'a pas le droit de nettoyer : rien n'a été fait.
    case refused = 4
    /// Le nettoyage a eu lieu, mais un élément au moins a été laissé ou a échoué.
    case incomplete = 5
    /// Pas d'aperçu valable : analyser d'abord (ou de nouveau).
    case previewRequired = 6
}

/// Pourquoi une demande n'a pas abouti. Rien n'est jamais à moitié fait :
/// tant qu'une de ces erreurs est levée, aucun élément n'a été touché.
public enum AgentError: Error, Sendable, Hashable {
    case usage(String)
    case unknownFinder(String)
    case pathNotFound(String)
    /// Aucun aperçu récent ne couvre tous ces éléments.
    case previewRequired
    /// Le jeton est inconnu ou périmé.
    case tokenExpired
    case unknownItems([String])
    /// Leur classe, leur méthode ou leurs chemins ont changé depuis l'aperçu.
    case changedSincePreview([String])
    case refused([Refusal])
    /// Le journal d'Oust! ne peut pas être écrit : on ne nettoie pas sans trace.
    case journalUnavailable(String)
    /// L'inattendu, avec le message du système.
    case failure(String)

    public struct Refusal: Sendable, Hashable {
        public var id: String
        /// `needsAllowReview`, ou une raison de `AgentRefusal`.
        public var reason: String
        public var label: String
    }

    /// Identifiant stable du JSON.
    public var code: String {
        switch self {
        case .usage: "usage"
        case .unknownFinder: "unknownFinder"
        case .pathNotFound: "pathNotFound"
        case .previewRequired: "previewRequired"
        case .tokenExpired: "tokenExpired"
        case .unknownItems: "unknownItems"
        case .changedSincePreview: "changedSincePreview"
        case .refused: "refused"
        case .journalUnavailable: "journalUnavailable"
        case .failure: "failure"
        }
    }

    public var exitCode: AgentExitCode {
        switch self {
        case .usage, .unknownFinder, .pathNotFound: .usage
        case .unknownItems: .notFound
        case .refused: .refused
        case .previewRequired, .tokenExpired, .changedSincePreview: .previewRequired
        case .journalUnavailable, .failure: .failure
        }
    }

    public var message: String {
        switch self {
        case .usage(let message): message
        case .unknownFinder(let name):
            L10n.string("agent.error.unknownFinder", name, FinderKind.names)
        case .pathNotFound(let path): L10n.string("agent.error.pathNotFound", path)
        case .previewRequired: L10n.string("agent.error.previewRequired")
        case .tokenExpired: L10n.string("agent.error.tokenExpired")
        case .unknownItems(let ids): L10n.string("agent.error.unknownItems", ids.joined(separator: ", "))
        case .changedSincePreview(let ids): L10n.string("agent.error.changedSincePreview", ids.joined(separator: ", "))
        case .refused(let refusals):
            L10n.string("agent.error.refused", refusals.map { "\($0.id) (\($0.label))" }.joined(separator: ", "))
        case .journalUnavailable(let reason): L10n.string("agent.error.journalUnavailable", reason)
        case .failure(let reason): L10n.string("agent.error.failure", reason)
        }
    }

    var items: [ErrorReport.ErrorItem] {
        switch self {
        case .unknownItems(let ids), .changedSincePreview(let ids):
            ids.map { ErrorReport.ErrorItem(id: $0) }
        case .refused(let refusals):
            refusals.map { ErrorReport.ErrorItem(id: $0.id, reason: $0.reason, label: $0.label) }
        default:
            []
        }
    }
}

extension FinderKind {
    /// Les noms acceptés par `--finders`, pour les messages.
    static var names: String { homeCases.map(\.rawValue).joined(separator: ", ") }
}
