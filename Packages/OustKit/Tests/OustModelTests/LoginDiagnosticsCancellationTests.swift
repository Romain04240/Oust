import Darwin
import Foundation
import Synchronization
import Testing
import OustCore
@testable import OustModel

@Suite("Annulation du diagnostic de connexion")
struct LoginDiagnosticsCancellationTests {
    @Test("Une demande déjà annulée n’appelle pas le lecteur")
    func cancelledBeforeAdmission() async {
        let calls = CapturedCommand()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LoginDiagnostics.scan(read: {
                calls.record(.notRun)
                return .notRun
            })
        }
        let result = await task.value
        #expect(result == .unavailable && calls.value == nil)
    }

    @Test("Une réponse valide tardive est ignorée après fermeture")
    func lateReadAfterCancellation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let delayed = DelayedRead(); defer { delayed.finish(.notRun) }
        let task = Task { await LoginDiagnostics.scan(read: { await delayed.read() }) }
        await delayed.waitUntilEntered()
        task.cancel()
        delayed.finish(f.command)
        let result = await task.value
        #expect(result == .unavailable)
        try f.expectDocumentIntact()
    }

    @Test("Les erreurs, avertissements et sorties illisibles restent indisponibles",
          arguments: ["status", "stderr", "timeout", "not-run", "malformed"])
    func unavailableReads(_ variant: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        var command = f.command
        switch variant {
        case "status": command.status = 1
        case "stderr": command.stderr = Data("Avertissement fictif".utf8)
        case "timeout": command.timedOut = true
        case "not-run": command = .notRun
        default: command.stdout = Data("Sortie fictive illisible".utf8)
        }
        let reply = command
        let result = await LoginDiagnostics.scan(read: { reply })
        #expect(result == .unavailable)
        try f.expectDocumentIntact()
    }

    @Test("Le lecteur voit l’opt-in et le contexte antérieur est rétabli", arguments: [false, true])
    func restoresCommandContext(_ inherited: Bool) async {
        let original = CommandCancellationContext.cancelsReadOnlyCommands
        await CommandCancellationContext.$cancelsReadOnlyCommands.withValue(inherited) {
            let result = await LoginDiagnostics.scan(read: {
                #expect(CommandCancellationContext.cancelsReadOnlyCommands)
                return .notRun
            })
            #expect(result == .unavailable)
            #expect(CommandCancellationContext.cancelsReadOnlyCommands == inherited)
        }
        #expect(CommandCancellationContext.cancelsReadOnlyCommands == original)
    }

    @Test("Une réponse fictive valide conserve le diagnostic de volume indéterminé")
    func validFixtureResult() async throws {
        let f = try Fixture(); defer { f.remove() }
        let command = f.command
        let original = CommandCancellationContext.cancelsReadOnlyCommands
        let result = await LoginDiagnostics.scan(read: { command })
        #expect(result == .checked(volumeIndeterminate: [.init(id: f.id, name: "Application fictive")]))
        #expect(CommandCancellationContext.cancelsReadOnlyCommands == original)
        try f.expectDocumentIntact()
    }

    @Test("Annuler le diagnostic attend le retrait de sa commande possédée")
    func reapsOwnedReadCommand() async throws {
        let f = try Fixture(); defer { f.remove() }
        let captured = CapturedCommand()
        let marker = f.root.appendingPathComponent("owned.pid")
        let task = Task {
            await LoginDiagnostics.scan(read: {
                let command = await Command.run("/bin/sh", [
                    "-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10",
                    "oust-login-fixture", marker.path,
                ], timeout: 3)
                captured.record(command)
                return command
            })
        }
        let deadline = ContinuousClock.now + .seconds(2)
        var pid: Int32?
        while pid == nil, ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: marker, encoding: .utf8) {
                pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if pid == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        // Le handle est toujours annulé et rejoint, même sans marqueur lisible.
        task.cancel()
        let result = await task.value
        let ownedPID = try #require(pid)
        let command = try #require(captured.value)
        #expect(result == .unavailable)
        #expect(command.status == -1 && !command.succeeded && !command.timedOut)
        #expect(command.stdout.isEmpty && command.stderr.isEmpty)
        #expect(kill(ownedPID, 0) == -1 && errno == ESRCH)
        try f.expectDocumentIntact()
    }

    private struct Fixture {
        let root: URL
        let document: URL
        let id = UUID()

        init() throws {
            let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("oust-login-cancellation-\(UUID())", isDirectory: true)
            self.root = root
            self.document = root.appendingPathComponent("document.txt")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                try Data(repeating: 29, count: 128).write(to: document)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        var command: CommandResult {
            let app = root.appendingPathComponent("Absente.app", isDirectory: true)
            let report = """
             Records for UID \(getuid()) : \(UUID())
             #0:
                     UUID: \(id)
                     Name: Application fictive
                     Type: user item (0x1)
              Disposition: [enabled, allowed, not notified] (0x3)
               Identifier: \(app.absoluteString)
                      URL: \(app.path)
            """
            return CommandResult(status: 0, stdout: Data(report.utf8), stderr: Data(), timedOut: false)
        }

        func expectDocumentIntact() throws {
            #expect(try Data(contentsOf: document) == Data(repeating: 29, count: 128))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class CapturedCommand: Sendable {
    private let storage = Mutex<CommandResult?>(nil)
    var value: CommandResult? { storage.withLock { $0 } }
    func record(_ result: CommandResult) { storage.withLock { $0 = result } }
}

/// Le lecteur fictif continue volontairement après l’annulation de l’appelant.
private final class DelayedRead: Sendable {
    private struct State {
        var entered = false
        var continuation: CheckedContinuation<CommandResult, Never>?
        var prepared: CommandResult?
    }
    private let storage = Mutex(State())

    func read() async -> CommandResult {
        await withCheckedContinuation { continuation in
            let prepared: CommandResult? = storage.withLock {
                $0.entered = true
                if let prepared = $0.prepared { return prepared }
                $0.continuation = continuation
                return nil
            }
            if let prepared { continuation.resume(returning: prepared) }
        }
    }

    func finish(_ result: CommandResult) {
        let continuation = storage.withLock {
            $0.prepared = result
            let continuation = $0.continuation
            $0.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }

    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !storage.withLock({ $0.entered }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(storage.withLock { $0.entered })
    }
}
