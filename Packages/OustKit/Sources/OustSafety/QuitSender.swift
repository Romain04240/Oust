import Darwin
import Foundation

/// Qui demande à l'app de quitter.
///
/// Réglages Système quitte l'app pour qu'un accès accordé prenne effet, et
/// promet de la rouvrir ; il ne le fait pas toujours. Le 18/10/2026, après
/// l'Accès complet au disque, Oust! a été quitté à 12:56:25 et personne ne l'a
/// rouvert. On reconnaît sa demande à l'exécutable qui l'envoie, pour se
/// rouvrir soi-même.
public enum QuitSender {
    /// Le chemin de l'exécutable d'un processus, nil s'il n'est plus là.
    public static func executable(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Réglages Système, ou l'un de ses panneaux (des extensions ExtensionKit).
    /// Jamais loginwindow : se rouvrir pendant une fermeture de session ou un
    /// redémarrage serait absurde.
    public static func isSystemSettings(executable path: String) -> Bool {
        path.hasPrefix("/System/Applications/System Settings.app/")
            || path.hasPrefix("/System/Library/ExtensionKit/Extensions/")
    }
}
