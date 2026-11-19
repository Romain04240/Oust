import Foundation
import Testing
import OustBrowsers
import OustCore
import OustRules
import OustScan
import OustSafety
@testable import OustModel

@Suite("La publication navigateur remplace ses seuls résultats") @MainActor
struct BrowserRefreshPublicationTests {
    @MainActor private struct Fixture {
        let root: URL
        let home: URL
        let profile: URL
        let keptFile: URL
        let boot: VolumeDescriptor
        let model: AppModel
        let contents = Data(repeating: 43, count: 16_384)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-browser-publication-\(UUID())")
                .resolvingSymlinksInPath()
            home = root.appendingPathComponent("home")
            let firefox = home.appendingPathComponent("Library/Application Support/Firefox")
            profile = firefox.appendingPathComponent("Profiles/fixture.default")
            keptFile = home.appendingPathComponent("keep.bin")
            let cache = home.appendingPathComponent("Library/Caches/Firefox/Profiles/fixture.default/cache.bin")
            for file in [profile.appendingPathComponent("places.sqlite"), profile.appendingPathComponent("cookies.sqlite"), cache, keptFile] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file)
            }
            try "[Profile0]\nName=ProfilFirefoxFixture\nIsRelative=1\nPath=Profiles/fixture.default\n"
                .write(to: firefox.appendingPathComponent("profiles.ini"), atomically: false, encoding: .utf8)
            boot = VolumeDescriptor(name: "Fictif", mountURL: home, scanRoot: home, isBoot: true,
                isInternal: true, isRemovable: false,
                capacity: Capacity(total: 1_000_000, available: 400_000, availableForImportantUsage: 500_000))
            model = AppModel(home: home, defaults: BrowserPublicationDefaults(),
                disk: DiskIndexModel(store: TreeStore(directory: root.appendingPathComponent("Index"))))
            model.volumes = [boot]
        }

        var kept: CleanupItem { otherItem(id: "tool.fixture.manual") }
        var prefixDecoy: CleanupItem { otherItem(id: "browser.cache|another-tool") }
        var registry: URL { home.appendingPathComponent("Library/Application Support/Firefox/profiles.ini") }

        func context() -> RuleContext {
            RuleContext(home: home, projectRoots: [], processes: ProcessSnapshot(processes: []),
                applications: root, systemLibrary: root, sharedFolder: root, temporaryDirectory: root, runningApps: [])
        }

        func otherItem(id: String) -> CleanupItem {
            CleanupItem(id: id, title: "Choix manuel", paths: [keptFile], category: .toolVersions,
                owner: "Fixture", ruleID: "tool.brew_cleanup", safety: .safe,
                method: .brewCleanup(executable: home.appendingPathComponent("bin/brew").path),
                sizes: .zero, rebuild: .nothing)
        }

        func snapshot() async -> BrowserAnalysisSnapshot {
            let inventory = BrowserFinder.inventory(home: home)
            let profiles = inventory.profiles
            var rows = profiles.flatMap { BrowserFinder.items(for: $0, isRunning: false) }
            let measures = await Scanner.measure(rows.flatMap(\.paths), options: ScanOptions(leafThreshold: .max))
            for index in rows.indices {
                rows[index].sizes = rows[index].paths.compactMap { measures[$0]?.sizes }.total()
            }
            return BrowserAnalysisSnapshot(profiles: profiles, items: rows, unavailableBrowsers: inventory.unavailableBrowsers)
        }

        func publish(_ snapshot: BrowserAnalysisSnapshot) async throws {
            let pending = model.startBrowserRefresh(read: { snapshot }, readRunningBrowsers: { [] })
            let work = try #require(pending)
            await work.value
        }

        func selectOtherItems() {
            for item in [kept, prefixDecoy] { model.toggle(item) }
        }

        func expectKeptFile() throws {
            #expect(try Data(contentsOf: keptFile) == contents)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Un profil Firefox retiré disparaît des profils, résultats, recherches, totaux et choix")
    func removedProfileDisappears() async throws {
        let f = try Fixture(); defer { f.remove() }
        let original = await f.snapshot()
        #expect(original.profiles.count == 1 && original.items.count == 3)
        let history = try #require(original.items.first { $0.ruleID == "browser.history" })
        try await f.publish(original)
        #expect(f.model.cart.isEmpty && f.model.canSelectForCleanup(history))
        f.model.toggle(history)
        f.selectOtherItems()
        f.model.searchText = "ProfilFirefoxFixture"
        #expect(Set(f.model.searchResults.map(\.id)) == Set(original.items.map(\.id)))
        #expect(f.model.total(of: [.browsers], headlineOnly: false) > 0)
        #expect(f.model.cart == [history.id, f.kept.id, f.prefixDecoy.id])

        try FileManager.default.removeItem(at: f.profile)
        let removed = await f.snapshot()
        #expect(removed.profiles.isEmpty && removed.items.isEmpty)
        try await f.publish(removed)

        #expect(f.model.browserProfiles.isEmpty && f.model.items(in: [.browsers]).isEmpty)
        #expect(original.items.allSatisfy { f.model.items[$0.id] == nil })
        #expect(f.model.searchResults.isEmpty && f.model.total(of: [.browsers], headlineOnly: false) == 0)
        #expect(f.model.items == [f.kept.id: f.kept, f.prefixDecoy.id: f.prefixDecoy])
        #expect(f.model.cart == [f.kept.id, f.prefixDecoy.id] && f.model.cleaning == .idle)
        try f.expectKeptFile()
    }

    @Test("La publication conserve le choix vivant ou retire son nouveau veto sans le ressusciter",
          arguments: ["selected", "unchecked", "protected"])
    func liveSelections(_ change: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let original = await f.snapshot()
        let history = try #require(original.items.first { $0.ruleID == "browser.history" })
        try await f.publish(original)
        f.model.toggle(history)
        f.selectOtherItems()
        var fresh = original
        if change == "unchecked" { f.model.toggle(history) }
        if change == "protected", let index = fresh.items.firstIndex(where: { $0.id == history.id }) {
            fresh.items[index].protect(.appRunning(name: "Firefox"))
        }
        try await f.publish(fresh)
        let expected: Set<String> = change == "selected" ? [history.id, f.kept.id, f.prefixDecoy.id]
            : [f.kept.id, f.prefixDecoy.id]
        #expect(f.model.cart == expected && f.model.browserProfiles == original.profiles)
        #expect(f.model.items[f.kept.id] == f.kept && f.model.items[f.prefixDecoy.id] == f.prefixDecoy)
        if change == "protected" {
            let protected = try #require(f.model.items[history.id])
            #expect(!f.model.canSelectForCleanup(protected))
            f.model.toggle(protected)
            #expect(f.model.cart == expected)
        }
        try await f.publish(original)
        #expect(f.model.cart == expected && f.model.cleaning == .idle)
        #expect(try Data(contentsOf: f.profile.appendingPathComponent("places.sqlite")) == f.contents)
        try f.expectKeptFile()
    }

    @Test("Une collision ou un résultat étranger ne remplace pas un autre outil")
    func foreignItemsRemainUntouched() async throws {
        let f = try Fixture(); defer { f.remove() }
        let original = await f.snapshot()
        let history = try #require(original.items.first { $0.ruleID == "browser.history" })
        try await f.publish(original)
        let collision = f.otherItem(id: history.id)
        f.model.items[collision.id] = collision
        f.model.toggle(collision)
        f.selectOtherItems()
        let foreign = f.otherItem(id: "tool.fixture.unexpected")
        var fresh = original
        fresh.items.append(foreign)
        try await f.publish(fresh)
        #expect(f.model.items[collision.id] == collision && f.model.items[foreign.id] == nil)
        #expect(f.model.items[f.kept.id] == f.kept && f.model.items[f.prefixDecoy.id] == f.prefixDecoy)
        #expect(f.model.cart == [collision.id, f.kept.id, f.prefixDecoy.id])
        #expect(f.model.cleaning == .idle)
        try f.expectKeptFile()
    }

    @Test("Une lecture annulée, indisponible ou écartée par l’analyse ne purge rien",
          arguments: ["cancelled", "unavailable", "boot"])
    func rejectedReadDoesNotPurge(_ reason: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let original = await f.snapshot()
        let history = try #require(original.items.first { $0.ruleID == "browser.history" })
        try await f.publish(original)
        f.model.toggle(history)
        f.selectOtherItems()
        let beforeItems = f.model.items, beforeCart = f.model.cart
        let gate = BrowserPublicationGate(); defer { gate.release() }
        let answer: BrowserAnalysisSnapshot? = reason == "unavailable" ? nil : BrowserAnalysisSnapshot(profiles: [], items: [])
        let pending = f.model.startBrowserRefresh(read: { await gate.wait(); return answer }, readRunningBrowsers: { [] })
        let work = try #require(pending)
        try await gate.waitUntilEntered()
        if reason == "cancelled" { work.cancel() }
        if reason == "boot" { _ = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false)) }
        defer { f.model.bootAnalysisRequest = nil; f.model.analysis = .idle }
        gate.release(); await work.value
        #expect(f.model.items == beforeItems && f.model.cart == beforeCart)
        #expect(f.model.browserProfiles == original.profiles && f.model.cleaning == .idle)
        try f.expectKeptFile()
    }

    @Test("Une réponse périmée ne purge pas les choix avant la publication de sa relève")
    func supersededReadDoesNotPurge() async throws {
        let f = try Fixture(); defer { f.remove() }
        let original = await f.snapshot()
        let history = try #require(original.items.first { $0.ruleID == "browser.history" })
        try await f.publish(original)
        f.model.toggle(history)
        f.selectOtherItems()
        let beforeItems = f.model.items, beforeCart = f.model.cart
        let oldGate = BrowserPublicationGate(), newGate = BrowserPublicationGate()
        defer { oldGate.release(); newGate.release() }
        let pendingOld = f.model.startBrowserRefresh(read: {
            await oldGate.wait()
            return BrowserAnalysisSnapshot(profiles: [], items: [])
        }, readRunningBrowsers: { [] })
        let old = try #require(pendingOld)
        try await oldGate.waitUntilEntered()
        let pendingNew = f.model.startBrowserRefresh(read: { await newGate.wait(); return original }, readRunningBrowsers: { [] })
        let current = try #require(pendingNew)
        oldGate.release(); await old.value
        try await newGate.waitUntilEntered()
        #expect(f.model.items == beforeItems && f.model.cart == beforeCart)
        #expect(f.model.browserProfiles == original.profiles)
        newGate.release(); await current.value
        #expect(f.model.items == beforeItems && f.model.cart == beforeCart && f.model.cleaning == .idle)
        #expect(try Data(contentsOf: f.profile.appendingPathComponent("places.sqlite")) == f.contents)
        try f.expectKeptFile()
    }

    @Test("Le doute conserve le choix sous veto puis exige un nouveau choix après lecture complète",
          arguments: ["refresh", "boot", "remove", "clear"])
    func unavailableSuspendsWithoutReactivation(_ path: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let original = await f.snapshot()
        let history = try #require(original.items.first { $0.ruleID == "browser.history" })
        try await f.publish(original)
        f.model.toggle(history); f.selectOtherItems()
        try FileManager.default.removeItem(at: f.registry)
        try FileManager.default.createDirectory(at: f.registry, withIntermediateDirectories: false)
        let unavailable = await f.snapshot()
        #expect(unavailable.unavailableBrowsers == [.firefox])
        if path == "boot" {
            let request = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false))
            await f.model.runBootAnalysis(request, context: f.context(), finders: [],
                readBrowsers: { unavailable }, readRunningBrowsers: { [] })
        } else { try await f.publish(unavailable) }
        let protected = try #require(f.model.items[history.id])
        #expect(f.model.unavailableBrowserInventories == [.firefox] && f.model.browserProfiles == original.profiles)
        #expect(protected.protections.contains(.unknownState) && protected.sizes.freeable == 0)
        #expect(!f.model.canSelectForCleanup(protected) && f.model.total(of: [.browsers], headlineOnly: false) == 0)
        #expect(f.model.cart.contains(history.id) && !f.model.cartItems.contains { $0.id == history.id })
        #expect(f.model.suspendedBrowserSelectionCount == 1 && f.model.cleaning == .idle)
        f.model.toggle(protected)
        #expect(f.model.cart.contains(history.id))
        if path == "remove" { f.model.remove([history.id]) }
        if path == "clear" { f.model.clearCart() }
        try await f.publish(original)
        #expect(f.model.unavailableBrowserInventories.isEmpty && f.model.suspendedBrowserSelectionCount == 0)
        let restored = try #require(f.model.items[history.id])
        #expect(!f.model.cart.contains(history.id) && f.model.canSelectForCleanup(restored))
        if path == "refresh" || path == "remove" { #expect(f.model.cart == [f.kept.id, f.prefixDecoy.id]) }
        if path == "clear" { #expect(f.model.cart.isEmpty) }
        f.model.toggle(history)
        #expect(f.model.cart.contains(history.id))
        #expect(try Data(contentsOf: f.profile.appendingPathComponent("places.sqlite")) == f.contents)
        try f.expectKeptFile()
    }

    @Test("L'indisponibilité Firefox n'empêche pas le retrait confirmé d'un profil Chrome")
    func readableBrowserStillPublishes() async throws {
        let f = try Fixture(); defer { f.remove() }
        let chrome = f.home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try f.contents.write(to: chrome.appendingPathComponent("History"))
        let original = await f.snapshot()
        #expect(Set(original.profiles.map(\.browser)) == [.chrome, .firefox])
        try await f.publish(original)
        let history = try #require(original.items.first { $0.ruleID == "browser.history" && BrowserFinder.browser(of: $0) == .firefox })
        f.model.toggle(history); f.selectOtherItems()
        try FileManager.default.removeItem(at: chrome)
        try FileManager.default.removeItem(at: f.registry)
        try FileManager.default.createDirectory(at: f.registry, withIntermediateDirectories: false)
        try await f.publish(await f.snapshot())
        #expect(f.model.browserProfiles.map(\.browser) == [.firefox])
        #expect(!f.model.items.values.contains { BrowserFinder.browser(of: $0) == .chrome })
        #expect(f.model.cart == [history.id, f.kept.id, f.prefixDecoy.id])
        #expect(f.model.cartItems.allSatisfy { $0.category != .browsers })
        try f.expectKeptFile()
    }

    @Test("Un navigateur ouvert après la mesure est protégé au dernier point de publication",
          arguments: ["refresh", "boot"])
    func runningBrowserIsRechecked(_ path: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let original = await f.snapshot()
        let history = try #require(original.items.first { $0.ruleID == "browser.history" })
        try await f.publish(original)
        f.model.toggle(history)
        var fresh = original
        let index = try #require(fresh.items.firstIndex { $0.id == history.id })
        fresh.items[index].protect(.inUse)
        let snapshot = fresh
        let gate = BrowserPublicationGate(); defer { gate.release() }
        let work: Task<Void, Never>
        if path == "boot" {
            let request = try #require(f.model.reserveBootAnalysis(f.boot, preselect: false))
            work = Task { await f.model.runBootAnalysis(request, context: f.context(), finders: [],
                readBrowsers: { await gate.wait(); return snapshot }, readRunningBrowsers: { gate.running }) }
        } else {
            let pending = f.model.startBrowserRefresh(read: { await gate.wait(); return snapshot },
                readRunningBrowsers: { gate.running })
            work = try #require(pending)
        }
        try await gate.waitUntilEntered()
        gate.running = [.firefox]
        gate.release(); await work.value
        let published = try #require(f.model.items[history.id])
        #expect(published.protections.contains(.inUse))
        #expect(published.protections.contains(.appRunning(name: "Firefox")))
        #expect(!f.model.canSelectForCleanup(published) && !f.model.cart.contains(history.id))
        #expect(f.model.cleaning == .idle)
        try f.expectKeptFile()
    }

    @Test("Un résultat indéterminé annulé ou périmé ne publie aucun statut ni veto",
          arguments: ["cancelled", "superseded"])
    func rejectedUnknownDoesNotPublish(_ reason: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let original = await f.snapshot()
        try await f.publish(original)
        let history = try #require(original.items.first { $0.ruleID == "browser.history" })
        f.model.toggle(history)
        let before = f.model.items, choices = f.model.cart
        let gate = BrowserPublicationGate(); defer { gate.release() }
        let pending = f.model.startBrowserRefresh(read: {
            await gate.wait()
            return BrowserAnalysisSnapshot(profiles: [], items: [], unavailableBrowsers: [.firefox])
        }, readRunningBrowsers: { [.firefox] })
        let work = try #require(pending)
        try await gate.waitUntilEntered()
        var newer: Task<Void, Never>?
        if reason == "cancelled" { work.cancel() }
        else { newer = f.model.startBrowserRefresh(read: { original }, readRunningBrowsers: { [] }) }
        gate.release(); await work.value; await newer?.value
        #expect(f.model.items == before && f.model.cart == choices)
        #expect(f.model.unavailableBrowserInventories.isEmpty && f.model.suspendedBrowserSelectionCount == 0)
        try f.expectKeptFile()
    }
}

@MainActor private final class BrowserPublicationGate {
    var running = Set<BrowserKind>()
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(entered)
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private final class BrowserPublicationDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey key: String) -> Any? { nil }
    override func data(forKey key: String) -> Data? { nil }
    override func stringArray(forKey key: String) -> [String]? { nil }
    override func bool(forKey key: String) -> Bool { false }
    override func set(_ value: Any?, forKey key: String) {}
}
