import Foundation
import OustCore
import OustSafety
import Testing
@testable import OustUninstall

@Suite("Restes réévalués après une redirection des préférences")
struct PreferenceLeftoverRecheckTests {
    @Test("Un reste orphelin devient protégé si Preferences change après la mesure")
    func orphanRedirectedDuringMeasurement() async throws {
        let fixture = try Fixture()
        let mac = fixture.mac
        let found = OrphanTests().orphans(mac)
        let initial = try #require(found.flatMap(\.leftovers).first { $0.url.path == fixture.leftover.path })
        #expect(initial.protection == nil)
        let measured = await OrphanFinder.measured(found, canReadContainers: true, recencyDays: 0,
                                                   openPaths: fixture.redirectDuringMeasurement, holder: { _ in nil })
        #expect(!PathGuard(home: mac.home).allows(fixture.leftover))
        let group = try #require(measured.first { $0.identifier == "com.fixture.app" })
        try fixture.expectProtected(in: group.leftovers.map { $0.cleanupItem(in: group) })
        #expect(group.freeable > 0)
    }

    @Test("Le désinstalleur revérifie les restes découverts avant la redirection")
    func installedRedirectedAfterDiscovery() async throws {
        let fixture = try Fixture()
        let mac = fixture.mac
        try mac.app("Fictif.app", id: "com.fixture.app")
        let installed = mac.installed()
        let app = try #require(installed.first)
        let found = LeftoverFinder.leftovers(of: app, among: installed, home: mac.home)
        let initial = try #require(found.first { $0.url.path == fixture.leftover.path })
        #expect(initial.protection == nil)
        try FileManager.default.createSymbolicLink(at: fixture.preferences, withDestinationURL: fixture.destination)
        let measured = await LeftoverFinder.measured(found)
        try fixture.expectProtected(in: measured.map { $0.cleanupItem(for: app) })
    }

    @Test("Les restes d'une app jetée tiennent compte d'une redirection après la mesure")
    func trashedRedirectedDuringMeasurement() async throws {
        let fixture = try Fixture()
        let mac = fixture.mac
        try mac.app("Fictif.app", id: "com.fixture.app")
        let trashTests = TrashedAppTests()
        let appURL = try trashTests.trash(mac, "Fictif.app")
        let found = try trashTests.offer(try trashTests.examine(mac, appURL))
        let initial = try #require(found.leftovers.first { $0.url.path == fixture.leftover.path })
        #expect(initial.protection == nil)
        let measured = await TrashedAppFinder.measured(found, recencyDays: 7,
                                                        openPaths: fixture.redirectDuringMeasurement, holder: { _ in nil })
        try fixture.expectProtected(in: measured.items)
        #expect(measured.freeable > 0)
    }

    private struct Fixture {
        let mac: FakeMac
        let leftover: URL
        let destination: URL
        let preferences: URL
        let control: URL

        init() throws {
            let mac = try FakeMac()
            self.mac = mac
            leftover = try mac.libraryItem("Application Support/com.fixture.app", directory: true, bytes: 180_000)
            destination = leftover.appendingPathComponent("Réglages")
            preferences = mac.library.appendingPathComponent("Preferences")
            control = try mac.libraryItem("Saved Application State/com.fixture.app.savedState", directory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        var redirectDuringMeasurement: @Sendable (URL) -> Set<String> {
            { [preferences, destination] _ in
                do { try FileManager.default.createSymbolicLink(at: preferences, withDestinationURL: destination) }
                catch { Issue.record("Impossible de rediriger les préférences fictives : \(error)") }
                return []
            }
        }

        func expectProtected(in items: [CleanupItem]) throws {
            let protected = try #require(items.first { $0.paths.first?.path == leftover.path })
            let unaffected = try #require(items.first { $0.paths.first?.path == control.path })
            #expect(protected.protections == [.systemPath] && !protected.isSelectable)
            #expect(protected.sizes.allocated > 0 && protected.sizes.freeable == 0)
            #expect(unaffected.isSelectable && unaffected.sizes.freeable > 0)
        }
    }
}
