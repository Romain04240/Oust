import Darwin
import Foundation
import OustClean
import OustCore
import OustSafety
import Testing
@testable import OustUninstall

@Suite("Veto par chemin des préférences")
struct PreferencePathVetoTests {
    @Test("Un suffixe équivalent sur APFS désigne le plist protégé")
    func alternateSuffix() async throws {
        let mac = try FakeMac()
        let plist = try mac.libraryItem("Preferences/org.fixture.synthetic.plist")
        let ordinary = try mac.libraryItem("Preferences/Unfichier.txt")
        let guardian = PathGuard(home: mac.home)
        #expect(guardian.protectsUserPreferences(plist))
        #expect(!guardian.protectsUserPreferences(ordinary))
        #expect(guardian.allows(ordinary))

        let alternate = plist.deletingLastPathComponent().appendingPathComponent("org.fixture.synthetic.pliſt")
        guard let alias = FileFacts.of(alternate.path) else { return }
        let original = try #require(FileFacts.of(plist.path))
        #expect(alias.device == original.device && alias.inode == original.inode)
        #expect(!guardian.allows(alternate))
        await expectTrashVeto(for: alternate, on: mac)
        #expect(FileManager.default.fileExists(atPath: plist.path))
    }

    @Test("Un ancêtre redirigé reste protégé sous une autre casse APFS")
    func alternateAncestor() async throws {
        let mac = try FakeMac()
        let parent = mac.home.appendingPathComponent("Other/CasedParent", isDirectory: true)
        let destination = parent.appendingPathComponent("Preferences", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let plist = destination.appendingPathComponent("org.fixture.synthetic.plist")
        try Data("plist fictif".utf8).write(to: plist)
        try fm.createSymbolicLink(at: mac.library.appendingPathComponent("Preferences"), withDestinationURL: destination)

        let guardian = PathGuard(home: mac.home)
        #expect(!guardian.allows(parent))
        let alternate = mac.home.appendingPathComponent("Other/cASEDpARENT")
        guard let alias = FileFacts.of(alternate.path) else { return }
        let original = try #require(FileFacts.of(parent.path))
        #expect(alias.device == original.device && alias.inode == original.inode)
        #expect(!guardian.allows(alternate))
        await expectTrashVeto(for: alternate, on: mac)
        #expect(fm.fileExists(atPath: plist.path))
    }

    @Test("Si Library devient inaccessible, la cible redirigée reste protégée",
          .enabled(if: geteuid() != 0))
    func unreadableLibrary() async throws {
        let mac = try FakeMac()
        let destination = mac.home.appendingPathComponent("Outside/Prefs", isDirectory: true)
        let plist = destination.appendingPathComponent("org.fixture.synthetic.plist")
        let ordinary = mac.home.appendingPathComponent("Outside/Ordinaire.txt")
        let text = "plist fictif"
        let fm = FileManager.default
        try mac.data(text, to: plist)
        try mac.data("fichier témoin", to: ordinary)
        let preferences = PreferenceDirectory.url(in: mac.home)
        try fm.createSymbolicLink(at: preferences, withDestinationURL: destination)
        let guardian = PathGuard(home: mac.home)
        #expect(!guardian.allows(plist))
        #expect(guardian.allows(ordinary))

        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: mac.library.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mac.library.path) }
        #expect(PreferenceDirectory(preferences.path).isUncertain)
        #expect(guardian.check(plist) == .refused("user-preferences"))
        #expect(!guardian.allows(ordinary))
        await expectTrashVeto(for: plist, on: mac)
        await expectTrashVeto(for: destination.deletingLastPathComponent(), on: mac)
        #expect(try String(contentsOf: plist, encoding: .utf8) == text)
        #expect(fm.fileExists(atPath: ordinary.path))

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mac.library.path)
        #expect(!PreferenceDirectory(preferences.path).isUncertain)
        #expect(!guardian.allows(plist))
        #expect(guardian.allows(ordinary))
    }

    private func expectTrashVeto(for url: URL, on mac: FakeMac) async {
        let item = CleanupItem(title: "Préférence fictive", paths: [url], category: .explorer,
                               owner: "", ruleID: "explorer.item", safety: .review, method: .trash, rebuild: .irreversible)
        var results: [OutcomeResult] = []
        for await event in mac.engine().run([item]) {
            if case .finished(let report) = event { results = report.outcomes.map(\.result) }
        }
        #expect(results == [.skipped(.refusedByGuard)])
    }
}
