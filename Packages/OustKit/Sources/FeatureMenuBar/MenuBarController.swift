import AppKit
import Observation
import SwiftUI
import OustLocalization
import OustModel
import OustWatch

enum MenuBarPage: Hashable { case storage, battery }

@MainActor @Observable
final class MenuBarNavigation {
    var page: MenuBarPage = .storage {
        didSet { if page != oldValue && page == .battery { batteryPresentedAt = .now } }
    }
    var presented = false {
        didSet { if presented && !oldValue { batteryPresentedAt = .now } }
    }
    private(set) var batteryPresentedAt = ContinuousClock.now
    var height: CGFloat = 500
    var batteryHealth: BatterySummary?
    var batteryHealthReadAt: ContinuousClock.Instant?
    var batteryDiagnostics: BatteryDiagnostics?
    var batteryDiagnosticsReadAt: ContinuousClock.Instant?
    var batteryDiagnosticsCycle: Int?
    @ObservationIgnored var close: () -> Void = {}
}

/// L'icône d'Oust! dans la barre de menus, et son panneau.
///
/// En AppKit, là où SwiftUI ne sait pas faire : `MenuBarExtra(isInserted:)`,
/// la seule façon de rendre la barre de menus masquable en SwiftUI, faisait
/// reconstruire le menu principal de l'app sans fin. Processeur à 100 %,
/// accessibilité muette, puis débordement de pile au lancement (18/10/2026,
/// macOS 27). Sans `isInserted`, plus de boucle ; mais l'icône ne se masquait
/// plus. Le panneau, lui, reste en SwiftUI.
@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private var icon: NSImage
    private var item: NSStatusItem?
    private var batteryItem: NSStatusItem?
    private weak var anchor: NSStatusBarButton?
    private enum PendingPresentation {
        case panel(MenuBarPage, NSStatusBarButton)
        case battery(onUnavailable: @MainActor () -> Void)
        case commands(NSStatusBarButton)
    }
    private var pendingPresentation: PendingPresentation?
    private var isClosing = false
    private let navigation = MenuBarNavigation()
    private let popover = NSPopover()

    public init(model: AppModel, icon: NSImage) {
        self.model = model
        self.icon = icon
        super.init()
        navigation.close = { [weak self] in self?.close() }
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(rootView: MenuBarPanel(model: model, navigation: navigation))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    public func setVisible(_ visible: Bool) {
        if visible && model.watch.menuBarContents.showsStorage { install() } else { removeStorage() }
        if visible && model.watch.menuBarContents.showsBattery { installBattery() } else { removeBattery() }
    }

    /// Change l'icône (monogramme blanc ou en couleur), sans retirer l'élément.
    public func setIcon(_ image: NSImage) {
        icon = image
        updateStorageBadge(available: model.watch.boot?.capacity.availableForImportantUsage)
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // macOS retient la place que l'utilisateur lui donne (⌘-glisser).
        item.autosaveName = "fr.meaillais.oust.menubar"
        if let button = item.button {
            button.imagePosition = .imageOnly
            configure(button)
        }
        self.item = item
        trackLabel()
    }

    private func removeStorage() {
        guard let item else { return }
        if let anchor, anchor === item.button { close() }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    private func installBattery() {
        guard batteryItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "fr.meaillais.oust.menubar.battery"
        batteryItem = item
        if let button = item.button {
            button.imagePosition = .imageOnly
            configure(button)
            trackBattery(on: button)
        }
    }

    private func removeBattery() {
        guard let batteryItem else { return }
        if let anchor, anchor === batteryItem.button { close() }
        NSStatusBar.system.removeStatusItem(batteryItem)
        self.batteryItem = nil
    }

    /// Le disponible macOS à côté de l'icône : le même chiffre que la fenêtre,
    /// relu à chaque nouvel échantillon du modèle.
    private func trackLabel() {
        guard let button = item?.button else { return }
        let available = withObservationTracking {
            model.watch.boot?.capacity.availableForImportantUsage
        } onChange: { [weak self, weak button] in
            Task { @MainActor in
                guard let self, let button, self.item?.button === button else { return }
                self.trackLabel()
            }
        }
        updateStorageBadge(available: available)
    }

    private func updateStorageBadge(available: Int64?) {
        guard let button = item?.button else { return }
        let value = available.map { Formatters.compactBytes($0) }
        let label = L10n.string("menubar.storage")
        let badge = MenuBarBadge.storage(icon: icon, value: value)
        item?.length = badge.size.width
        button.image = badge
        button.setAccessibilityLabel(value.map { label + ", " + L10n.string("disks.free", $0) } ?? label)
    }

    private func trackBattery(on button: NSStatusBarButton) {
        guard batteryItem?.button === button else { return }
        let reading = withObservationTracking { model.watch.battery } onChange: { [weak self, weak button] in
            Task { @MainActor in if let button { self?.trackBattery(on: button) } }
        }
        let label = L10n.string("menubar.battery")
        let percent = reading.map { L10n.string("menubar.battery_percent", Formatters.count($0.level)) }
        let badge = MenuBarBadge.battery(reading, percentage: percent)
        batteryItem?.length = badge.size.width
        button.image = badge
        if let reading, let percent {
            button.setAccessibilityLabel(label + " " + percent + ", " + L10n.string(reading.state.localizationKey))
        } else {
            button.setAccessibilityLabel(L10n.string("menubar.battery_unavailable"))
        }
    }

    private func configure(_ button: NSStatusBarButton) {
        button.isBordered = false
        button.imageScaling = .scaleNone
        button.wantsLayer = true
        button.target = self
        button.action = #selector(toggle(_:))
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: L10n.string("menubar.commands")) { [weak self, weak button] in
                guard let self, let button else { return false }
                self.showCommands(from: button)
                return true
            }
        ])
        let secondary = NSClickGestureRecognizer(target: self, action: #selector(contextClick(_:)))
        secondary.buttonMask = 0x2
        button.addGestureRecognizer(secondary)
    }

    @objc private func contextClick(_ gesture: NSClickGestureRecognizer) {
        guard let button = gesture.view as? NSStatusBarButton else { return }
        showCommands(from: button)
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showCommands(from: sender)
            return
        }
        let page: MenuBarPage = sender === batteryItem?.button ? .battery : .storage
        if !isClosing, popover.isShown, anchor === sender, navigation.page == page {
            close()
        } else {
            show(page, from: sender)
        }
    }

    @discardableResult
    public func showBattery(onUnavailable: @escaping @MainActor () -> Void = {}) -> Bool {
        if isClosing {
            pendingPresentation = .battery(onUnavailable: onUnavailable)
            return true
        }
        guard let button = batteryItem?.button, visibleRect(of: button) != nil else {
            onUnavailable()
            return false
        }
        if popover.isShown, anchor !== button {
            pendingPresentation = .battery(onUnavailable: onUnavailable)
            close()
            return true
        }
        if show(.battery, from: button) { return true }
        onUnavailable()
        return false
    }

    private func visibleRect(of button: NSStatusBarButton) -> NSRect? {
        guard button === item?.button || button === batteryItem?.button,
              let window = button.window, window.isVisible, let screen = window.screen else { return nil }
        let rect = button.bounds.intersection(button.visibleRect)
        guard !rect.isEmpty,
              window.convertToScreen(button.convert(rect, to: nil)).intersects(screen.frame) else { return nil }
        return rect
    }

    @discardableResult
    private func show(_ page: MenuBarPage, from sender: NSStatusBarButton) -> Bool {
        guard let rect = visibleRect(of: sender) else { return false }
        if isClosing {
            pendingPresentation = .panel(page, sender)
            return true
        }
        if popover.isShown {
            if anchor === sender { return true }
            pendingPresentation = .panel(page, sender)
            close()
            return true
        }
        navigation.page = page
        navigation.height = min(520, max(180, (sender.window?.screen?.visibleFrame.height ?? 600) - 70))
        popover.show(relativeTo: rect, of: sender, preferredEdge: .minY)
        guard popover.isShown else { return false }
        anchor = sender
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = sender.layer {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.65
            pulse.toValue = 1
            pulse.duration = 0.20
            layer.add(pulse, forKey: "oust.badge.open")
        }
        navigation.presented = popover.isShown
            // Par-dessus une app en plein écran, comme les menus des autres
            // apps : le panneau rejoint l'espace courant au lieu de rester sur
            // celui de la fenêtre d'Oust!, dessous (Romain, 18/10/2026).
        if let window = popover.contentViewController?.view.window {
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .transient])
            window.level = .popUpMenu
            window.orderFrontRegardless()
            window.makeKey()
        }
        return true
    }

    /// Ferme le panneau (on vient d'ouvrir la fenêtre, de quitter…).
    public func close() {
        if popover.isShown && !isClosing { popover.close() }
    }

    public func popoverWillClose(_ notification: Notification) {
        isClosing = true
        navigation.presented = false
    }

    public func popoverDidClose(_ notification: Notification) {
        isClosing = false
        navigation.presented = false
        anchor = nil
        let pending = pendingPresentation
        pendingPresentation = nil
        switch pending {
        case .panel(let page, let button): show(page, from: button)
        case .battery(let onUnavailable): showBattery(onUnavailable: onUnavailable)
        case .commands(let button): showCommands(from: button)
        case nil: break
        }
    }

    private func showCommands(from button: NSStatusBarButton) {
        if popover.isShown || isClosing {
            pendingPresentation = .commands(button)
            close()
            return
        }
        // Sortir de la distribution du clic secondaire avant le suivi modal.
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button else { return }
            self.presentCommands(from: button)
        }
    }

    private func presentCommands(from button: NSStatusBarButton) {
        guard let rect = visibleRect(of: button), let window = button.window else { return }
        let screenRect = window.convertToScreen(button.convert(rect, to: nil))
        let menu = NSMenu()
        for (key, action) in [
            ("menubar.open", #selector(openApp)),
            ("menu.settings", #selector(openSettings)),
            ("menubar.quit", #selector(confirmQuit)),
        ] {
            let item = NSMenuItem(title: L10n.string(key), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: .init(x: screenRect.minX, y: screenRect.minY - 2), in: nil)
    }

    @objc private func openApp() { MainWindow.show() }
    @objc private func openSettings() { SettingsWindow.show(model: model) }

    @objc private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = L10n.string("menubar.quit_title")
        var detail = L10n.string("menubar.quit_detail")
        if model.cleaning == .running { detail += " " + L10n.string("menubar.quit_cleaning") }
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.string("menubar.quit_confirm"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }
}
