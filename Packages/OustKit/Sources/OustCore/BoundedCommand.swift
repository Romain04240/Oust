import Darwin
import Foundation

/// A small, read-only child process. Cancellation and the combined pipe budget
/// are enforced while reading, and no result is returned until the child exits.
public enum BoundedCommand {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 6,
                           maximumOutputBytes: Int = 32_768) async -> Data? {
        guard !Task.isCancelled, timeout.isFinite, timeout > 0, (1...1_048_576).contains(maximumOutputBytes),
              executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let cancellation = Cancellation()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let result = execute(executable, arguments, timeout: timeout, limit: maximumOutputBytes,
                                         cancellation: cancellation)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { cancellation.cancel() }
        return Task.isCancelled ? nil : result
    }

    private static func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                                limit: Int, cancellation: Cancellation) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let descriptors = [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor]
        defer {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else { return nil }
        }
        let deadline = ContinuousClock.now + .seconds(timeout)
        do { guard try cancellation.launch(process) else { return nil } } catch { return nil }
        var bytes = Data(), consumed = 0, failed = false
        var killAt: ContinuousClock.Instant?
        var killed = false
        func drain(_ descriptor: Int32, capture: Bool, final: Bool = false) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            // A noisy process must not starve the deadline/cancellation check.
            for _ in 0..<(final ? limit / buffer.count + 2 : 8) {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                guard count <= limit - consumed else { failed = true; return }
                consumed += count
                if capture { bytes.append(contentsOf: buffer.prefix(count)) }
            }
        }
        while process.isRunning {
            drain(descriptors[0], capture: true)
            drain(descriptors[1], capture: false)
            if failed || cancellation.isCancelled || ContinuousClock.now >= deadline {
                failed = true
                if killAt == nil {
                    process.terminate()
                    killAt = .now + .milliseconds(200)
                }
            }
            if let killAt, ContinuousClock.now >= killAt, !killed {
                killed = true
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        // Reap this child before allowing another read. The relay never forks.
        process.waitUntilExit()
        drain(descriptors[0], capture: true, final: true)
        drain(descriptors[1], capture: false, final: true)
        guard !failed, !cancellation.isCancelled, ContinuousClock.now < deadline, process.terminationStatus == 0 else { return nil }
        return bytes
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
        func launch(_ process: Process) throws -> Bool {
            // Reserve the launch before cancellation, but never hold the lock
            // across native process creation: cancelling must not block the UI.
            guard lock.withLock({ !cancelled }) else { return false }
            try process.run()
            return true
        }
    }
}
