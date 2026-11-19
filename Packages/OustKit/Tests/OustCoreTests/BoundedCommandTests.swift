import Darwin
import Foundation
import OustCore
import Testing

@Suite("Bounded read-only worker", .serialized)
struct BoundedCommandTests {
    @Test("Output is bounded across both streams, including after a fast exit")
    func outputBudget() async {
        let arguments = ["BEGIN { printf \"abcd\"; printf \"efgh\" > \"/dev/stderr\" }"]
        #expect(await BoundedCommand.run("/usr/bin/awk", arguments, maximumOutputBytes: 7) == nil)
        #expect(await BoundedCommand.run("/usr/bin/awk", arguments, maximumOutputBytes: 8) == Data("abcd".utf8))
        #expect(await BoundedCommand.run("/usr/bin/awk", ["BEGIN { for (i=0;i<33000;i++) printf \"x\" }"],
                                         maximumOutputBytes: 32768) == nil)
    }

    @Test("Timeout reaps a worker ignoring termination")
    func timeout() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let start = ContinuousClock.now
        let output = await BoundedCommand.run("/bin/sh", [fixture.script.path, fixture.pid.path], timeout: 0.15)
        #expect(output == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
        try expectStopped(fixture.pid)
    }

    @Test("Cancellation stops and reaps the worker before returning")
    func cancellation() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let task = Task { await BoundedCommand.run("/bin/sh", [fixture.script.path, fixture.pid.path], timeout: 5) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: fixture.pid.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        let output = await task.value
        #expect(output == nil)
        try expectStopped(fixture.pid)
    }

    @Test("An already cancelled request never launches a worker")
    func cancelledBeforeLaunch() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BoundedCommand.run("/bin/sh", [fixture.script.path, fixture.pid.path])
        }
        #expect(await task.value == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.pid.path))
    }

    @Test("Cancellation racing with launch leaves no owned worker alive")
    func cancellationAtLaunch() async throws {
        for _ in 0..<10 {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let task = Task { await BoundedCommand.run("/bin/sh", [fixture.script.path, fixture.pid.path], timeout: 2) }
            await Task.yield()
            task.cancel()
            #expect(await task.value == nil)
            if FileManager.default.fileExists(atPath: fixture.pid.path) { try expectStopped(fixture.pid) }
        }
    }

    private func expectStopped(_ file: URL) throws {
        let value = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(value))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    private struct Fixture {
        let root: URL
        let script: URL
        let pid: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-worker-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            script = root.appendingPathComponent("worker.sh")
            pid = root.appendingPathComponent("worker.pid")
            try Data("printf '%s' \"$$\" > \"$1\"\ntrap '' TERM\nwhile :; do :; done\n".utf8).write(to: script)
        }
    }
}
