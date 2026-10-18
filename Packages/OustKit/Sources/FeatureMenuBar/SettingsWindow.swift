import AppKit
import SwiftUI
import OustCore
import OustModel

/// La fenêtre Réglages (scène `Settings`), vue de la barre de menus et des
/// notifications.
///
/// SwiftUI ne l'ouvre que par `openSettings` ou `SettingsLink` :
/// `showSettingsWindow:` ne répond plus depuis macOS 14. L'action est donc prise
/// à la première vue qui la connaît, comme celle de la fenêtre principale.
@MainActor
public enum SettingsWindow {
    /// L'action d'ouverture de SwiftUI, prise dans la fenêtre principale ou le
    /// panneau de la barre de menus.
    public static var opener: OpenSettingsAction?

    /// SwiftUI nomme ainsi la fenêtre de sa scène `Settings`.
    static let identifier = "com_apple_SwiftUI_Settings_window"

    /// La fenêtre Réglages, si elle est ouverte.
    public static var current: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == identifier && ($0.isVisible || $0.isMiniaturized) }
    }

    /// Ouvre les Réglages au dernier onglet, ou à celui qu'on donne.
    public static func show(_ tab: SettingsTab? = nil, model: AppModel) {
        if let tab { model.settingsTab = tab }
        // Ouvert depuis la barre de menus, Oust! peut être hors du Dock : sans
        // cela, la fenêtre s'ouvrirait derrière celle qu'on regarde.
        NSApp.setActivationPolicy(.regular)
        if let opener {
            opener()
        } else {
            openFromMenu()
        }
        NSApp.activate()
    }

    /// Sans action prise (lancement à la connexion, rien d'ouvert encore) :
    /// l'article « Réglages… » du menu de l'app, que SwiftUI crée pour la scène.
    private static func openFromMenu() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: {
                  $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
              })
        else { return }
        menu.performActionForItem(at: index)
    }
}

/// Mène où dit une notification ou un lien de la barre de menus : une section
/// de la fenêtre principale, ou un onglet des Réglages.
@MainActor
public enum Navigator {
    public static func open(_ destination: Destination, model: AppModel) {
        switch destination {
        case .section(let section):
            model.searchText = ""
            model.section = section
            MainWindow.show()
        case .settings(let tab):
            SettingsWindow.show(tab, model: model)
        }
    }
}
