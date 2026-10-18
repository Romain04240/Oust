import AppKit
import Darwin
import Foundation
import OustSafety

/// L'Accès complet au disque, deviné faute d'API (SPEC §2).
///
/// Apple ne fournit aucun moyen de le demander ni de le vérifier : on tente une
/// lecture que macOS refuse sans lui, et on regarde l'erreur. `EPERM` vient de
/// TCC ; tout autre échec ne permet pas de conclure.
public enum FullDiskAccess {
    public static func isGranted(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool? {
        let probes = [
            home.appendingPathComponent("Library/Safari").path,
            home.appendingPathComponent("Library/Mail").path,
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for probe in probes {
            let fd = open(probe, O_RDONLY)
            if fd >= 0 {
                close(fd)
                if probe.hasSuffix(".db") { return true }
                // Un dossier ouvert ne suffit pas : c'est sa lecture que TCC bloque.
                if (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil { return true }
                return false
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return nil
    }

    /// Ouvre Réglages Système au bon panneau.
    @MainActor
    public static func openSettings() {
        let deep = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security")
        if let deep, NSWorkspace.shared.open(deep) { return }
        if let fallback { NSWorkspace.shared.open(fallback) }
    }

    /// L'accès ne prend effet qu'au prochain lancement.
    @MainActor
    public static func relaunch() {
        relaunchAfterExit()
        NSApp.terminate(nil)
    }

    /// Rouvre l'app une fois ce processus parti. `open` sans `-n` ne fait
    /// qu'activer une instance que Réglages Système aurait rouverte entre-temps.
    public static func relaunchAfterExit() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [
            "-c", #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$2""#,
            "oust-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath,
        ]
        try? shell.run()
    }

    /// L'exécutable qui demande de quitter, quand la demande est un événement
    /// Apple (Réglages Système, `osascript`…) ; nil pour ⌘Q.
    @MainActor
    public static func quitRequestSender() -> String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
              let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        else { return nil }
        return QuitSender.executable(of: pid)
    }
}

/// Révéler dans le Finder.
public enum Finder {
    @MainActor
    public static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
