import Foundation
import Testing
@testable import OustBrowsers
import OustCore
import OustSafety

/// Un faux Mac : des navigateurs qui quittent au bout de quelques tours, ou
/// jamais. Rien de réel n'est fermé ni ouvert.
@MainActor
final class FakeMac {
    /// Combien de lectures avant que le navigateur ait fini de quitter, une
    /// fois prié ; `nil` : il refuse.
    var quitsAfter: [String: Int?]
    var running: Set<String>
    private(set) var askedToQuit: [String] = []
    private(set) var reopened: [(URL, [String])] = []
    private(set) var sleeps = 0
    private var countdown: [String: Int] = [:]

    init(running: [String: Int?]) {
        quitsAfter = running
        self.running = Set(running.keys)
    }

    var driver: BrowserRestart.Driver {
        BrowserRestart.Driver(
            isRunning: { [self] identifier in
                guard running.contains(identifier) else { return false }
                if let left = countdown[identifier] {
                    if left <= 0 { running.remove(identifier); return false }
                    countdown[identifier] = left - 1
                }
                return true
            },
            askToQuit: { [self] identifier in
                askedToQuit.append(identifier)
                if let after = quitsAfter[identifier] ?? nil { countdown[identifier] = after }
                return URL(fileURLWithPath: "/Applications/\(identifier).app")
            },
            reopen: { [self] url, arguments in
                reopened.append((url, arguments))
                return true
            },
            sleep: { [self] _ in await MainActor.run { sleeps += 1 } }
        )
    }
}

@Suite("Fermer un navigateur, nettoyer, le rouvrir")
@MainActor
struct BrowserRestartTests {

    @Test("Prié de quitter, il quitte : fermé, et rouvert d'où il venait")
    func closesThenReopens() async {
        let mac = FakeMac(running: ["com.apple.Safari": 3])
        let outcome = await BrowserRestart.close([.safari], driver: mac.driver)
        #expect(outcome.closed.map(\.browser) == [.safari])
        #expect(outcome.refused.isEmpty)
        #expect(mac.askedToQuit == ["com.apple.Safari"])

        await BrowserRestart.reopen(outcome.closed, driver: mac.driver)
        #expect(mac.reopened.map(\.0.lastPathComponent) == ["com.apple.Safari.app"])
    }

    @Test("Il refuse : on attend un temps borné, on ne le force jamais, ses éléments restent")
    func refusesWithinPatience() async {
        let mac = FakeMac(running: ["com.google.Chrome": nil])
        let outcome = await BrowserRestart.close([.chrome], driver: mac.driver, patience: .seconds(2))
        #expect(outcome.closed.isEmpty)
        #expect(outcome.refused == [.chrome])
        // Une seule demande polie, puis l'attente : 2 s par pas de 250 ms.
        #expect(mac.askedToQuit == ["com.google.Chrome"])
        #expect(mac.sleeps == 8)
        #expect(mac.running.contains("com.google.Chrome"))
        // Rien à rouvrir : il n'a jamais été fermé.
        await BrowserRestart.reopen(outcome.closed, driver: mac.driver)
        #expect(mac.reopened.isEmpty)
    }

    @Test("Déjà fermé : ni demande, ni réouverture")
    func notRunning() async {
        let mac = FakeMac(running: [:])
        let outcome = await BrowserRestart.close([.firefox, .brave], driver: mac.driver)
        #expect(outcome == BrowserRestart.Outcome())
        #expect(mac.askedToQuit.isEmpty)
        #expect(mac.sleeps == 0)
    }

    @Test("Plusieurs à la fois : chacun prié une fois, chacun son sort")
    func several() async {
        let mac = FakeMac(running: ["com.apple.Safari": 1, "com.google.Chrome": nil, "com.brave.Browser": 4])
        let outcome = await BrowserRestart.close([.safari, .chrome, .brave, .safari], driver: mac.driver,
                                                 patience: .seconds(3))
        #expect(Set(outcome.closed.map(\.browser)) == [.safari, .brave])
        #expect(outcome.refused == [.chrome])
        #expect(mac.askedToQuit == ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser"])
    }

    @Test("Chrome et ses cousins reprennent leurs onglets ; Safari et Firefox, selon leurs réglages")
    func restoreArguments() async {
        let mac = FakeMac(running: ["com.google.Chrome": 0, "com.apple.Safari": 0, "org.mozilla.firefox": 0,
                                    "company.thebrowser.Browser": 0])
        let outcome = await BrowserRestart.close([.chrome, .safari, .firefox, .arc], driver: mac.driver)
        await BrowserRestart.reopen(outcome.closed, driver: mac.driver)
        let arguments = Dictionary(uniqueKeysWithValues: mac.reopened.map { ($0.0.lastPathComponent, $0.1) })
        #expect(arguments["com.google.Chrome.app"] == ["--restore-last-session"])
        #expect(arguments["company.thebrowser.Browser.app"] == ["--restore-last-session"])
        #expect(arguments["com.apple.Safari.app"] == [])
        #expect(arguments["org.mozilla.firefox.app"] == [])
    }
}

