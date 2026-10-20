import Foundation
import Observation
import OustVolume
import OustLocalization

/// État local des écrans Time Machine et Réglages. Le nettoyage consulte
/// toujours le système au moment d'agir, sans se fier à cet affichage.
@MainActor
@Observable
public final class PrivilegedHelperModel {
    public enum State: Equatable, Sendable {
        case notInstalled
        case awaitingApproval
        case active(version: String)
        case unresponsive
    }

    public private(set) var state: State = .notInstalled
    public private(set) var failure: String?
    public private(set) var installationIssue: String?
    public private(set) var isWorking = false
    public private(set) var isChecking = false
    public var isBusy: Bool { isWorking || isChecking }
    public var isDevelopmentBuild: Bool { !PrivilegedHelper.isDeveloperIDSigned }
    public var needsStableLocation: Bool { !PrivilegedHelper.isInApplications }
    public var isInstalled: Bool { state != .notInstalled }
    public var updateNotice: String? {
        switch PrivilegedHelper.updateState {
        case .deferred: "helper.update_deferred"
        case .none: nil
        }
    }

    @ObservationIgnored private let operations: Operations

    /// Les tests remplacent uniquement le gestionnaire d'installation : aucun
    /// service système n'est enregistré pour vérifier les échecs et les courses.
    @MainActor struct Operations {
        var registration: () -> PrivilegedHelper.Registration
        var issue: () -> String?
        var version: () async -> String?
        var install: () throws -> Void
        var uninstall: () async throws -> Void
        var openSettings: () -> Void
        var repair: (() async throws -> Void)? = nil

        static let system = Operations(
            registration: { PrivilegedHelper.registration },
            issue: { PrivilegedHelper.installationIssue?.rawValue },
            version: { await PrivilegedHelper.status()?.helperVersion },
            install: { try PrivilegedHelper.install() },
            uninstall: { try await PrivilegedHelper.uninstall() },
            openSettings: { PrivilegedHelper.openSystemSettings() },
            repair: { try await PrivilegedHelper.reinstall() })
    }

    public convenience init() { self.init(operations: .system) }
    init(operations: Operations) { self.operations = operations }

    public func refresh() async {
        guard !isBusy else { return }
        isChecking = true
        defer { isChecking = false }
        await readState()
    }

    private func readState() async {
        installationIssue = operations.issue()
        switch operations.registration() {
        case .notInstalled: state = .notInstalled
        case .awaitingApproval: state = .awaitingApproval
        case .enabled:
            if let version = await operations.version() {
                state = .active(version: version)
                failure = nil
            } else {
                state = .unresponsive
            }
        }
    }

    public func install() async {
        guard !isBusy else { return }
        isWorking = true
        defer { isWorking = false }
        installationIssue = operations.issue()
        guard installationIssue == nil else { return }
        do {
            try operations.install()
            failure = nil
        } catch { recordFailure(error) }
        await readState()
        if state == .awaitingApproval { operations.openSettings() }
    }

    public func uninstall() async {
        guard !isBusy else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await operations.uninstall()
            failure = nil
        } catch { recordFailure(error) }
        await readState()
    }

    /// Ne pas masquer un échec de retrait : enregistrer quand même pouvait
    /// conserver le mauvais chemin et annoncer une réparation sans effet.
    public func reinstall() async {
        guard !isBusy else { return }
        isWorking = true
        defer { isWorking = false }
        installationIssue = operations.issue()
        guard installationIssue == nil else { return }
        do {
            if let repair = operations.repair {
                try await repair()
            } else {
                try await operations.uninstall()
                try operations.install()
            }
            failure = nil
        } catch { recordFailure(error) }
        await readState()
        if state == .awaitingApproval { operations.openSettings() }
    }

    public func openSystemSettings() { operations.openSettings() }

    private func recordFailure(_ error: any Error) {
        if error is PrivilegedHelper.LifecycleError {
            failure = L10n.string("helper.operation_busy")
        } else {
            failure = error.localizedDescription
        }
    }
}
