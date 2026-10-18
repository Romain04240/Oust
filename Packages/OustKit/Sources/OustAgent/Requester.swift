import Darwin
import OustSafety

/// Qui demande : le processus `oust` et la lignée qui l'a lancé.
///
/// Un agent travaille dans son projet : son dossier courant y est, celui du
/// shell qui lance `oust` aussi. Comptés comme activité, ils protégeraient tout
/// ce que l'agent demande justement de nettoyer derrière lui. Leur dossier
/// courant ne compte donc pas ; leur exécutable, si : on ne retire pas le
/// dossier d'où tourne celui qui demande. Tout autre processus — un serveur de
/// développement, une compilation que l'agent a lancée à côté — protège comme
/// partout ailleurs (RULES.md, règle 3).
public enum Requester {

    /// Ce processus et ses parents, jusqu'à launchd exclu.
    public static func lineage(of pid: Int32 = getpid()) -> Set<Int32> {
        var lineage: Set<Int32> = []
        var current = pid
        // 64 : une chaîne plus longue serait une boucle, pas une lignée.
        while current > 1, lineage.count < 64, lineage.insert(current).inserted {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            current = Int32(bitPattern: info.pbi_ppid)
        }
        return lineage
    }

    /// Le nom de l'agent qui a lancé `oust`, pour l'Historique de l'app : le
    /// premier ancêtre qui n'est pas un shell (« claude », « codex »).
    ///
    /// Un agent passe d'ordinaire par un shell (`zsh -c "oust clean …"`) ; en
    /// MCP, il lance `oust` lui-même. `nil` si la lignée ne se lit pas.
    public static func agentName(of pid: Int32 = getpid()) -> String? {
        var seen: Set<Int32> = [pid]
        var current = parent(of: pid)
        while let ancestor = current, ancestor > 1, seen.count < 64, seen.insert(ancestor).inserted {
            guard let name = executablePath(of: ancestor).flatMap(displayName(ofExecutable:)) else { return nil }
            if !intermediaries.contains(name) { return name }
            current = parent(of: ancestor)
        }
        return nil
    }

    /// Ce qui passe la main sans être l'agent : shells et lanceurs.
    static let intermediaries: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "nu",
        "env", "login", "nohup", "timeout", "xargs", "script",
    ]

    /// Le nom à montrer pour un exécutable.
    ///
    /// Claude Code installé en natif s'exécute depuis
    /// `~/.local/share/claude/versions/2.1.289` : son nom de fichier est un
    /// numéro de version. C'est alors le dossier qui tient `versions` qui le nomme.
    static func displayName(ofExecutable path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last, !last.isEmpty else { return nil }
        let isVersion = last.first?.isNumber == true && last.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
        if isVersion, components.count >= 3, components[components.count - 2] == "versions" {
            return components[components.count - 3]
        }
        return last
    }

    private static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    private static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// La table des processus où ceux de la lignée n'ont plus de dossier courant.
    public static func snapshot(_ snapshot: ProcessSnapshot, excluding lineage: Set<Int32>) -> ProcessSnapshot {
        ProcessSnapshot(processes: snapshot.processes.map { process in
            guard lineage.contains(process.pid) else { return process }
            return ActiveProcess(pid: process.pid, name: process.name, workingDirectory: "",
                                 executablePath: process.executablePath)
        })
    }
}
