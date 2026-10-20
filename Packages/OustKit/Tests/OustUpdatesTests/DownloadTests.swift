import CryptoKit
import Foundation
import Testing
import OustCore
@testable import OustUpdates

@Suite("L'installation est vérifiée avant ouverture")
struct DownloadTests {
    func release(size: Int, digest: String? = nil) throws -> GitHubRelease {
        var asset: [String: Any] = ["name": "Oust-0.2.0.dmg", "size": size,
            "browser_download_url": "https://github.com/Romain04240/Oust/releases/download/v0.2.0/Oust-0.2.0.dmg"]
        if let digest { asset["digest"] = digest }
        let object: [String: Any] = ["tag_name": "v0.2.0", "draft": false, "prerelease": false,
            "html_url": "https://github.com/Romain04240/Oust/releases/tag/v0.2.0", "assets": [asset]]
        return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("Le téléchargement vérifié est conservé dans le dossier injecté")
    func verifiedDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("installation de théâtre".utf8)
        let temporary = root.appendingPathComponent("download")
        try data.write(to: temporary)
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let cache = root.appendingPathComponent("cache")
        let downloaded = try await GitHubUpdates.download(release(size: data.count, digest: digest), into: cache,
            fetch: { url in (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) },
            verify: { url in url == temporary })
        #expect(downloaded.lastPathComponent == "Oust-0.2.0.dmg")
        #expect(downloaded.path.hasPrefix(cache.path + "/"))
        #expect(try Data(contentsOf: downloaded) == data)
    }

    @Test("Empreinte, taille, réponse HTTP et signature invalides empêchent l'installation",
          arguments: ["digest", "size", "http", "signature"])
    func refuses(_ failure: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("image factice".utf8)
        let temporary = root.appendingPathComponent("download")
        try data.write(to: temporary)
        let release = try release(size: data.count + (failure == "size" ? 1 : 0), digest: failure == "digest" ? "sha256:invalid" : nil)
        let cache = root.appendingPathComponent("cache")
        do {
            _ = try await GitHubUpdates.download(release, into: cache,
                fetch: { url in (temporary, HTTPURLResponse(url: url, statusCode: failure == "http" ? 500 : 200, httpVersion: nil, headerFields: nil)!) },
                verify: { _ in
                    if failure != "signature" { Issue.record("La vérification de signature ne doit pas précéder les contrôles de données") }
                    return false
                })
            Issue.record("L'installation aurait dû être refusée")
        } catch {
            #expect(error as? UpdateError == (failure == "signature" ? .invalidSignature : .invalidDownload))
        }
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("Une fausse image sans signature est refusée par le vrai vérificateur")
    func unsignedImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-signature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("unsigned.dmg")
        try Data("image non signée".utf8).write(to: file)
        #expect(await !GitHubUpdates.verifyInstaller(file))
    }

    @Test("Le vérificateur accepte une exigence inline satisfaite par un vrai binaire signé")
    func inlineRequirement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-inline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let signed = await Command.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "fr.meaillais.oust.fixture", executable.path])
        #expect(signed.succeeded)
        #expect(await GitHubUpdates.checkSignature(executable, requirement: "identifier \"fr.meaillais.oust.fixture\""))
        #expect(await !GitHubUpdates.checkSignature(executable, requirement: "identifier \"wrong.identifier\""))
    }

    @Test("L'absence de publication et la limite GitHub ont des messages distincts")
    func responseErrors() {
        #expect(throws: UpdateError.notPublished) { try GitHubUpdates.decode(Data(), status: 404) }
        #expect(throws: UpdateError.rateLimited) { try GitHubUpdates.decode(Data(), status: 403) }
        #expect(throws: UpdateError.network) { try GitHubUpdates.decode(Data(), status: 500) }
        #expect(throws: UpdateError.invalidRelease) { try GitHubUpdates.decode(Data("{}".utf8), status: 200) }
    }
}
