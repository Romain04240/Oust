import AppKit
import os
import SwiftUI
import FeatureMenuBar
import FeatureSettings
import OustDesignSystem
import OustLocalization
import OustModel
import OustSafety
import OustUninstall

@main
struct OustApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Le modèle vit dans le délégué : la barre de menus, l'alerte et les
        // règles planifiées tournent sans que la fenêtre se soit jamais ouverte
        // (lancement à la connexion).
        let model = appDelegate.model
        WindowGroup(id: MainWindow.id) {
            RootView(model: model)
                .frame(minWidth: 1080, minHeight: 720)
                .task { await model.start() }
                .modifier(OpenWindowCapture())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(LaunchContext.isLoginLaunch ? .suppressed : .automatic)
        .commands {
            // « À propos d'Oust! » avec l'éditeur, son site et son adresse,
            // cliquables (Romain, 18/10/2026).
            CommandGroup(replacing: .appInfo) {
                Button { AboutPanel.show() } label: { Text("menu.about", bundle: .oust) }
            }
            CommandGroup(after: .appInfo) {
                Button {
                    model.settingsTab = .general
                    SettingsWindow.show(.general, model: model)
                    Task { await model.updates.check() }
                } label: { Text("updates.check", bundle: .oust) }
                    .disabled(model.updates.busy)
            }
            // Les réglages ont leur fenêtre, à onglets : la scène `Settings`
            // met elle-même « Réglages… » (⌘,) dans le menu de l'app. Le
            // remplacer en ajoutait un second (vu à l'écran, 18/10/2026).
            CommandGroup(after: .newItem) {
                Button {
                    let section = model.section
                    let isSearching = model.isSearching
                    Task { await model.performAnalysisCommand(from: section, isSearching: isSearching) }
                } label: { Text("menu.analyze", bundle: .oust) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.analysis.isRunning)
                Button {
                    model.section = .cart
                    MainWindow.show()
                } label: { Text("menu.cart", bundle: .oust) }
                    .keyboardShortcut("k", modifiers: .command)
                // ⌘Y, comme l'historique de Safari : la barre d'outils n'en montre
                // plus que l'icône.
                Button {
                    model.searchText = ""
                    model.section = .history
                    MainWindow.show()
                } label: { Text("menu.history", bundle: .oust) }
                    .keyboardShortcut("y", modifiers: .command)
            }
        }

        // Une fenêtre à part, à onglets, plutôt qu'une section de la fenêtre
        // (Romain, 18/10/2026 : « trop long, ça défile », « mal rangé »).
        Settings {
            SettingsView(model: model)
        }
    }
}

