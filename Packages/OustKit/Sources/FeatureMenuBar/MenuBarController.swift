import AppKit
import Observation
import SwiftUI
import OustLocalization
import OustModel

/// L'icône d'Oust! dans la barre de menus, et son panneau.
///
/// En AppKit, là où SwiftUI ne sait pas faire : `MenuBarExtra(isInserted:)`,
/// la seule façon de rendre la barre de menus masquable en SwiftUI, faisait
/// reconstruire le menu principal de l'app sans fin. Processeur à 100 %,
/// accessibilité muette, puis débordement de pile au lancement (18/10/2026,
/// macOS 27). Sans `isInserted`, plus de boucle ; mais l'icône ne se masquait
/// plus. Le panneau, lui, reste en SwiftUI.
@MainActor
public final class MenuBarController: NSObject {
    private let model: AppModel
    private var icon: NSImage
    private var item: NSStatusItem?
    private let popover = NSPopover()

    public init(model: AppModel, icon: NSImage) {
        self.model = model
        self.icon = icon
        super.init()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(rootView: MenuBarPanel(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    public func setVisible(_ visible: Bool) {
        if visible { install() } else { remove() }
    }

    /// Change l'icône (monogramme blanc ou en couleur), sans retirer l'élément.
    public func setIcon(_ image: NSImage) {
        icon = image
        item?.button?.image = image
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // macOS retient la place que l'utilisateur lui donne (⌘-glisser).
        item.autosaveName = "fr.meaillais.oust.menubar"
        if let button = item.button {
            button.image = icon
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggle(_:))
            button.setAccessibilityLabel("Oust!")
        }
        self.item = item
        trackLabel()
    }

    private func remove() {
        guard let item else { return }
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    /// Le disponible macOS à côté de l'icône : le même chiffre que la fenêtre,
    /// relu à chaque nouvel échantillon du modèle.
    private func trackLabel() {
        guard let button = item?.button else { return }
        let title = withObservationTracking {
            model.watch.boot.map { " " + Formatters.compactBytes($0.capacity.availableForImportantUsage) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackLabel() }
        }
        button.title = title ?? ""
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // Par-dessus une app en plein écran, comme les menus des autres
            // apps : le panneau rejoint l'espace courant au lieu de rester sur
            // celui de la fenêtre d'Oust!, dessous (Romain, 18/10/2026).
            if let window = popover.contentViewController?.view.window {
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .transient])
                window.level = .popUpMenu
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }

    /// Ferme le panneau (on vient d'ouvrir la fenêtre, de quitter…).
    public func close() {
        popover.performClose(nil)
    }
}
