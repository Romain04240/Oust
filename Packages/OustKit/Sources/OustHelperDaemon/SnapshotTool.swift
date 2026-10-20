import Foundation
import Darwin
import OustHelperContract
import Synchronization

/// Ce dont le démon a besoin du système : lister, supprimer. Rien d'autre.
///
/// Un protocole pour que les tests remplacent `tmutil` par un faux qui note ce
/// qu'on lui demande : aucun test ne supprime de vrai snapshot.
public protocol SnapshotTool: Sendable {
    /// La sortie de `tmutil listlocalsnapshots` sur le volume de données, ou
    /// nil si elle a échoué.
    func listLocalSnapshots() -> String?

    /// Supprime le snapshot Time Machine local de cette date : nil si `tmutil`
    /// a confirmé, sinon ce qu'il a dit.
    func deleteLocalSnapshot(date: String) -> String?
}

/// `tmutil`, le vrai, avec des arguments fixes.
public struct SystemSnapshotTool: SnapshotTool {

    static let tmutil = "/usr/bin/tmutil"

    /// Sur le volume de données et non sur `/`, comme `VolumeService` : `/` ne
    /// montre que le volume système scellé et son snapshot de mise à jour.
    static let dataVolume = "/System/Volumes/Data"

    public init() {}

    public func listLocalSnapshots() -> String? {
        let result = Self.run(["listlocalsnapshots", Self.dataVolume], timeout: 30)
        return result.status == 0 ? result.output : nil
    }

    public func deleteLocalSnapshot(date: String) -> String? {
        // Revérifié au plus près de l'exécution : quel que soit le chemin
        // par lequel on arrive ici, aucune autre forme n'atteint `tmutil`.
        guard SnapshotDates.isValid(date) else { return "malformed" }
        let result = Self.run(["deletelocalsnapshots", date], timeout: 300)
        if result.status == 0 { return nil }
        let said = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "tmutil \(result.status)" : String(said.prefix(300))
    }

    struct Output {
        var status: Int32
        var output: String
        var errorOutput: String
    }

    /// Lance `tmutil` directement, sans shell, avec un environnement réduit :
    /// les arguments arrivent tels quels, rien ne les interprète.
    ///
    /// Les tubes sont lus pendant l'attente et non après : un tube plein
    /// bloquerait `tmutil`, qui ne se terminerait jamais (leçon de Tacho).
    static func run(_ arguments: [String], timeout: TimeInterval) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmutil)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            return Output(status: -1, output: "", errorOutput: error.localizedDescription)
        }
        let descriptors = [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor]
        for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var stdout = Data()
        var stderr = Data()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
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
        let status: Int32 = timedOut || process.isRunning ? -1 : process.terminationStatus
        return Output(status: status, output: String(decoding: stdout, as: UTF8.self),
                      errorOutput: timedOut ? "tmutil timed out" : String(decoding: stderr, as: UTF8.self))
    }

    private static func drain(_ fd: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<16 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
