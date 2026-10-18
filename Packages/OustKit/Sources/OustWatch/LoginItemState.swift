import Foundation
import ServiceManagement

/// Oust! dans « Ouvrir à la connexion », tel que macOS le dit.
public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case disabled
    /// Inscrit, mais macOS attend que l'utilisateur l'autorise dans Réglages
    /// Système (éléments d'ouverture).
    case requiresApproval

    public var isOn: Bool { self == .enabled || self == .requiresApproval }

    /// Pour l'app elle-même, `.notFound` veut dire « jamais inscrite » : c'est ce
    /// que macOS répond tant qu'elle n'a pas été inscrite une première fois
    /// (« record not found » dans le journal de backgroundtaskmanagementd).
    ///
    /// Le 18/10/2026, `.notFound` se lisait « introuvable » et grisait
    /// l'interrupteur : `register()` n'était jamais appelé, et l'option n'avait
    /// jamais pu marcher, où que soit rangée l'app. Le journal le montrait : des
    /// dizaines de lectures du statut, pas une seule inscription.
    public init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered, .notFound: self = .disabled
        @unknown default: self = .disabled
        }
    }
}

/// Ce que macOS a refusé quand on a coché ou décoché l'ouverture à la connexion,
/// dit en une phrase sous l'interrupteur, avec quoi faire. Sans elle,
/// l'interrupteur revenait en arrière sans un mot.
public enum LoginItemNotice: Sendable, Equatable {
    /// Oust! est désactivé dans les éléments d'ouverture de Réglages Système.
    case deniedByUser
    /// La signature de cette copie d'Oust! ne convient pas à macOS.
    case invalidSignature
    /// `register()` n'a rien objecté, mais macOS n'a rien retenu.
    case notKept
    /// `unregister()` n'a rien objecté, mais macOS ouvre toujours Oust!.
    case notRemoved
    /// Un autre refus : le message de macOS, tel quel.
    case failed(String)

    /// Ce qu'il faut dire après avoir demandé `wanted`, au vu de l'erreur levée
    /// et du statut relu ensuite. `nil` quand macOS a fait ce qu'on demandait,
    /// ou qu'il attend l'accord de l'utilisateur : l'interface le dit déjà.
    public static func after(requesting wanted: Bool, error: (any Error)?,
                             status: LoginItemStatus) -> LoginItemNotice? {
        if let error, !isHarmless(error, wanted: wanted) {
            switch serviceManagementCode(error) {
            case kSMErrorLaunchDeniedByUser: return .deniedByUser
            case kSMErrorInvalidSignature: return .invalidSignature
            default: return .failed(error.localizedDescription)
            }
        }
        switch (wanted, status.isOn) {
        case (true, false): return .notKept
        case (false, true): return .notRemoved
        default: return nil
        }
    }

    /// Déjà inscrit quand on inscrit, déjà retiré quand on retire : macOS le
    /// signale comme une erreur, mais c'est l'état voulu. Le statut relu tranche.
    private static func isHarmless(_ error: any Error, wanted: Bool) -> Bool {
        switch serviceManagementCode(error) {
        case kSMErrorAlreadyRegistered: wanted
        case kSMErrorJobNotFound: !wanted
        default: false
        }
    }

    /// Le code `kSMError…`, seulement si l'erreur vient de ServiceManagement :
    /// ailleurs, le même nombre veut dire autre chose.
    private static func serviceManagementCode(_ error: any Error) -> Int? {
        let error = error as NSError
        return error.domain == SMAppServiceErrorDomain ? error.code : nil
    }
}

/// L'ouverture à la connexion vue par Oust! : ce que macOS dit, et la phrase à
/// montrer tant qu'il n'a pas fait ce qu'on lui a demandé.
public struct LoginItemState: Sendable, Equatable {
    public private(set) var status: LoginItemStatus
    public private(set) var notice: LoginItemNotice?
    /// Ce que l'utilisateur a demandé en dernier.
    private var wanted: Bool?

    public init(status: LoginItemStatus = .disabled) {
        self.status = status
    }

    /// Après `register()` ou `unregister()`, avec le statut relu juste après.
    public mutating func requested(_ wanted: Bool, error: (any Error)?, status: LoginItemStatus) {
        self.wanted = wanted
        self.status = status
        notice = LoginItemNotice.after(requesting: wanted, error: error, status: status)
    }

    /// Relu chez macOS (lancement, ouverture des Réglages). Si l'utilisateur a
    /// fait le nécessaire dans Réglages Système entre-temps, la phrase n'a plus
    /// lieu d'être.
    public mutating func refreshed(_ status: LoginItemStatus) {
        self.status = status
        if let wanted, status.isOn == wanted {
            notice = nil
        }
    }
}
