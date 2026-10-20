import Foundation
import Testing
@testable import OustUpdates

@Suite("Publications GitHub et installations")
struct UpdateTests {
    func release(version: String = "v0.2.0", url: String = "https://github.com/Romain04240/Oust/releases/download/v0.2.0/Oust-0.2.0.dmg",
                 name: String = "Oust-0.2.0.dmg", draft: Bool = false, prerelease: Bool = false) throws -> GitHubRelease {
        let object: [String: Any] = ["tag_name": version, "draft": draft, "prerelease": prerelease,
            "html_url": "https://github.com/Romain04240/Oust/releases/tag/\(version)",
            "assets": [["name": name, "browser_download_url": url, "size": 100]]]
        return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("Comparaison numérique, avec ou sans préfixe v")
    func versions() throws {
        #expect(try #require(ReleaseVersion("v0.10.0")) > #require(ReleaseVersion("0.9.9")))
        #expect(ReleaseVersion("v1.2.3") == ReleaseVersion("1.2.3"))
        for invalid in ["", "1.0", "1.2.3-beta", "1.2.3/evil", "1.2.３", "999999999999.1.0"] {
            #expect(ReleaseVersion(invalid) == nil)
        }
    }

    @Test("Seule une publication stable avec le DMG du dépôt est recevable")
    func supported() throws {
        #expect(try release().isValid)
        #expect(try !release(draft: true).isValid)
        #expect(try !release(prerelease: true).isValid)
        #expect(try !release(name: "Source.zip").isValid)
    }

    @Test("Les liens trompeurs ou vers un autre dépôt sont refusés", arguments: [
        "http://github.com/Romain04240/Oust/releases/download/v0.2.0/Oust-0.2.0.dmg",
        "https://github.com.evil.test/Romain04240/Oust/releases/download/v0.2.0/Oust-0.2.0.dmg",
        "https://github.com/other/Oust/releases/download/v0.2.0/Oust-0.2.0.dmg",
        "https://attacker@github.com/Romain04240/Oust/releases/download/v0.2.0/Oust-0.2.0.dmg",
        "https://github.com/Romain04240/Oust/releases/download/v0.2.0/Oust-0.2.0.dmg?redirect=evil"
    ])
    func untrusted(_ url: String) throws { #expect(try !release(url: url).isValid) }
}
