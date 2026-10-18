import Foundation
import Synchronization
import Testing
import OustHelperContract
@testable import OustVolume

@Suite("Sauvegardes Time Machine : le démon d'abord, l'invite ensuite")
struct BackupRoutingTests {

    static let mount = TimeMachineFixtures.mountPoint
    static let old = ["2025-03-03-101530", "2025-09-14-221004"]

    /// Note ce qui a été demandé au démon et à l'invite.
    final class Calls: Sendable {
        private let state = Mutex((helper: [[String]](), administrator: [[String]]()))
        func helper(_ chunk: [String]) { state.withLock { $0.helper.append(chunk) } }
        func administrator(_ chunk: [String]) { state.withLock { $0.administrator.append(chunk) } }
        var helperCalls: [[String]] { state.withLock { $0.helper } }
        var administratorCalls: [[String]] { state.withLock { $0.administrator } }
    }

    private func route(_ timestamps: [String] = old, at mount: String = mount,
                       helper: PrivilegedHelper.Call<BackupDeletionResponse>,
                       administrator: BackupDeletionRefusal? = nil, calls: Calls = Calls()) async -> BackupDeletionReply {
        await TimeMachineService.deleteBackups(timestamps, at: mount, helper: { chunk, _ in
            calls.helper(chunk)
            return helper
        }, administrator: { chunk in
            calls.administrator(chunk)
            return administrator
        })
    }

    @Test("Le démon a répondu : pas d'invite, et ce qu'il n'a pas supprimé est rapporté")
    func helperAnswered() async {
        let calls = Calls()
        let response = BackupDeletionResponse(results: [.init(timestamp: Self.old[0], outcome: .deleted),
                                                        .init(timestamp: Self.old[1], outcome: .failed, message: "Busy")])
        let reply = await route(helper: .answered(response), calls: calls)
        #expect(reply.path == .helper)
        #expect(reply.refusal == nil)
        #expect(reply.messages == [Self.old[1]: "Busy"])
        #expect(calls.administratorCalls.isEmpty)
    }

    @Test("Démon absent, d'une autre version, ou sans liste lisible : l'invite prend le relais",
          arguments: [PrivilegedHelper.Call<BackupDeletionResponse>.unreachable,
                      .answered(.refused(.contractMismatch)), .answered(.refused(.listingFailed))])
    func fallsBack(helper: PrivilegedHelper.Call<BackupDeletionResponse>) async {
        let calls = Calls()
        let reply = await route(helper: helper, calls: calls)
        #expect(reply.path == .administrator)
        #expect(reply.refusal == nil)
        #expect(calls.administratorCalls == [Self.old])
    }

    @Test("Sauvegarde en cours ou destination inconnue selon le démon : on s'arrête, sans invite")
    func stopsWithoutPrompt() async {
        for (refusal, expected) in [(RequestRefusal.backupRunning, BackupDeletionRefusal.backupRunning),
                                    (.unknownDestination, .unknownDestination)] {
            let calls = Calls()
            let reply = await route(helper: .answered(.refused(refusal)), calls: calls)
            #expect(reply.refusal == expected)
            #expect(calls.administratorCalls.isEmpty)
        }
    }

    @Test("Une sauvegarde lancée en route, d'après le démon : on s'arrête là")
    func runningMidway() async {
        let calls = Calls()
        let response = BackupDeletionResponse(results: [.init(timestamp: Self.old[0], outcome: .deleted),
                                                        .init(timestamp: Self.old[1], outcome: .backupRunning)])
        let reply = await route(helper: .answered(response), calls: calls)
        #expect(reply.refusal == .backupRunning)
        #expect(calls.administratorCalls.isEmpty)
    }

    @Test("Le démon ne répond pas à temps : ni succès, ni invite par-dessus")
    func timedOut() async {
        let calls = Calls()
        let reply = await route(helper: .timedOut, calls: calls)
        #expect(reply.refusal == .timedOut)
        #expect(calls.administratorCalls.isEmpty)
    }

    @Test("Invite fermée sans mot de passe : annulé")
    func cancelled() async {
        let reply = await route(helper: .unreachable, administrator: .cancelled)
        #expect(reply.refusal == .cancelled)
    }

    @Test("Un point de montage ou un horodatage hors forme : ni démon, ni invite")
    func malformedNeverLeaves() async {
        for (timestamps, mount) in [(Self.old, "/"), (Self.old, "/Volumes/a/b"), (["/"], Self.mount),
                                    (Self.old + ["2025-03-03"], Self.mount), ([], Self.mount)] {
            let calls = Calls()
            let reply = await route(timestamps, at: mount, helper: .unreachable, calls: calls)
            #expect(reply.refusal != nil)
            #expect(calls.helperCalls.isEmpty)
            #expect(calls.administratorCalls.isEmpty)
        }
    }

    @Test("Au-delà de la limite d'une demande, découpé en plusieurs")
    func chunks() async {
        let calls = Calls()
        let many = (0..<(TimeMachineBackups.maximumPerRequest + 10)).map { index in
            String(format: "2025-01-01-%02d%02d00", index % 24, index / 24)
        }
        _ = await route(many, helper: .unreachable, calls: calls)
        #expect(calls.helperCalls.map(\.count) == [TimeMachineBackups.maximumPerRequest, 10])
        #expect(calls.administratorCalls.flatMap { $0 } == many)
    }

    // MARK: L'invite administrateur

    @Test("Le script de l'invite : tmutil delete, le point de montage en argument, jamais dans le texte")
    func administratorArguments() throws {
        let arguments = try #require(TimeMachineService.administratorArguments(for: Self.old, at: Self.mount))
        #expect(arguments.last == Self.mount)
        let script = arguments.dropLast().joined(separator: "\n")
        #expect(!script.contains("Time Machine"))
        #expect(script.contains(#"do shell script "/usr/bin/tmutil delete -d " & quoted form of (item 1 of argv) & " -t 2025-03-03-101530 -t 2025-09-14-221004" with administrator privileges"#))
        #expect(arguments.first == "-e")
        #expect(arguments.filter { $0 == "-e" }.count == 3)
    }

    @Test("Rien ne se construit si une seule pièce n'a pas la forme attendue")
    func administratorArgumentsRefuse() {
        #expect(TimeMachineService.administratorArguments(for: Self.old, at: "/") == nil)
        #expect(TimeMachineService.administratorArguments(for: Self.old, at: "/Volumes/Time \"Machine\"") == nil)
        #expect(TimeMachineService.administratorArguments(for: ["2025-03-03-101530; rm -rf /"], at: Self.mount) == nil)
        #expect(TimeMachineService.administratorArguments(for: [], at: Self.mount) == nil)
        let tooMany = Array(repeating: Self.old[0], count: TimeMachineBackups.maximumPerRequest + 1)
        #expect(TimeMachineService.administratorArguments(for: tooMany, at: Self.mount) == nil)
    }

    @Test("Une sauvegarde ne se construit que d'un horodatage valide")
    func backupValue() throws {
        #expect(TimeMachineBackup(timestamp: "2025-03-03-101530.backup") == nil)
        #expect(TimeMachineBackup(timestamp: "/") == nil)
        let backup = try #require(TimeMachineBackup(timestamp: "2025-03-03-101530"))
        let date = try #require(backup.date)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second]
                == [2025, 3, 3, 10, 15, 30])
    }
}

extension PrivilegedHelper.Call: CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case .answered: "répondu"
        case .unreachable: "injoignable"
        case .timedOut: "délai"
        }
    }
}
