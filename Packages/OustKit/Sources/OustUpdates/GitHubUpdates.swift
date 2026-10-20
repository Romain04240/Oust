import CryptoKit
import Foundation
import OustCore
import OustHelperContract

/// Versions stables uniquement ; un tag ne doit pas devenir une option ou un chemin.
public struct ReleaseVersion: Sendable, Comparable, Equatable {
    public let components: [Int]
    public init?(_ value: String) {
        let plain = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        components = parts.compactMap { Int($0) }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

public enum UpdateError: Error, Sendable, Equatable {
    case notPublished, rateLimited, invalidRelease, invalidDownload, invalidSignature, network
    public var localizationKey: String {
        switch self {
        case .notPublished: "updates.error.not_published"
        case .rateLimited: "updates.error.rate_limit"
        case .invalidRelease: "updates.error.release"
        case .invalidDownload: "updates.error.download"
        case .invalidSignature: "updates.error.signature"
        case .network: "updates.error.network"
        }
    }
}

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browser_download_url: URL
        public let size: Int64
        public let digest: String?
    }
    public let tag_name: String
    public let html_url: URL
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    public var version: ReleaseVersion? { ReleaseVersion(tag_name) }
    public var installer: Asset? {
        assets.first { asset in
            let plain = tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
            return asset.name == "Oust-\(plain).dmg" && asset.size > 0 && asset.size <= 1_000_000_000
                && Self.isTrusted(asset.browser_download_url, prefix: "/Romain04240/Oust/releases/download/\(tag_name)/")
                && asset.browser_download_url.lastPathComponent == asset.name
        }
    }
    public var isValid: Bool {
        !draft && !prerelease && version != nil && installer != nil
            && Self.isTrusted(html_url, prefix: "/Romain04240/Oust/releases/tag/")
    }
    static func isTrusted(_ url: URL, prefix: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.query == nil && url.fragment == nil && url.path.hasPrefix(prefix)
    }
}

public enum GitHubUpdates {
    public static let releasesURL = URL(string: "https://github.com/Romain04240/Oust/releases")!
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    /// Uniquement sur demande : pas de réseau au lancement ni pendant l'analyse.
    public static func latest() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Romain04240/Oust/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Oust-update-check", forHTTPHeaderField: "User-Agent")
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.network }
        return try decode(data, status: http.statusCode)
    }

    static func decode(_ data: Data, status: Int) throws -> GitHubRelease {
        switch status {
        case 404: throw UpdateError.notPublished
        case 403, 429: throw UpdateError.rateLimited
        case 200: break
        default: throw UpdateError.network
        }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data), release.isValid else {
            throw UpdateError.invalidRelease
        }
        return release
    }

    /// L'image est contrôlée avant d'être ouverte : taille, empreinte lorsqu'elle
    /// est publiée, puis signature Developer ID de la même équipe qu'Oust!.
    /// L'installation utilise ensuite le Finder, comme l'installation initiale.
    public static func download(_ release: GitHubRelease) async throws -> URL {
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fr.meaillais.oust/Updates", isDirectory: true)
        return try await download(release, into: cache, fetch: { try await session.download(from: $0) }, verify: verifyInstaller)
    }

    static func download(_ release: GitHubRelease, into cache: URL,
        fetch: @Sendable (URL) async throws -> (URL, URLResponse),
        verify: @Sendable (URL) async -> Bool
    ) async throws -> URL {
        guard release.isValid, let asset = release.installer else { throw UpdateError.invalidRelease }
        let (temporary, response) = try await fetch(asset.browser_download_url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == asset.size else { throw UpdateError.invalidDownload }
        if let digest = asset.digest {
            let actual = try await Task.detached(priority: .utility) { try sha256(temporary) }.value
            guard digest.lowercased() == "sha256:" + actual else { throw UpdateError.invalidDownload }
        }
        guard await verify(temporary) else { throw UpdateError.invalidSignature }
        let directory = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let installer = directory.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: temporary, to: installer)
        return installer
    }

    static func verifyInstaller(_ url: URL) async -> Bool {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(HelperContract.teamIdentifier)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        return await checkSignature(url, requirement: requirement)
    }

    static func checkSignature(_ url: URL, requirement: String) async -> Bool {
        await Command.run("/usr/bin/codesign", ["--verify", "--strict", "-R", "=" + requirement, url.path], timeout: 30).succeeded
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
