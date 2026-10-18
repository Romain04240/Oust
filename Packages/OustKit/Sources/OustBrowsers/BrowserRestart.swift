import AppKit
import Foundation
import OustCore

/// Fermer un navigateur le temps de vider son cache, puis le rouvrir (Romain,
/// 18/10/2026) : « si on veut vider les caches des navigateurs, ça te propose
/// de fermer l'application et de la rouvrir ».
///
/// Un navigateur ouvert réécrit son cache pendant qu'on le retire (SPEC §8,
/// navigateur fermé exigé). On lui demande donc de quitter comme le ferait ⌘Q,
/// on attend un temps borné, et jamais on ne le force : un navigateur qui
/// refuse (un téléchargement en cours, un formulaire à enregistrer) a ses
/// raisons, et ses éléments restent. La revalidation de `CleanupEngine` les
/// écarte alors elle-même, et le bilan le dit.
@MainActor
public enum BrowserRestart {

    /// Ce qu'on demande à macOS ; un faux dans les tests, qui ne ferment rien.
    public struct Driver: Sendable {
        public var isRunning: @MainActor @Sendable (String) -> Bool
        /// Demande à chaque instance de quitter, comme ⌘Q, et rend l'emplacement
        /// de l'application pour la rouvrir ; `nil` si aucune n'a pu l'entendre.
        public var askToQuit: @MainActor @Sendable (String) -> URL?
        public var reopen: @MainActor @Sendable (URL, [String]) async -> Bool
        public var sleep: @Sendable (Duration) async -> Void

        public init(isRunning: @escaping @MainActor @Sendable (String) -> Bool,
                    askToQuit: @escaping @MainActor @Sendable (String) -> URL?,
                    reopen: @escaping @MainActor @Sendable (URL, [String]) async -> Bool,
                    sleep: @escaping @Sendable (Duration) async -> Void) {
            self.isRunning = isRunning
            self.askToQuit = askToQuit
            self.reopen = reopen
            self.sleep = sleep
        }
    }

    /// Un navigateur qu'on a fermé, et d'où le rouvrir.
    public struct Closed: Sendable, Equatable {
        public let browser: BrowserKind
        public let application: URL
    }

    public struct Outcome: Sendable, Equatable {
        public var closed: [Closed] = []
        /// Toujours ouverts au bout de l'attente : leurs éléments restent.
        public var refused: [BrowserKind] = []
    }

    /// Le temps laissé à un navigateur pour quitter. Chrome met deux ou trois
    /// secondes avec beaucoup d'onglets ; au-delà, il attend sans doute une
    /// réponse de l'utilisateur, qu'on ne donnera pas à sa place.
    public static let patience: Duration = .seconds(20)
    static let poll: Duration = .milliseconds(250)

    /// Demande aux navigateurs ouverts de quitter, tous à la fois, et attend
    /// qu'ils l'aient fait. Ceux qui étaient déjà fermés ne figurent nulle part :
    /// il n'y aura rien à rouvrir.
    public static func close(_ browsers: [BrowserKind], driver: Driver = .live,
                             patience: Duration = patience) async -> Outcome {
        // Chacun une fois, dans l'ordre donné, avec l'application d'où le rouvrir.
        var waiting: [(browser: BrowserKind, application: URL?)] = []
        for browser in browsers where !waiting.contains(where: { $0.browser == browser })
            && driver.isRunning(browser.bundleIdentifier) {
            waiting.append((browser, driver.askToQuit(browser.bundleIdentifier)))
        }
        var outcome = Outcome()
        var waited: Duration = .zero
        while true {
            // Une seule lecture par tour : un navigateur qui finit de quitter
            // entre deux lectures n'était ni compté fermé, ni rouvert.
            let gone = Set(waiting.filter { !driver.isRunning($0.browser.bundleIdentifier) }.map(\.browser))
            for one in waiting where gone.contains(one.browser) {
                // Parti avant qu'on ait pu le lui demander : on ne sait d'où le rouvrir.
                if let application = one.application {
                    outcome.closed.append(Closed(browser: one.browser, application: application))
                }
            }
            waiting.removeAll { gone.contains($0.browser) }
            guard !waiting.isEmpty, waited < patience else { break }
            await driver.sleep(poll)
            waited += poll
        }
        outcome.refused = waiting.map(\.browser)
        return outcome
    }

    /// Rouvre ce qu'on a fermé, sans voler le premier plan : le bilan du vide
    /// reste devant. Chrome et ses cousins reprennent leurs onglets ; Safari et
    /// Firefox selon leurs propres réglages.
    public static func reopen(_ closed: [Closed], driver: Driver = .live) async {
        for one in closed {
            _ = await driver.reopen(one.application, arguments(for: one.browser))
        }
    }

    /// `--restore-last-session` : un Chromium rouvre les onglets de la dernière
    /// session, quel que soit son réglage de démarrage. Safari et Firefox n'ont
    /// pas d'équivalent qu'on puisse passer à l'ouverture.
    static func arguments(for browser: BrowserKind) -> [String] {
        browser.isChromium ? ["--restore-last-session"] : []
    }
}

extension BrowserRestart.Driver {
    /// Le vrai Mac : `NSRunningApplication.terminate()` (jamais
    /// `forceTerminate()`), et `NSWorkspace` pour rouvrir.
    public static let live = BrowserRestart.Driver(
        isRunning: { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { !$0.isTerminated }
        },
        askToQuit: { identifier in
            var application: URL?
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            where !running.isTerminated {
                if running.terminate() { application = application ?? running.bundleURL }
            }
            return application
        },
        reopen: { url, arguments in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = arguments
            return (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil
        },
        sleep: { duration in try? await Task.sleep(for: duration) }
    )
}

extension BrowserFinder {
    /// Le navigateur d'un élément de la section Navigateurs, lu dans son
    /// identifiant (`browser.cache|chrome|/…/Default`).
    public static func browser(of item: CleanupItem) -> BrowserKind? {
        guard item.category == .browsers, item.ruleID.hasPrefix("browser.") else { return nil }
        let parts = item.id.split(separator: "|", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        return BrowserKind(rawValue: String(parts[1]))
    }

    /// Les caches de navigateurs à proposer, mesurés, comme si chaque navigateur
    /// était fermé : l'entretien les compte, et la revue proposera de fermer
    /// ceux qui sont ouverts. Seuls les caches : l'historique et les cookies
    /// restent « à examiner ».
    public static func caches(home: URL) -> [CleanupItem] {
        profiles(home: home).flatMap { items(for: $0, isRunning: false) }.filter { $0.ruleID == "browser.cache" }
    }
}
