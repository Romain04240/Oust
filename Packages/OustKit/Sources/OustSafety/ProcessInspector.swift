import Darwin
import Foundation

/// Un processus et le dossier dans lequel il travaille.
public struct ActiveProcess: Sendable, Hashable {
    public let pid: Int32
    public let name: String
    /// Vide quand macOS ne le dit pas (processus d'un autre utilisateur).
    public let workingDirectory: String
    /// Le chemin de l'exécutable : une application lancée du Finder a `/` pour
    /// dossier courant, et seul son exécutable dit qu'elle tourne.
    public let executablePath: String

    public init(pid: Int32, name: String, workingDirectory: String, executablePath: String = "") {
        self.pid = pid
        self.name = name
        self.workingDirectory = workingDirectory
        self.executablePath = executablePath
    }
}

/// Les processus de l'utilisateur à un instant donné.
///
/// Un agent qui travaille dans un projet, une compilation en cours, un éditeur
/// ouvert : leur dossier courant suffit à dire « quelqu'un est là ». Le
/// 18/10/2026, sessions Claude, Codex, Xcode et l'émulateur Android tournaient
/// dans quatre projets pendant le ménage ; c'est ce qui a dicté ce qu'on n'a pas
/// touché.
public struct ProcessSnapshot: Sendable {
    public let processes: [ActiveProcess]
    /// Faux si la table ou l'activité d'un processus vivant de cet utilisateur
    /// n'a pas pu être lue. Une archive ne doit pas confondre inconnu et inactif.
    public let isComplete: Bool

    public init(processes: [ActiveProcess], isComplete: Bool = true) {
        self.processes = processes
        self.isComplete = isComplete
    }

    /// Lit la table des processus (sans `lsof`, par `libproc`).
    public static func current() -> ProcessSnapshot {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return ProcessSnapshot(processes: [], isComplete: false) }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.size))
        }
        guard filled > 0 else { return ProcessSnapshot(processes: [], isComplete: false) }

        var found: [ActiveProcess] = []
        var isComplete = Int(filled) < pids.count
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            // Les processus d'autres utilisateurs répondent EPERM à cette question :
            // ils ne travaillent pas dans le dossier personnel, mais leur
            // exécutable peut vivre dans une application qu'on désinstalle.
            var directory = ""
            let hasDirectory = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size
            if hasDirectory {
                directory = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let executableError = length > 0 ? 0 : errno
            let executable = length > 0
                ? String(decoding: pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            if !activityIsKnown(directoryRead: hasDirectory, directory: directory,
                                executable: executable, executableError: executableError) {
                // Les démons d'autres comptes peuvent refuser cette lecture.
                // Un processus disparu entre les deux appels ne crée pas de doute.
                var owner = proc_bsdinfo()
                let ownerSize = Int32(MemoryLayout<proc_bsdinfo>.size)
                let hasOwner = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &owner, ownerSize) == ownerSize
                let vanished = kill(pid, 0) != 0 && errno == ESRCH
                if !vanished && (!hasOwner || owner.pbi_uid == geteuid()) { isComplete = false }
            }
            // Un dossier courant à la racine ne dit rien : c'est celui de toutes les
            // applications lancées par launchd.
            if directory.count <= 1 { directory = "" }
            guard !directory.isEmpty || !executable.isEmpty else { continue }
            let name = executable.isEmpty ? "pid \(pid)" : (executable as NSString).lastPathComponent
            found.append(ActiveProcess(pid: pid, name: name, workingDirectory: directory, executablePath: executable))
        }
        return ProcessSnapshot(processes: found, isComplete: isComplete)
    }

    static func activityIsKnown(directoryRead: Bool, directory: String,
                                executable: String, executableError: Int32) -> Bool {
        guard directoryRead, !directory.isEmpty else { return false }
        // ChatGPT for Chrome restait vivant après la disparition de son binaire
        // (ENOENT). Son cwd était connu : le bloquer interdisait toute archive.
        // Le binaire absent ne peut pas se trouver dans l'archive existante ;
        // le cwd reste inspecté normalement. Tout autre échec reste inconnu.
        return !executable.isEmpty || executableError == ENOENT
    }

    /// Le premier processus dont le dossier courant est `path` ou en dessous.
    public func busy(under path: String) -> ActiveProcess? {
        processes.first { !$0.workingDirectory.isEmpty && PathNormalizer.isWithin($0.workingDirectory, path) }
    }

    /// Le premier processus dont l'exécutable est `path` ou en dessous : une
    /// application ouverte, un assistant lancé depuis son paquet, un outil
    /// lancé depuis `node_modules/.bin`.
    public func running(inside path: String) -> ActiveProcess? {
        processes.first { !$0.executablePath.isEmpty && PathNormalizer.isWithin($0.executablePath, path) }
    }

    /// Vrai si un processus de ce nom tourne.
    public func isRunning(_ name: String) -> Bool {
        processes.contains { $0.name == name }
    }

}
