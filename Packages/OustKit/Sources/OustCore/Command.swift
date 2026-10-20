import Foundation
import Darwin

/// Le résultat d'un outil du système.
public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }

    public static let notRun = CommandResult(status: -1, stdout: Data(), stderr: Data(), timedOut: false)
}

/// Lance un outil du système (`git`, `xcrun`, `tmutil`) et rend sa sortie.
///
/// Placé dans le domaine malgré son lien avec `Process` : quatre moteurs en ont
/// besoin, et une seule implémentation évite quatre façons différentes de
/// rater la lecture concurrente des tubes.
public enum Command {

    /// Exécute sans jamais bloquer au-delà du délai.
    ///
    /// La lecture des tubes se fait pendant l'attente, pas après : un tube plein
    /// bloquerait le processus fils, qui ne se terminerait jamais (leçon de
    /// Tacho, `HardwareInventory.run`).
    public static func run(
        _ executable: String,
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: TimeInterval = 30,
        environment: [String: String]? = nil
    ) async -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return .notRun }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                if let environment {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                }
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: .notRun)
                    return
                }
                // Un descendant peut hériter des tubes puis survivre à osascript.
                // Attendre EOF rendait alors le délai inopérant : l'interface
                // tournait indéfiniment. Les lectures ne bloquent jamais.
                let descriptors = [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor]
                for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
                var stdout = Data()
                var stderr = Data()
                let clock = ContinuousClock()
                let deadline = clock.now + .seconds(max(0, timeout))
                var timedOut = false
                var killDeadline: ContinuousClock.Instant?
                while process.isRunning {
                    drain(descriptors[0], into: &stdout)
                    drain(descriptors[1], into: &stderr)
                    if !timedOut, clock.now >= deadline {
                        timedOut = true
                        process.terminate()
                        killDeadline = clock.now + .seconds(1)
                    }
                    if let killDeadline, clock.now >= killDeadline {
                        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                drain(descriptors[0], into: &stdout)
                drain(descriptors[1], into: &stderr)
                try? out.fileHandleForReading.close()
                try? err.fileHandleForReading.close()
                let status: Int32 = process.isRunning ? -1 : process.terminationStatus
                continuation.resume(returning: CommandResult(status: status, stdout: stdout, stderr: stderr, timedOut: timedOut))
            }
        }
    }

    private static func drain(_ fd: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        // Limite par tour : un producteur bavard ne doit pas empêcher le délai.
        for _ in 0..<16 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
