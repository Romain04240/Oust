import Darwin
import Foundation
import Testing
@testable import OustBrowsers

@Suite("Disponibilité de l’inventaire Firefox")
struct BrowserInventoryAvailabilityTests {
    @Test("Un registre absent confirmé retire les profils sans rendre Firefox indisponible")
    func missingRegistry() throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.ini)
        let inventory = BrowserFinder.inventory(home: f.root)
        #expect(!inventory.unavailableBrowsers.contains(.firefox))
        #expect(inventory.profiles.filter { $0.browser == .firefox }.isEmpty)
        try f.expectChromeUnchanged(inventory)
    }

    @Test("Un registre remplacé ou incohérent n’est pas une preuve d’absence",
          arguments: ["directory", "invalid-utf8", "truncated-section", "conflicting-path", "invalid-relative", "missing-path"])
    func invalidRegistry(_ variant: String) throws {
        let f = try Fixture(); defer { f.remove() }
        switch variant {
        case "directory":
            try FileManager.default.removeItem(at: f.ini)
            try FileManager.default.createDirectory(at: f.ini, withIntermediateDirectories: false)
        case "invalid-utf8":
            try Data([0xff, 0xfe, 0xff]).write(to: f.ini)
        case "truncated-section":
            try "[Profile0\nName=Fixture\nPath=Profiles/fixture.default\n".write(to: f.ini, atomically: true, encoding: .utf8)
        case "conflicting-path":
            try (Fixture.registry + "Path=Profiles/other.default\n").write(to: f.ini, atomically: true, encoding: .utf8)
        case "invalid-relative":
            try "[Profile0]\nIsRelative=2\nPath=Profiles/fixture.default\n".write(to: f.ini, atomically: true, encoding: .utf8)
        default:
            try "[Profile0]\nName=Fixture\nIsRelative=1\n".write(to: f.ini, atomically: true, encoding: .utf8)
        }
        let inventory = BrowserFinder.inventory(home: f.root)
        #expect(inventory.unavailableBrowsers == [.firefox])
        #expect(inventory.profiles.filter { $0.browser == .firefox }.isEmpty)
        try f.expectChromeUnchanged(inventory)
    }

    @Test("Une erreur de permission reste indisponible, jamais assimilée à un retrait",
          .enabled(if: geteuid() != 0), arguments: ["registry", "profile"])
    func unreadableLocation(_ variant: String) throws {
        let f = try Fixture(); defer { f.remove() }
        let location = variant == "registry" ? f.ini : f.profile
        let restored: mode_t = variant == "registry" ? 0o600 : 0o700
        defer { #expect(chmod(location.path, restored) == 0) }
        try #require(chmod(location.path, 0o000) == 0)
        let inventory = BrowserFinder.inventory(home: f.root)
        #expect(inventory.unavailableBrowsers == [.firefox])
        #expect(inventory.profiles.filter { $0.browser == .firefox }.isEmpty)
        try f.expectChromeUnchanged(inventory)
    }

    @Test("Un profil retiré confirmé diffère d’un profil remplacé par un fichier", arguments: [false, true])
    func removedOrReplacedProfile(_ replaced: Bool) throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.profile)
        if replaced { try Data([23]).write(to: f.profile) }
        let inventory = BrowserFinder.inventory(home: f.root)
        #expect(inventory.unavailableBrowsers.contains(.firefox) == replaced)
        #expect(inventory.profiles.filter { $0.browser == .firefox }.isEmpty)
        try f.expectChromeUnchanged(inventory)
    }

    @Test("Retirer places.sqlite conserve le profil et ses autres données")
    func removedHistoryDatabase() throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.places)
        let inventory = BrowserFinder.inventory(home: f.root)
        #expect(!inventory.unavailableBrowsers.contains(.firefox))
        let profile = try #require(inventory.profiles.first { $0.browser == .firefox })
        #expect(profile.folder == f.profile && profile.historyDatabase == nil)
        #expect(profile.cookies == [f.profile.appendingPathComponent("cookies.sqlite")])
        #expect(profile.caches == [f.cache])
        try f.expectChromeUnchanged(inventory)
    }

    @Test("Un chemin places.sqlite devenu dossier ou lien ne confirme pas son retrait", arguments: [false, true])
    func replacedHistoryDatabase(_ symlink: Bool) throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.places)
        if symlink {
            try FileManager.default.createSymbolicLink(at: f.places,
                                                       withDestinationURL: f.profile.appendingPathComponent("absent.sqlite"))
        } else {
            try FileManager.default.createDirectory(at: f.places, withIntermediateDirectories: false)
        }
        let inventory = BrowserFinder.inventory(home: f.root)
        #expect(inventory.unavailableBrowsers == [.firefox])
        #expect(inventory.profiles.filter { $0.browser == .firefox }.isEmpty)
        try f.expectChromeUnchanged(inventory)
    }

    private struct Fixture {
        static let registry = "[Profile0]\nName=Fixture\nIsRelative=1\nPath=Profiles/fixture.default\n"
        let root: URL
        let ini: URL
        let profile: URL
        let places: URL
        let cache: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("oust-browser-inventory-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
            let firefox = root.appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
            let profile = firefox.appendingPathComponent("Profiles/fixture.default", isDirectory: true)
            let cache = root.appendingPathComponent("Library/Caches/Firefox/Profiles/fixture.default", isDirectory: true)
            self.root = root
            self.ini = firefox.appendingPathComponent("profiles.ini")
            self.profile = profile
            self.places = profile.appendingPathComponent("places.sqlite")
            self.cache = cache
            do {
                for folder in [profile, cache] {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                }
                try Self.registry.write(to: ini, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ini.path)
                for relative in [
                    "Library/Application Support/Firefox/Profiles/fixture.default/places.sqlite",
                    "Library/Application Support/Firefox/Profiles/fixture.default/cookies.sqlite",
                    "Library/Caches/Firefox/Profiles/fixture.default/cache2/document.txt",
                    "Library/Application Support/Google/Chrome/Default/History",
                    "Library/Application Support/Google/Chrome/Default/Network/Cookies",
                    "Library/Application Support/Google/Chrome/Default/Code Cache/document.txt",
                ] {
                    let url = root.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(repeating: 23, count: 32).write(to: url)
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func expectChromeUnchanged(_ inventory: BrowserProfileInventory) throws {
            #expect(!inventory.unavailableBrowsers.contains(.chrome))
            let profiles = inventory.profiles.filter { $0.browser == .chrome }
            #expect(profiles.count == 1)
            let profile = try #require(profiles.first)
            let folder = root.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
            #expect(profile.folder == folder && profile.name == "Default")
            #expect(profile.history == [folder.appendingPathComponent("History")])
            #expect(profile.cookies == [folder.appendingPathComponent("Network/Cookies")])
            #expect(profile.caches == [folder.appendingPathComponent("Code Cache")])
            for url in profile.history + profile.cookies + [folder.appendingPathComponent("Code Cache/document.txt")] {
                #expect(try Data(contentsOf: url) == Data(repeating: 23, count: 32))
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
