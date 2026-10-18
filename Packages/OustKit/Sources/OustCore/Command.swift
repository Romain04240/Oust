import Foundation

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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = directory }
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            }
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            let box = ResultBox()
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "fr.meaillais.oust.command", attributes: .concurrent)

            group.enter()
            queue.async {
                box.setStdout((try? out.fileHandleForReading.readToEnd()) ?? Data())
                group.leave()
            }
            group.enter()
            queue.async {
                box.setStderr((try? err.fileHandleForReading.readToEnd()) ?? Data())
                group.leave()
            }
            group.enter()
            process.terminationHandler = { _ in group.leave() }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: .notRun)
                return
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    box.markTimedOut()
                    process.terminate()
                }
            }

            group.notify(queue: queue) {
                continuation.resume(returning: box.result(status: process.terminationStatus))
            }
        }
    }

    /// Petite boîte synchronisée : les deux tubes se lisent sur d'autres files.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var timedOut = false

        func setStdout(_ data: Data) { lock.withLock { stdout = data } }
        func setStderr(_ data: Data) { lock.withLock { stderr = data } }
        func markTimedOut() { lock.withLock { timedOut = true } }
        func result(status: Int32) -> CommandResult {
            lock.withLock { CommandResult(status: status, stdout: stdout, stderr: stderr, timedOut: timedOut) }
        }
    }
}
