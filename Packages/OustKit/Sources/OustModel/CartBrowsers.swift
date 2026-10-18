import Foundation
import OustBrowsers
import OustCore

/// Un navigateur ouvert dont des éléments attendent dans la corbeille.
public struct OpenBrowser: Identifiable, Sendable, Equatable {
    /// `BrowserKind.rawValue`.
    public let id: String
    public let name: String
    /// Ce que ses éléments rendraient, une fois fermé.
    public let bytes: Int64
}

extension AppModel {

    /// Les navigateurs ouverts dont des éléments sont dans la corbeille : tant
    /// qu'ils le sont, ces éléments restent (SPEC §8). Relu à la demande, pas
    /// observé : la revue le relit quand une application s'ouvre ou se ferme.
    public func openBrowsersInCart() -> [OpenBrowser] {
        var bytes: [BrowserKind: Int64] = [:]
        for item in cartItems {
            if let browser = BrowserFinder.browser(of: item) { bytes[browser, default: 0] += item.sizes.freeable }
        }
        return BrowserKind.allCases.compactMap { browser in
            guard let total = bytes[browser], BrowserFinder.isRunning(browser) else { return nil }
            return OpenBrowser(id: browser.rawValue, name: browser.displayName, bytes: total)
        }
    }

    /// « Fermer Safari, nettoyer, puis le rouvrir » (Romain, 18/10/2026).
    ///
    /// Chaque navigateur ouvert dont des éléments sont dans la corbeille est
    /// prié de quitter, comme par ⌘Q, jamais forcé (`BrowserRestart`). Puis le
    /// vide de toute la corbeille, comme après une confirmation ordinaire, et
    /// enfin la réouverture de ceux qu'on a fermés, une fois le vide fini ou
    /// arrêté. Un navigateur qui a refusé de quitter garde ses éléments : la
    /// revalidation les écarte juste avant d'agir, et le bilan le dit.
    public func cleanClosingBrowsers() async {
        guard cleaning != .running, !cart.isEmpty else { return }
        let open = openBrowsersInCart().compactMap { BrowserKind(rawValue: $0.id) }
        let outcome = await BrowserRestart.close(open)
        guard cleaning != .running else {
            await BrowserRestart.reopen(outcome.closed)
            return
        }
        // La protection « ouvert », posée par l'analyse, ne vaut plus : c'est la
        // revalidation qui tranche, au moment d'agir, navigateur par navigateur.
        let inCart = Set(cartItems.compactMap(BrowserFinder.browser(of:)))
        let fresh = BrowserFinder.profiles(home: home).filter { inCart.contains($0.browser) }
            .flatMap { BrowserFinder.items(for: $0, isRunning: false) }
            .compactMap { item -> CleanupItem? in
                guard cart.contains(item.id), let known = items[item.id] else { return nil }
                var item = item
                item.sizes = known.sizes
                return item
            }
        refreshItems(fresh, addingToCart: false)
        startCleaning()
        guard !outcome.closed.isEmpty else { return }
        Task {
            while self.cleaning == .running { try? await Task.sleep(for: .milliseconds(250)) }
            await BrowserRestart.reopen(outcome.closed)
        }
    }
}