/// Se rouvrir quand Réglages Système nous quitte pour appliquer un accès : il
/// le promet, mais ne le fait pas toujours (18/10/2026). L'expéditeur est noté
/// dans le journal système, pour comprendre la prochaine fois.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "fr.meaillais.oust", category: "lifecycle")

    /// Le modèle de l'app, créé avec elle et non avec la fenêtre.
    let model = AppModel()
    /// La barre de menus (SPEC §10, phase 3) : les disques, la corbeille,
    /// l'analyse et la fenêtre, d'un clic. Masquable dans les Réglages.
    private lazy var menuBar = MenuBarController(model: model, icon: storageIcon)
    private var storageIcon: NSImage {
        MenuBarIcon.image(colored: model.watch.menuBarIconInColor, drive: model.watch.menuBarUsesDriveIcon)
    }
    private var router: NotificationRouter?
    private var observers: [any NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Avant la fin du lancement : une notification cliquée alors qu'Oust!
        // était fermé arrive juste après, et doit trouver à qui parler.
        let model = model
        let router = NotificationRouter { destination in
            Navigator.open(destination, model: model)
        } perform: { action in
            // L'entretien remplit la corbeille avant qu'elle s'ouvre.
            model.watch.maintenance.perform(action)
        }
        router.install()
        self.router = router
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = model
        model.watch.onLowDisk = { alert in
            CapsulePresenter.shared.show(alert) {
                model.searchText = ""
                model.section = .overview
                MainWindow.show()
            }
        }
        model.watch.onBatteryAlert = { [weak self] alert in
            guard let cycle = self?.model.watch.batteryAlertCycle else { return }
            CapsulePresenter.shared.showBattery(alert, current: { [weak self] in
                self?.model.watch.currentBatteryAlert(matching: alert, cycle: cycle)
            }) { [weak self] in
                guard let self else { return }
                self.menuBar.showBattery { [weak self] in
                    guard let self else { return }
                    SettingsWindow.show(.battery, model: self.model)
                }
            }
        }
        // L'entretien planifié : ce qu'il a trouvé, en pastille ; un clic ouvre
        // la corbeille avec ces éléments, pour la revue et la confirmation.
        model.watch.maintenance.onFinding = { finding in
            CapsulePresenter.shared.showMaintenance(current: {
                await MaintenanceModel.capsuleFinding(finding, home: model.home)
            }) { current in
                model.watch.maintenance.review(current)
                MainWindow.show()
            }
        }
        // Les restes d'une app mise à la corbeille du Mac, en pastille aussi :
        // la notification seule passait inaperçue (Romain, 18/10/2026). Un clic
        // ouvre leur revue ; rien ne part sans confirmation.
        model.trashedApps.onLeftovers = { report in
            let capacity = model.bootVolume?.capacity
            let total = Double(max(1, capacity?.total ?? 1))
            CapsulePresenter.shared.show(CapsuleMessage(
                symbol: "trash.fill",
                label: L10n.string("trashed.capsule.label", report.app.name),
                figure: Formatters.compactBytes(report.freeable),
                word: L10n.string("trashed.capsule.word"),
                gauge: CapsuleGauge(filled: capacity?.usedFraction ?? 0, giveBack: Double(report.freeable) / total),
                announcement: L10n.string("trashed.capsule.announcement", report.app.name,
                                          Formatters.bytes(report.freeable)),
                hint: L10n.string("trashed.capsule.hint")
            )) {
                model.trashedApps.review(report.id)
                MainWindow.show()
            }
        }
        model.watch.onMenuBarIconChange = { [weak self] in
            guard let self else { return }
            self.menuBar.setIcon(self.storageIcon)
        }
        model.watch.onMenuBarChange = { [weak self] visible in
            self?.menuBar.setVisible(visible)
            self?.updateActivationPolicy()
        }
        menuBar.setVisible(model.watch.showsMenuBar)
        model.watch.start()
        observeWindows()
        // Seulement à la connexion : à un lancement ordinaire, la fenêtre n'est
        // peut-être pas encore là, et quitter le Dock maintenant la priverait de
        // son menu.
        if LaunchContext.isLoginLaunch {
            log.notice("Ouvert à la connexion : sans fenêtre")
            // Au cas où SwiftUI aurait ouvert la fenêtre avant de lire
            // `defaultLaunchBehavior` : elle part aussitôt.
            MainWindow.closeAll()
            updateActivationPolicy()
        }
    }

    /// Fenêtre fermée, Oust! reste ouvert : la barre de menus, l'alerte et les
    /// règles planifiées continuent de veiller.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let requester = FullDiskAccess.quitRequestSender() {
            log.notice("Quitter demandé par \(requester, privacy: .public)")
            if QuitSender.isSystemSettings(executable: requester) { FullDiskAccess.relaunchAfterExit() }
        }
        return .terminateNow
    }

    // MARK: Dock ou barre de menus

    private func observeWindows() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                let name = window.map { "\(type(of: $0)) \($0.identifier?.rawValue ?? "-")" } ?? "-"
                self?.log.debug("Fenêtre clé : \(name, privacy: .public)")
                self?.updateActivationPolicy()
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            // Pendant `willClose`, la fenêtre est encore visible : on regarde au tour suivant.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateActivationPolicy() } }
        })
    }

    /// Fenêtre fermée et barre de menus active, Oust! quitte le Dock et vit
    /// dans la barre de menus. Sans barre de menus, il garde son icône dans le
    /// Dock : sinon, plus rien ne permettrait de le retrouver. Les Réglages
    /// ouverts le gardent aussi : sans Dock ni menu, leur fenêtre se perdrait
    /// derrière les autres.
    func updateActivationPolicy() {
        let keepsDock = MainWindow.current != nil || SettingsWindow.current != nil || !model.watch.showsMenuBar
        let policy: NSApplication.ActivationPolicy = keepsDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}

/// Retient les actions d'ouverture de SwiftUI, pour rouvrir la fenêtre ou les
/// Réglages depuis la barre de menus ou une notification une fois qu'on l'a fermée.
private struct OpenWindowCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            MainWindow.opener = openWindow
            SettingsWindow.opener = openSettings
        }
    }
}

/// Comment Oust! a été ouvert.
@MainActor
enum LaunchContext {
    private static var known: Bool?

    /// macOS l'a ouvert à la connexion (« Ouvrir à la connexion ») : l'événement
    /// d'ouverture le dit. Retenu dès qu'on l'a vu passer ; avant, on ne sait pas.
    static var isLoginLaunch: Bool {
        if let known { return known }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication)
        else { return false }
        let atLogin = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
        known = atLogin
        return atLogin
    }
}

/// Le panneau « À propos » de macOS, avec les mentions de l'éditeur en liens.
@MainActor
enum AboutPanel {
    static func show() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString(string: L10n.string("about.publisher") + "\n", attributes: base)
        credits.append(link("blanc-conseil.fr", to: "https://blanc-conseil.fr", base: base))
        credits.append(NSAttributedString(string: "  ·  ", attributes: base))
        credits.append(link("daniel@blanc-conseil.fr", to: "mailto:daniel@blanc-conseil.fr", base: base))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): L10n.string("about.copyright"),
        ])
        NSApp.activate()
    }

    private static func link(_ text: String, to address: String, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = base
        attributes[.link] = URL(string: address)
        return NSAttributedString(string: text, attributes: attributes)
    }
}
