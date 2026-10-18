import Foundation
import Testing
@testable import OustBrowsers
import OustCore

final class BrowserHome {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-browsers-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ relative: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

@Suite("Navigateurs")
struct BrowserTests {

    @Test("Profils Chrome nommés comme dans le navigateur, sans mots de passe ni cartes")
    func chromeProfiles() throws {
        let home = try BrowserHome()
        let base = "Library/Application Support/Google/Chrome"
        try home.write("\(base)/Local State", #"{"profile":{"info_cache":{"Default":{"name":"Perso"},"Profile 1":{"name":"Travail"}}}}"#)
        for profile in ["Default", "Profile 1"] {
            try home.write("\(base)/\(profile)/History")
            try home.write("\(base)/\(profile)/Network/Cookies")
            try home.write("\(base)/\(profile)/Login Data")
            try home.write("\(base)/\(profile)/Web Data")
            try home.write("\(base)/\(profile)/Code Cache/js/a")
        }
        try home.write("Library/Caches/Google/Chrome/Default/Cache/f")

        let profiles = BrowserFinder.profiles(of: .chrome, home: home.root)

        #expect(profiles.map(\.name) == ["Perso", "Travail"])
        let perso = try #require(profiles.first)
        let all = (perso.caches + perso.history + perso.cookies).map(\.lastPathComponent)
        #expect(!all.contains("Login Data"))
        #expect(!all.contains("Web Data"))
        #expect(perso.history.map(\.lastPathComponent) == ["History"])
        #expect(perso.cookies.map(\.lastPathComponent) == ["Cookies"])
        #expect(perso.caches.count == 2)
    }

    @Test("Seul le cache est sûr ; historique et cookies sont à examiner")
    func itemSafety() throws {
        let home = try BrowserHome()
        let base = "Library/Application Support/BraveSoftware/Brave-Browser"
        try home.write("\(base)/Default/History")
        try home.write("\(base)/Default/Network/Cookies")
        try home.write("\(base)/Default/GPUCache/a")
        let profile = try #require(BrowserFinder.profiles(of: .brave, home: home.root).first)

        let items = BrowserFinder.items(for: profile, isRunning: false)

        #expect(items.map(\.ruleID) == ["browser.cache", "browser.history", "browser.cookies"])
        #expect(items.map(\.safety) == [.safe, .review, .review])
        #expect(items.filter { PreselectionPolicy().preselects($0) }.map(\.ruleID) == ["browser.cache"])
    }

    @Test("Un navigateur ouvert protège tout son profil")
    func runningProtects() throws {
        let home = try BrowserHome()
        try home.write("Library/Application Support/Vivaldi/Default/History")
        let profile = try #require(BrowserFinder.profiles(of: .vivaldi, home: home.root).first)

        let items = BrowserFinder.items(for: profile, isRunning: true)

        #expect(items.allSatisfy { $0.protections == [.appRunning(name: "Vivaldi")] })
    }

    @Test("Firefox : l'historique passe par SQL, pour garder les favoris")
    func firefox() throws {
        let home = try BrowserHome()
        let base = "Library/Application Support/Firefox"
        try home.write("\(base)/profiles.ini", "[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abc.default-release\n")
        try home.write("\(base)/Profiles/abc.default-release/places.sqlite")
        try home.write("\(base)/Profiles/abc.default-release/cookies.sqlite")
        try home.write("Library/Caches/Firefox/Profiles/abc.default-release/cache2/x")

        let profile = try #require(BrowserFinder.profiles(of: .firefox, home: home.root).first)
        let items = BrowserFinder.items(for: profile, isRunning: false)
        let history = try #require(items.first { $0.ruleID == "browser.history" })

        #expect(profile.name == "default-release")
        guard case .firefoxHistory(let database) = history.method else { Issue.record("méthode"); return }
        #expect(database.hasSuffix("places.sqlite"))
        #expect(items.contains { $0.ruleID == "browser.cookies" })
        #expect(items.contains { $0.ruleID == "browser.cache" })
    }
}
