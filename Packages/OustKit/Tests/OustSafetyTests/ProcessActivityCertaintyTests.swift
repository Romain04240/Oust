import Darwin
import Foundation
import Testing
@testable import OustSafety

@Suite("Activité connue malgré un exécutable disparu")
struct ProcessActivityCertaintyTests {
    @Test("ENOENT avec cwd connu ne rend pas tous les projets incertains")
    func deletedExecutableWithKnownDirectory() {
        let known = ProcessSnapshot.activityIsKnown(directoryRead: true, directory: "/",
            executable: "", executableError: ENOENT)
        #expect(known)
        #expect(ProcessSnapshot(processes: [], isComplete: known).isComplete)
    }

    @Test("Un exécutable disparu ne masque pas un cwd qui occupe le projet")
    func deletedExecutableStillProtectsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-process-\(UUID().uuidString)")
        let known = ProcessSnapshot.activityIsKnown(directoryRead: true, directory: root.path,
            executable: "", executableError: ENOENT)
        let snapshot = ProcessSnapshot(processes: [ActiveProcess(pid: 42, name: "agent",
            workingDirectory: root.path)], isComplete: known)
        #expect(snapshot.isComplete)
        #expect(snapshot.busy(under: root.path)?.name == "agent")
    }

    @Test("Un cwd inconnu ou une autre erreur d'exécutable reste incertain", arguments: [
        (false, "/", ENOENT), (true, "", ENOENT), (true, "/", EPERM),
        (true, "/", EACCES), (true, "/", Int32(0)),
    ])
    func unknownActivity(directoryRead: Bool, directory: String, error: Int32) {
        #expect(!ProcessSnapshot.activityIsKnown(directoryRead: directoryRead, directory: directory,
            executable: "", executableError: error))
    }
}
