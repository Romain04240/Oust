import AppKit
import SwiftUI

/// La fenêtre d'Oust!, vue de la barre de menus et des notifications.
///
/// Une seule fenêtre : la ramener si elle existe, en ouvrir une sinon. Un
/// `openWindow` nu en ouvrirait une deuxième à chaque clic.
@MainActor
public enum MainWindow {
    /// L'identifiant du `WindowGroup` principal.
    public static let id = "main"

    /// L'action d'ouverture de SwiftUI, prise à la première vue qui la connaît
    /// (l'icône de la barre de menus) : une notification n'en a pas.
    public static var opener: OpenWindowAction?

    /// La fenêtre principale, visible ou réduite dans le Dock. Le panneau de la
    /// barre de menus et les feuilles ne comptent pas : ils ne deviennent
    /// jamais fenêtre principale.
    public static var current: NSWindow? {
        NSApp.windows.first { isMain($0) && ($0.isVisible || $0.isMiniaturized) }
    }

    /// SwiftUI nomme les fenêtres d'un `WindowGroup` d'après son identifiant
    /// (« main-AppWindow-1 ») : c'est ce qui les distingue sûrement du panneau
    /// de la barre de menus, qui n'est pas forcément un `NSPanel`.
    static func isMain(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue, identifier.hasPrefix(id) else { return false }
        return window.canBecomeMain && !(window is NSPanel)
    }

    public static func show() {
        NSApp.setActivationPolicy(.regular)
        if let window = current {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let opener {
            opener(id: id)
        } else {
            // Ni fenêtre ni action d'ouverture (barre de menus masquée) : rouvrir
            // l'app lui fait montrer sa fenêtre, comme un clic dans le Dock.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
        NSApp.activate()
    }

    /// Ferme la fenêtre principale sans quitter (lancement à la connexion).
    public static func closeAll() {
        for window in NSApp.windows where isMain(window) && window.isVisible { window.close() }
    }
}
