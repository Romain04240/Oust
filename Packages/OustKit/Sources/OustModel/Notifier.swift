import AppKit
import Foundation
import os
import OustCore
@preconcurrency import UserNotifications

/// Ce que macOS permet à Oust! en matière de notifications.
public enum NotificationPermission: Sendable, Equatable {
    case unknown
    case notDetermined
    case allowed
    case denied
}

/// Les notifications locales d'Oust! : posées par le Mac, pour le Mac. Rien ne
/// sort (RULES.md, règle 11).
@MainActor
enum Notifier {
    private static var center: UNUserNotificationCenter { .current() }
    /// Un refus de macOS ne se voit pas à l'écran : on le note dans le journal
    /// système (`log show --predicate 'subsystem == "fr.meaillais.oust"'`).
    private static let log = Logger(subsystem: "fr.meaillais.oust", category: "notifications")

    static func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    /// Demande la permission si macOS ne l'a encore jamais posée, et rend l'état.
    static func ensurePermission() async -> NotificationPermission {
        let current = await permission()
        guard current == .notDetermined else { return current }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            log.notice("Permission demandée : \(granted ? "accordée" : "refusée", privacy: .public)")
        } catch {
            log.error("Demande de permission en échec : \(error.localizedDescription, privacy: .public)")
        }
        return await permission()
    }

    /// Une notification tout de suite. Le même identifiant remplace la
    /// précédente : deux alertes de disque bas ne s'empilent pas. `action` est
    /// rendue à l'app quand on la clique, avant d'ouvrir la destination
    /// (l'entretien y remplit la corbeille) ; `focus` dit ce qu'il faut montrer
    /// une fois la section ouverte (`NotificationRouter.focusHandler`).
    static func post(id: String, title: String, body: String, opening section: AppSection, sound: Bool,
                     action: String? = nil, focus: String? = nil) async {
        await post(id: id, title: title, body: body, opening: .section(section), sound: sound,
                   action: action, focus: focus)
    }

    /// Une notification qui mène où l'on veut, un onglet des Réglages compris.
    static func post(id: String, title: String, body: String, opening destination: Destination, sound: Bool,
                     action: String? = nil, focus: String? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = destination.userInfo
        if let action { content.userInfo[NotificationRouter.actionKey] = action }
        if let focus { content.userInfo[NotificationRouter.focusKey] = focus }
        if sound { content.sound = .default }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            log.notice("Notification posée : \(id, privacy: .public)")
        } catch {
            log.error("Notification \(id, privacy: .public) en échec : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Retire une notification devenue sans objet du centre de notifications.
    static func remove(id: String) async {
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Le panneau des notifications d'Oust! dans Réglages Système.
    static func openSettings() {
        let identifier = Bundle.main.bundleIdentifier ?? "fr.meaillais.oust"
        let deep = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)")
        let fallback = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        if let deep, NSWorkspace.shared.open(deep) { return }
        if let fallback { NSWorkspace.shared.open(fallback) }
    }
}

/// Montre les notifications même quand Oust! est au premier plan, et ouvre la
/// bonne section, ou le bon onglet des Réglages, quand on en clique une.
public final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let actionKey = "action"
    static let focusKey = "focus"
    /// Ce qu'une notification montre en plus de sa section (la revue d'une
    /// application mise à la corbeille du Mac), posé par le modèle qui l'envoie.
    @MainActor static var focusHandler: (@MainActor (String) -> Void)?

    private let open: @MainActor @Sendable (Destination) -> Void
    private let perform: @MainActor @Sendable (String) -> Void

    public init(open: @escaping @MainActor @Sendable (Destination) -> Void,
                perform: @escaping @MainActor @Sendable (String) -> Void = { _ in }) {
        self.open = open
        self.perform = perform
    }

    /// À poser au lancement, avant qu'une notification cliquée ne relance l'app.
    @MainActor
    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if let action = userInfo[Self.actionKey] as? String { await perform(action) }
        await open(Destination(userInfo: userInfo))
        if let focus = userInfo[Self.focusKey] as? String { await MainActor.run { Self.focusHandler?(focus) } }
    }
}