@Suite("Le navigateur d'un élément, et la garde au moment d'agir")
struct BrowserOwnershipTests {

    @Test("Chaque élément d'un profil dit à quel navigateur il appartient")
    func browserOfItem() throws {
        let home = try BrowserHome()
        try home.write("Library/Application Support/Google/Chrome/Default/History")
        try home.write("Library/Caches/Google/Chrome/Default/Cache/f")
        try home.write("Library/Safari/History.db")
        try home.write("Library/Caches/com.apple.Safari/Cache.db")
        let items = BrowserFinder.profiles(home: home.root).flatMap { BrowserFinder.items(for: $0, isRunning: false) }
        #expect(!items.isEmpty)
        for item in items {
            let browser = try #require(BrowserFinder.browser(of: item))
            #expect(item.owner.hasPrefix(browser.displayName))
        }
        let stranger = CleanupItem(title: "npm", paths: [], category: .packageCaches, owner: "npm", ruleID: "cache.npm",
                                   safety: .safe, method: .removeNow, rebuild: .automatic)
        #expect(BrowserFinder.browser(of: stranger) == nil)
    }

    @Test("Les caches comptés navigateur fermé : sans protection, et seulement les caches")
    func cachesAsIfClosed() throws {
        let home = try BrowserHome()
        try home.write("Library/Application Support/Google/Chrome/Default/History")
        try home.write("Library/Application Support/Google/Chrome/Default/Network/Cookies")
        try home.write("Library/Caches/Google/Chrome/Default/Cache/f")
        let caches = BrowserFinder.caches(home: home.root)
        #expect(caches.map(\.ruleID) == ["browser.cache"])
        #expect(caches.allSatisfy { $0.protections.isEmpty && $0.safety == .safe })
    }

    /// Chaque profil connu, de chaque navigateur, retrouve son navigateur dans
    /// la table de la revalidation : un navigateur ouvert garde ce qui est à lui.
    @Test("Navigateur ouvert au moment d'agir : ses éléments restent, quel que soit le navigateur")
    func revalidationKnowsEveryBrowser() throws {
        let home = try BrowserHome()
        let chromiums: [BrowserKind: String] = [
            .chrome: "Google/Chrome", .arc: "Arc/User Data", .brave: "BraveSoftware/Brave-Browser",
            .edge: "Microsoft Edge", .vivaldi: "Vivaldi", .opera: "com.operasoftware.Opera",
        ]
        for (browser, folder) in chromiums {
            try home.write("Library/Application Support/\(folder)/Default/History")
            try home.write("Library/Application Support/\(folder)/Default/Network/Cookies")
            try home.write("Library/Caches/\(BrowserKindTestPaths.cacheFolder(browser))/Default/Cache/f")
        }
        try home.write("Library/Safari/History.db")
        try home.write("Library/Caches/com.apple.Safari/Cache.db")
        try home.write("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        try home.write("Library/Application Support/Firefox/profiles.ini", "[Profile0]\nName=default\nPath=Profiles/abc.default\nIsRelative=1\n")
        try home.write("Library/Application Support/Firefox/Profiles/abc.default/places.sqlite")
        try home.write("Library/Application Support/Firefox/Profiles/abc.default/cookies.sqlite")
        try home.write("Library/Caches/Firefox/Profiles/abc.default/cache2/x")

        let profiles = BrowserFinder.profiles(home: home.root)
        #expect(Set(profiles.map(\.browser)) == Set(BrowserKind.allCases))
        for profile in profiles {
            for item in BrowserFinder.items(for: profile, isRunning: false) {
                let open = AppOwnership.runningOwner(ruleID: item.ruleID, paths: item.paths,
                                                     running: [profile.browser.bundleIdentifier])
                #expect(open == profile.browser.displayName, "\(item.id)")
                let closed = AppOwnership.runningOwner(ruleID: item.ruleID, paths: item.paths, running: ["com.spotify.client"])
                #expect(closed == nil, "\(item.id)")
            }
        }
    }
}

/// Les dossiers de cache des Chromium, relatifs à `Library/Caches`.
enum BrowserKindTestPaths {
    static func cacheFolder(_ browser: BrowserKind) -> String {
        browser.cacheRoot.replacingOccurrences(of: "Library/Caches/", with: "")
    }
}
