import Foundation
import Observation
import OustVolume

/// Le démon privilégié, vu des Réglages (docs/adr/0001).
///
/// Un état à part, et non une propriété d'`AppModel` : personne d'autre que
/// les Réglages n'a besoin de le connaître. Le nettoyage, lui, demande à
/// `VolumeService` au moment d'agir, qui interroge le système à cet instant.
@MainActor
@Observable
public final class PrivilegedHelperModel {

    public enum State: Equatable, Sendable {
        case notInstalled
        /// Enregistré, en attente d'activation dans Réglages Système › Ouverture.
        case awaitingApproval
        /// Approuvé, et il a répondu.
        case active(version: String)
        /// Approuvé, mais il ne répond pas : l'invite administrateur reste le
        /// chemin. Typiquement, l'app a été remplacée et doit le réinstaller.
        case unresponsive
    }

    public private(set) var state: State = .notInstalled
    /// Le dernier refus de macOS, tel qu'il l'a formulé.
    public private(set) var failure: String?
    public private(set) var isWorking = false

    /// Une copie de développement : macOS peut refuser d'en enregistrer le
    /// démon (il exige une app notarisée).
    public var isDevelopmentBuild: Bool { !PrivilegedHelper.isDeveloperIDSigned }

    public var isInstalled: Bool { state != .notInstalled }

    public init() {}

    public func refresh() async {
        switch PrivilegedHelper.registration {
        case .notInstalled:
            state = .notInstalled
        case .awaitingApproval:
            state = .awaitingApproval
        case .enabled:
            if let status = await PrivilegedHelper.status() {
                state = .active(version: status.helperVersion)
                failure = nil
            } else {
                state = .unresponsive
            }
        }
    }

    /// Enregistre le démon, puis ouvre le volet où l'activer.
    public func install() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try PrivilegedHelper.install()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        await refresh()
        if state == .awaitingApproval { PrivilegedHelper.openSystemSettings() }
    }

    public func uninstall() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await PrivilegedHelper.uninstall()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        await refresh()
    }

    /// Un démon qui ne répond plus après une mise à jour se réenregistre :
    /// Apple recommande de le retirer avant, quand l'exécutable a changé.
    public func reinstall() async {
        isWorking = true
        defer { isWorking = false }
        try? await PrivilegedHelper.uninstall()
        do {
            try PrivilegedHelper.install()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        await refresh()
        if state == .awaitingApproval { PrivilegedHelper.openSystemSettings() }
    }

    public func openSystemSettings() {
        PrivilegedHelper.openSystemSettings()
    }
}
