import Foundation
import ObjectiveC
import Security
import Synchronization
import Testing
import OustHelperContract
@testable import OustHelperDaemon
@testable import OustVolume

/// Sans root ni démon installé : un écouteur XPC anonyme, dans le processus
/// de test, porte le vrai `HelperService`. La vérification de signature y est
/// faite par le système, comme pour le démon.
///
/// Le processus de test n'est pas Oust! : il n'est pas signé par l'équipe sous
/// `fr.meaillais.oust`. Il joue donc l'appelant étranger que le démon doit
/// refuser. Pour vérifier que le refus vient bien de la signature et non d'un
/// XPC en panne, chaque refus a son témoin : le même échange, avec une
/// exigence que ce processus satisfait (sa propre exigence désignée).
@Suite("Démon : signatures et verbes", .serialized)
struct HelperSecurityTests {

    // MARK: Verbes

    @Test("Le protocole ne compte que trois verbes : snapshots, sauvegardes Time Machine, version")
    func protocolSurface() {
        func selectors(required: Bool) -> Set<String> {
            var count: UInt32 = 0
            guard let list = protocol_copyMethodDescriptionList(OustHelperProtocol.self, required, true, &count)
            else { return [] }
            defer { free(list) }
            return Set((0..<Int(count)).compactMap { list[$0].name.map(NSStringFromSelector) })
        }
        #expect(selectors(required: true) == ["deleteLocalSnapshots:contractVersion:withReply:",
                                              "deleteBackups:destination:contractVersion:withReply:",
                                              "readStatusWithReply:"])
        #expect(selectors(required: false).isEmpty)
    }

    @Test("Un verbe inconnu n'est jamais exécuté")
    func unknownVerbIsRefused() async throws {
        let ownRequirement = try #require(Self.ownRequirement())
        let tool = FakeSnapshotTool(listed: HelperServiceTests.listing)
        let host = Host(service: HelperService(tool: tool, clientRequirement: ownRequirement))

        let connection = NSXPCConnection(listenerEndpoint: host.listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: ProbeProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let answered = await Self.within(seconds: 3) { done in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done(false) } as? any ProbeProtocol
            proxy?.runCommand("/usr/bin/tmutil deletelocalsnapshots /") { _ in done(true) }
        }
        #expect(answered != true)
        #expect(tool.deletions.isEmpty)
        #expect(tool.listings == 0)
    }

    // MARK: Sauvegardes Time Machine

    @Test("Témoin : avec une exigence satisfaite, les sauvegardes passent par XPC")
    func backupsOverXPC() async throws {
        let ownRequirement = try #require(Self.ownRequirement())
        let backups = FakeBackupTool(listed: BackupServiceTests.listed)
        let host = Host(service: HelperService(tool: FakeSnapshotTool(listed: []), backups: backups,
                                               clientRequirement: ownRequirement))
        let call = await PrivilegedHelper.deleteBackups(
            ["2025-03-03-101530", "2026-10-18-083015"], destination: TimeMachineFixtures.mountPoint,
            transport: host.transport(daemonRequirement: ownRequirement), timeout: 5)
        guard case .answered(let response) = call else {
            Issue.record("pas de réponse : \(call)")
            return
        }
        #expect(response.deleted == ["2025-03-03-101530"])
        #expect(response.results.last?.outcome == .latest)
        #expect(backups.deletions == ["2025-03-03-101530"])
    }

    @Test("Le démon refuse les sauvegardes à un client qui n'est pas Oust! : rien n'est lu ni supprimé")
    func backupsRefuseForeignClient() async throws {
        let ownRequirement = try #require(Self.ownRequirement())
        let backups = FakeBackupTool(listed: BackupServiceTests.listed)
        let host = Host(service: HelperService(tool: FakeSnapshotTool(listed: []), backups: backups))
        let call = await PrivilegedHelper.deleteBackups(
            ["2025-03-03-101530"], destination: TimeMachineFixtures.mountPoint,
            transport: host.transport(daemonRequirement: ownRequirement), timeout: 5)
        #expect(call.isUnreachable)
        #expect(backups.deletions.isEmpty)
        #expect(backups.listings == 0)
    }

    // MARK: Signatures

    @Test("Les deux exigences de signature sont valides et nomment l'équipe et l'identifiant")
    func requirementsAreWellFormed() throws {
        for (text, identifier) in [(HelperContract.clientRequirement, "fr.meaillais.oust"),
                                   (HelperContract.daemonRequirement, "fr.meaillais.oust.helper")] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            #expect(text.contains("anchor apple generic"))
            #expect(text.contains("identifier \"\(identifier)\""))
            #expect(text.contains("certificate leaf[subject.OU] = \"H3W3XYM2NZ\""))
        }
    }

    @Test("Un processus qui n'est pas Oust! signé par l'équipe ne satisfait pas l'exigence du démon")
    func testProcessIsNotTheApp() throws {
        var code: SecCode?
        #expect(SecCodeCopySelf([], &code) == errSecSuccess)
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(HelperContract.clientRequirement as CFString, [], &requirement)
                == errSecSuccess)
        let ownCode = try #require(code)
        let clientRequirement = try #require(requirement)
        #expect(SecCodeCheckValidity(ownCode, [], clientRequirement) != errSecSuccess)
    }

    @Test("Le démon refuse un client qui n'est pas Oust! : rien n'est listé ni supprimé")
    func refusesForeignClient() async throws {
        let ownRequirement = try #require(Self.ownRequirement())
        let tool = FakeSnapshotTool(listed: HelperServiceTests.listing)
        // L'exigence du vrai démon côté serveur ; côté client, une que ce
        // processus satisfait, pour que seul le démon ait à refuser.
        let host = Host(service: HelperService(tool: tool))
        let call = await PrivilegedHelper.deleteSnapshots(
            dates: ["2026-10-17-014534"], transport: host.transport(daemonRequirement: ownRequirement), timeout: 5)
        #expect(call.isUnreachable)
        #expect(tool.deletions.isEmpty)
        #expect(tool.listings == 0)
    }

    @Test("Témoin : avec une exigence satisfaite, la même demande aboutit")
    func acceptsMatchingClient() async throws {
        let ownRequirement = try #require(Self.ownRequirement())
        let tool = FakeSnapshotTool(listed: HelperServiceTests.listing)
        let host = Host(service: HelperService(tool: tool, clientRequirement: ownRequirement))
        let call = await PrivilegedHelper.deleteSnapshots(
            dates: ["2026-10-17-014534"], transport: host.transport(daemonRequirement: ownRequirement), timeout: 5)
        guard case .answered(let response) = call else {
            Issue.record("pas de réponse : \(call)")
            return
        }
        #expect(response.deletedAll(["2026-10-17-014534"]))
        #expect(tool.deletions == ["2026-10-17-014534"])
    }

    @Test("L'application ne croit pas un démon qui n'est pas le sien")
    func refusesForeignDaemon() async throws {
        let ownRequirement = try #require(Self.ownRequirement())
        let tool = FakeSnapshotTool(listed: HelperServiceTests.listing)
        let host = Host(service: HelperService(tool: tool, clientRequirement: ownRequirement))
        // Côté application, la vraie exigence : ce « démon » n'y satisfait pas.
        let call = await PrivilegedHelper.status(
            transport: host.transport(daemonRequirement: HelperContract.daemonRequirement), timeout: 5)
        #expect(call == nil)
    }

    @Test("Démon absent : rien n'est tenté, l'invite administrateur reprend la main")
    func unregisteredHelperIsNeverCalled() async {
        let connections = Mutex(0)
        let transport = PrivilegedHelper.Transport(
            isRegistered: { false },
            connect: {
                connections.withLock { $0 += 1 }
                return NSXPCConnection(machServiceName: "fr.meaillais.oust.helper.absent")
            },
            daemonRequirement: HelperContract.daemonRequirement)
        let call = await PrivilegedHelper.deleteSnapshots(dates: ["2026-10-17-014534"], transport: transport)
        #expect(call.isUnreachable)
        #expect(connections.withLock { $0 } == 0)
    }

    @Test("Une demande refusée en bloc compte comme injoignable : rien n'a été fait")
    func wholeRefusalFallsBack() async throws {
        let ownRequirement = try #require(Self.ownRequirement())
        let tool = FakeSnapshotTool(listed: HelperServiceTests.listing, listingWorks: false)
        let host = Host(service: HelperService(tool: tool, clientRequirement: ownRequirement))
        let call = await PrivilegedHelper.deleteSnapshots(
            dates: ["2026-10-17-014534"], transport: host.transport(daemonRequirement: ownRequirement), timeout: 5)
        #expect(call.isUnreachable)
        #expect(tool.deletions.isEmpty)
    }

    @Test("Le démon dit sa version, et rien d'autre")
    func status() async throws {
        let ownRequirement = try #require(Self.ownRequirement())
        let host = Host(service: HelperService(tool: FakeSnapshotTool(listed: []),
                                               clientRequirement: ownRequirement, version: "1.2.3"))
        let status = await PrivilegedHelper.status(transport: host.transport(daemonRequirement: ownRequirement))
        #expect(status == HelperStatus(helperVersion: "1.2.3"))
    }

    // MARK: Outils

    /// L'exigence désignée du processus de test : ce qu'il satisfait à coup sûr.
    static func ownRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    /// Rend la première nouvelle : `true`/`false` donnés par `body`, ou nil
    /// passé le délai.
    static func within(seconds: TimeInterval,
                       _ body: (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool? {
        let first = Mutex<(CheckedContinuation<Bool?, Never>?, Bool)>((nil, false))
        let finish: @Sendable (Bool?) -> Void = { value in
            let continuation: CheckedContinuation<Bool?, Never>? = first.withLock { state in
                guard !state.1, let continuation = state.0 else { return nil }
                state = (nil, true)
                return continuation
            }
            continuation?.resume(returning: value)
        }
        return await withCheckedContinuation { continuation in
            first.withLock { $0.0 = continuation }
            body { finish($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(nil) }
        }
    }
}

/// Un écouteur anonyme qui porte le service du démon le temps d'un test.
private final class Host {
    let listener: NSXPCListener
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
        listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
    }

    deinit { listener.invalidate() }

    func transport(daemonRequirement: String) -> PrivilegedHelper.Transport {
        let endpoint = Endpoint(value: listener.endpoint)
        return PrivilegedHelper.Transport(
            isRegistered: { true },
            connect: { NSXPCConnection(listenerEndpoint: endpoint.value) },
            daemonRequirement: daemonRequirement)
    }

    /// Un point d'accès ne fait que désigner l'écouteur : le passer d'un fil à
    /// l'autre ne partage aucun état.
    private struct Endpoint: @unchecked Sendable {
        let value: NSXPCListenerEndpoint
    }
}

/// Ce qu'un appelant malveillant voudrait que le démon sache faire.
@objc private protocol ProbeProtocol {
    func runCommand(_ command: String, withReply reply: @escaping @Sendable (NSDictionary) -> Void)
}

private extension PrivilegedHelper.Call {
    var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }
}
