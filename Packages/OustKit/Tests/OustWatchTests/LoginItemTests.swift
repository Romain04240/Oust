import Foundation
import ServiceManagement
import Testing
@testable import OustWatch

// MARK: - Statut

@Suite("Ouverture à la connexion : ce que dit macOS")
struct LoginItemStatusTests {
    @Test("Jamais inscrite, l'app est « non trouvée » : on peut l'inscrire")
    func notFoundMeansNeverRegistered() {
        // Le 18/10/2026 : `.notFound` grisait l'interrupteur, et `register()`
        // n'était jamais appelé.
        #expect(LoginItemStatus(.notFound) == .disabled)
        #expect(LoginItemStatus(.notRegistered) == .disabled)
        #expect(!LoginItemStatus(.notFound).isOn)
    }

    @Test("Inscrite, ou en attente d'accord : l'interrupteur est coché")
    func onStates() {
        #expect(LoginItemStatus(.enabled) == .enabled)
        #expect(LoginItemStatus(.requiresApproval) == .requiresApproval)
        #expect(LoginItemStatus(.enabled).isOn)
        #expect(LoginItemStatus(.requiresApproval).isOn)
    }
}

// MARK: - Phrase

@Suite("Ouverture à la connexion : ce que macOS a refusé")
struct LoginItemNoticeTests {
    func smError(_ code: Int) -> NSError {
        NSError(domain: SMAppServiceErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: "Opération refusée."])
    }

    @Test("macOS a fait ce qu'on demandait : rien à dire")
    func success() {
        #expect(LoginItemNotice.after(requesting: true, error: nil, status: .enabled) == nil)
        #expect(LoginItemNotice.after(requesting: false, error: nil, status: .disabled) == nil)
    }

    @Test("En attente d'accord : la rangée d'accord le dit déjà, pas de seconde phrase")
    func approvalIsNotANotice() {
        #expect(LoginItemNotice.after(requesting: true, error: nil, status: .requiresApproval) == nil)
    }

    @Test("Aucune erreur, mais rien de retenu : on le dit au lieu de décocher en silence")
    func silentRefusal() {
        #expect(LoginItemNotice.after(requesting: true, error: nil, status: .disabled) == .notKept)
        #expect(LoginItemNotice.after(requesting: false, error: nil, status: .enabled) == .notRemoved)
    }

    @Test("Refusé dans Réglages Système, ou signature refusée : une phrase à chaque cas")
    func knownRefusals() {
        #expect(LoginItemNotice.after(requesting: true, error: smError(kSMErrorLaunchDeniedByUser),
                                      status: .disabled) == .deniedByUser)
        #expect(LoginItemNotice.after(requesting: true, error: smError(kSMErrorInvalidSignature),
                                      status: .disabled) == .invalidSignature)
    }

    @Test("Un autre refus : le message de macOS, tel quel")
    func otherRefusal() {
        #expect(LoginItemNotice.after(requesting: true, error: smError(kSMErrorInternalFailure),
                                      status: .disabled) == .failed("Opération refusée."))
    }

    @Test("Déjà inscrit, déjà retiré : pas une erreur, le statut tranche")
    func alreadyThere() {
        #expect(LoginItemNotice.after(requesting: true, error: smError(kSMErrorAlreadyRegistered),
                                      status: .enabled) == nil)
        #expect(LoginItemNotice.after(requesting: false, error: smError(kSMErrorJobNotFound),
                                      status: .disabled) == nil)
        // Déjà inscrit d'après macOS, mais pas coché à la relecture : on le dit.
        #expect(LoginItemNotice.after(requesting: true, error: smError(kSMErrorAlreadyRegistered),
                                      status: .disabled) == .notKept)
    }

    @Test("Le même code venu d'ailleurs ne passe pas pour un refus de l'utilisateur")
    func foreignDomain() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: kSMErrorLaunchDeniedByUser,
                            userInfo: [NSLocalizedDescriptionKey: "Ressource indisponible."])
        #expect(LoginItemNotice.after(requesting: true, error: posix, status: .disabled)
                == .failed("Ressource indisponible."))
    }
}

// MARK: - État

@Suite("Ouverture à la connexion : la phrase reste tant que rien n'est réglé")
struct LoginItemStateTests {
    @Test("Refusé, puis réglé dans Réglages Système : la phrase part à la relecture")
    func fixedElsewhere() {
        var state = LoginItemState()
        state.requested(true, error: nil, status: .disabled)
        #expect(state.notice == .notKept)
        #expect(!state.status.isOn)

        state.refreshed(.disabled)
        #expect(state.notice == .notKept, "Rien n'a changé : la phrase reste")

        state.refreshed(.enabled)
        #expect(state.notice == nil)
        #expect(state.status == .enabled)
    }

    @Test("Réussi du premier coup : ni phrase, ni phrase plus tard")
    func success() {
        var state = LoginItemState()
        state.requested(true, error: nil, status: .enabled)
        #expect(state.notice == nil)
        state.refreshed(.enabled)
        #expect(state.notice == nil)
    }

    @Test("Une relecture sans demande préalable ne fabrique pas de phrase")
    func refreshAlone() {
        var state = LoginItemState()
        state.refreshed(.enabled)
        #expect(state.notice == nil)
        #expect(state.status == .enabled)
    }
}
