import Darwin
import Foundation
import OustCore
import Testing

@Suite("Annulation des outils système")
struct CommandCancellationTests {
    @Test("Une demande déjà annulée ne lance pas de commande")
    func cancelledBeforeLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = Task {
            await CommandCancellationContext.$cancelsReadOnlyCommands.withValue(true) {
                withUnsafeCurrentTask { $0?.cancel() }
                return await Command.run("/bin/sh", ["-c", "printf launched > \"$1\"", "oust-fixture", fixture.marker.path],
                                         timeout: 3)
            }
        }
        let result = await task.value
        #expect(result.status == -1 && !result.succeeded && !result.timedOut)
        #expect(result.stdout.isEmpty && result.stderr.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    @Test("Annuler attend le retrait de la commande possédée avant de revenir")
    func cancellationReapsOwnedProcess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = Task {
            await CommandCancellationContext.$cancelsReadOnlyCommands.withValue(true) {
                await Command.run("/bin/sh", ["-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10",
                                               "oust-fixture", fixture.marker.path], timeout: 3)
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        var pid: Int32?
        while pid == nil, ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: fixture.marker, encoding: .utf8) {
                pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if pid == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let cancelledAt = ContinuousClock.now
        task.cancel()
        let result = await task.value
        let ownedPID = try #require(pid)
        #expect(ContinuousClock.now - cancelledAt < .seconds(2))
        #expect(result.status == -1 && !result.succeeded && !result.timedOut)
        #expect(result.stdout.isEmpty && result.stderr.isEmpty)
        #expect(kill(ownedPID, 0) == -1 && errno == ESRCH)
    }

    @Test("Par défaut une commande autorisée se termine malgré l'annulation de son appelant")
    func defaultContextPreservesCommand() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(!CommandCancellationContext.cancelsReadOnlyCommands)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Command.run("/bin/sh", ["-c", "/bin/sleep 0.1; printf completed > \"$1\"",
                                                 "oust-fixture", fixture.marker.path], timeout: 3)
        }
        let result = await task.value
        #expect(result.succeeded && !result.timedOut)
        #expect(try String(contentsOf: fixture.marker, encoding: .utf8) == "completed")
    }

    private struct Fixture {
        let root: URL
        let marker: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-command-cancel-\(UUID())")
            marker = root.appendingPathComponent("owned.pid")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
