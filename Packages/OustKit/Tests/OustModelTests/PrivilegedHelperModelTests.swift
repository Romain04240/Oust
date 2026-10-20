import Foundation
import Testing
@testable import OustModel
import OustVolume

@Suite("Composant privilégié : installation et réparation")
@MainActor
struct PrivilegedHelperModelTests {
    @Test("Un retrait refusé arrête la réparation et conserve le refus")
    func failedUninstallStopsRepair() async {
        let fixture = Fixture()
        fixture.registration = .enabled
        fixture.uninstallError = NSError(domain: "test", code: 42)
        let model = PrivilegedHelperModel(operations: fixture.operations)
        await model.reinstall()
        #expect(fixture.uninstalls == 1)
        #expect(fixture.installs == 0)
        #expect(model.failure != nil)
        #expect(model.state == .unresponsive)
        #expect(!model.isBusy)
    }

    @Test("Une réparation attend le retrait puis relit la réponse effective")
    func repairedServiceAnswers() async {
        let fixture = Fixture()
        fixture.registration = .enabled
        fixture.version = "1.2.3"
        let model = PrivilegedHelperModel(operations: fixture.operations)
        await model.reinstall()
        #expect(fixture.events == ["uninstall", "install", "version"])
        #expect(model.state == .active(version: "1.2.3"))
        #expect(model.failure == nil)
    }

    @Test("Un paquet incomplet ne modifie pas le service")
    func incompleteBundleDoesNotInstall() async {
        let fixture = Fixture()
        fixture.issue = "helper.diagnostic.incomplete_bundle"
        let model = PrivilegedHelperModel(operations: fixture.operations)
        await model.install()
        await model.reinstall()
        #expect(fixture.installs == 0)
        #expect(fixture.uninstalls == 0)
        #expect(model.installationIssue == fixture.issue)
    }

    @Test("Une installation en attente ouvre les Réglages sans inventer une réponse active")
    func pendingApproval() async {
        let fixture = Fixture()
        fixture.afterInstall = .awaitingApproval
        let model = PrivilegedHelperModel(operations: fixture.operations)
        await model.install()
        #expect(model.state == .awaitingApproval)
        #expect(fixture.settingsOpened == 1)
        #expect(!fixture.events.contains("version"))
    }

    @Test("Une vérification en cours empêche une réparation concurrente")
    func checkingPreventsConcurrentRepair() async {
        let fixture = Fixture()
        fixture.registration = .enabled
        let gate = VersionGate()
        var operations = fixture.operations
        operations.version = { await gate.read() }
        let model = PrivilegedHelperModel(operations: operations)
        let checking = Task { await model.refresh() }
        while !gate.started { await Task.yield() }
        #expect(model.isChecking)
        await model.reinstall()
        #expect(fixture.installs == 0)
        #expect(fixture.uninstalls == 0)
        gate.finish()
        await checking.value
        #expect(!model.isBusy)
        #expect(model.state == .active(version: "test"))
    }
}

@MainActor
private final class Fixture {
    var registration: PrivilegedHelper.Registration = .notInstalled
    var afterInstall: PrivilegedHelper.Registration = .enabled
    var issue: String?
    var version: String?
    var uninstallError: (any Error)?
    var installs = 0
    var uninstalls = 0
    var settingsOpened = 0
    var events: [String] = []

    var operations: PrivilegedHelperModel.Operations {
        .init(registration: { self.registration }, issue: { self.issue }, version: {
            self.events.append("version")
            return self.version
        }, install: {
            self.events.append("install")
            self.installs += 1
            self.registration = self.afterInstall
        }, uninstall: {
            self.events.append("uninstall")
            self.uninstalls += 1
            if let error = self.uninstallError { throw error }
            self.registration = .notInstalled
        }, openSettings: { self.settingsOpened += 1 })
    }
}

@MainActor
private final class VersionGate {
    var started = false
    private var continuation: CheckedContinuation<String?, Never>?
    func read() async -> String? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: "test") }
}
