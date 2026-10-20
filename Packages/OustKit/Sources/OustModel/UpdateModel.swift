import AppKit
import Foundation
import Observation
import OustLocalization
import OustUpdates

@MainActor
@Observable
public final class UpdateModel {
    public private(set) var busy = false
    public private(set) var release: GitHubRelease?
    public private(set) var message: String?
    public private(set) var installer: URL?
    public var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }

    public init() {}

    public func check() async {
        guard !busy else { return }
        busy = true
        release = nil
        installer = nil
        message = nil
        defer { busy = false }
        do {
            let latest = try await GitHubUpdates.latest()
            guard let installed = ReleaseVersion(currentVersion), let remote = latest.version else { throw UpdateError.invalidRelease }
            if remote > installed {
                release = latest
                message = L10n.string("updates.available", latest.tag_name)
            } else { message = L10n.string("updates.current", currentVersion) }
        } catch { message = describe(error) }
    }

    public func download() async {
        guard !busy, let release else { return }
        busy = true
        message = L10n.string("updates.downloading")
        defer { busy = false }
        do {
            let url = try await GitHubUpdates.download(release)
            installer = url
            guard NSWorkspace.shared.open(url) else { throw UpdateError.invalidDownload }
            message = L10n.string("updates.install_instructions")
        } catch { message = describe(error) }
    }

    public func openInstaller() {
        if let installer { NSWorkspace.shared.open(installer) }
    }

    private func describe(_ error: any Error) -> String {
        L10n.string((error as? UpdateError)?.localizationKey ?? "updates.error.network")
    }
}
