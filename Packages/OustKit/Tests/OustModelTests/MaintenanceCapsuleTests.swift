import Darwin
import Foundation
import OustCore
@testable import OustModel
import OustScan
import Testing

struct MaintenanceCapsuleTests {
    @Test("Une pastille différée oublie les fichiers disparus ou remplacés")
    func deferredFinding() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("oust-maintenance-capsule-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let kept = root.appendingPathComponent("kept")
        let removed = root.appendingPathComponent("removed")
        let replaced = root.appendingPathComponent("replaced")
        let companion = root.appendingPathComponent("companion")
        for path in [kept, removed, replaced, companion] { try Data(repeating: 1, count: 65_536).write(to: path) }
        var original = stat()
        #expect(lstat(replaced.path, &original) == 0)

        func item(_ id: String, _ paths: [URL], bytes: Int64, inode: UInt64? = nil) -> CleanupItem {
            CleanupItem(id: id, title: id, paths: paths, category: .appCaches, owner: "Fixture",
                        ruleID: "test", safety: .safe, method: .trash,
                        sizes: Sizes(private: bytes), rebuild: .automatic,
                        fingerprint: inode.map { Fingerprint(modificationDate: nil, fileID: $0) })
        }
        let surviving = item("kept", [kept], bytes: 20_000)
        let absent = item("removed", [removed], bytes: 200_000)
        let changed = item("replaced", [replaced], bytes: 300_000, inode: UInt64(original.st_ino))
        let incomplete = item("incomplete", [kept, companion], bytes: 400_000)

        try manager.removeItem(at: removed)
        try manager.removeItem(at: companion)
        try manager.moveItem(at: replaced, to: root.appendingPathComponent("original"))
        try Data([2]).write(to: replaced)

        let current = try #require(await MaintenanceModel.capsuleFinding(
            .init(items: [surviving, absent, changed, incomplete]), home: root
        ))
        #expect(current.items.map(\.id) == [surviving.id])
        #expect(current.total >= 65_536)
        #expect(current.total < absent.sizes.freeable)
        #expect(!current.measurementIsComplete)
    }

    @Test("Un cache sans empreinte recréé vide ne garde aucun gain")
    func emptyCacheAtSamePath() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("oust-maintenance-cache-\(UUID())")
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try Data(repeating: 51, count: 1_048_576).write(to: cache.appendingPathComponent("blob"))

        let item = CleanupItem(title: "Cache", paths: [cache], category: .browsers, owner: "Fixture",
                               ruleID: "browser.cache", safety: .safe, method: .trash,
                               sizes: Sizes(private: 1_048_576), rebuild: .automatic)
        let finding = try #require(await MaintenanceModel.capsuleFinding(.init(items: [item]), home: root))
        #expect(finding.total > 0)
        #expect(finding.items.first?.fingerprint == nil)

        try manager.moveItem(at: cache, to: root.appendingPathComponent("OldCache"))
        try manager.createDirectory(at: cache, withIntermediateDirectories: false)
        let current = try #require(await MaintenanceModel.capsuleFinding(finding, home: root))
        #expect(current.total == 0)
        #expect(current.items.isEmpty)
        #expect(current.measurementIsComplete)
        #expect(manager.fileExists(atPath: cache.path))
    }

    @Test("Un cache illisible n'est pas présenté comme un cache vide")
    func unreadableCache() async throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("oust-unreadable-cache-\(UUID())")
        let cache = home.appendingPathComponent("Cache", isDirectory: true)
        let payload = cache.appendingPathComponent("payload")
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.path)
            try? manager.removeItem(at: home)
        }
        try Data(repeating: 51, count: 65_536).write(to: payload)
        let item = cacheItem(at: cache)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: cache.path)

        let current = try #require(await MaintenanceModel.capsuleFinding(.init(items: [item]), home: home))
        #expect(!current.measurementIsComplete)
        #expect(current.items.isEmpty)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.path)
        #expect(try Data(contentsOf: payload).count == 65_536)
    }

    @Test("Le gain du dossier mesuré est écarté si le lien revient à sa cible d'origine")
    func aliasRetargetedDuringScan() async throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("oust-cache-identity-\(UUID())")
        let first = home.appendingPathComponent("First", isDirectory: true)
        let second = home.appendingPathComponent("Second", isDirectory: true)
        let alias = home.appendingPathComponent("Alias")
        defer { try? manager.removeItem(at: home) }
        for parent in [first, second] {
            try manager.createDirectory(at: parent.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        }
        let payload = second.appendingPathComponent("Cache/payload")
        try Data(repeating: 17, count: 1_048_576).write(to: payload)
        try manager.createSymbolicLink(at: alias, withDestinationURL: first)
        let item = cacheItem(at: alias.appendingPathComponent("Cache"))
        let resolved = try #require(realpath(first.appendingPathComponent("Cache").path, nil))
        let expectedPath = String(cString: resolved)
        free(resolved)
        let measured = await MaintenanceModel.capsuleFinding(.init(items: [item]), home: home) {
            paths, options, progress in
            let manager = FileManager()
            #expect(paths.map(\.path) == [expectedPath])
            try! manager.removeItem(at: alias)
            try! manager.createSymbolicLink(at: alias, withDestinationURL: second)
            let result = await Scanner.scan(paths, options: options, progress: progress)
            #expect(result.roots.first?.total.freeable == 0)
            try! manager.removeItem(at: alias)
            try! manager.createSymbolicLink(at: alias, withDestinationURL: first)
            return result
        }
        let current = try #require(measured)
        #expect(current.measurementIsComplete)
        #expect(current.items.isEmpty)
        #expect(manager.fileExists(atPath: payload.path))
    }

    @Test("Le scanner refuse un lien apparu dans le chemin physique autorisé")
    func replacementOfResolvedParent() async throws {
        let manager = FileManager()
        let home = manager.temporaryDirectory.appendingPathComponent("oust-capsule-physical-\(UUID())")
        let allowed = home.appendingPathComponent("Allowed")
        let logs = home.appendingPathComponent("Library/Logs")
        let parked = home.appendingPathComponent("Parked")
        let cache = allowed.appendingPathComponent("Cache")
        let alias = home.appendingPathComponent("Alias")
        defer { try? manager.removeItem(at: home) }
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: alias, withDestinationURL: allowed)
        try Data(repeating: 44, count: 65_536).write(to: cache.appendingPathComponent("payload"))
        let item = cacheItem(at: alias.appendingPathComponent("Cache"))
        let initial = try #require(await MaintenanceModel.capsuleFinding(.init(items: [item]), home: home))
        #expect(initial.total > 0)

        let current = try #require(await MaintenanceModel.capsuleFinding(initial, home: home) { paths, options, progress in
            let manager = FileManager()
            try! manager.moveItem(at: allowed, to: parked)
            try! manager.moveItem(at: parked.appendingPathComponent("Cache"), to: logs.appendingPathComponent("Cache"))
            try! manager.createSymbolicLink(at: allowed, withDestinationURL: logs)
            defer {
                try! manager.removeItem(at: allowed)
                try! manager.moveItem(at: logs.appendingPathComponent("Cache"), to: parked.appendingPathComponent("Cache"))
                try! manager.moveItem(at: parked, to: allowed)
            }
            let result = await Scanner.scan(paths, options: options, progress: progress)
            #expect(result.root?.status != .ok)
            return result
        })
        #expect(!current.measurementIsComplete)
        #expect(current.items.isEmpty)
        #expect(manager.fileExists(atPath: cache.appendingPathComponent("payload").path))
    }

    @Test("Une racine de protection invérifiable pendant la mesure invalide le gain")
    func invalidatedProtectionRoots() async throws {
        let manager = FileManager()
        let home = manager.temporaryDirectory.appendingPathComponent("oust-capsule-protection-\(UUID())")
        let backups = DeviceBackupPath.root(in: home)
        let cache = home.appendingPathComponent("Cache")
        defer { try? manager.removeItem(at: home) }
        for directory in [backups, cache] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let payload = cache.appendingPathComponent("payload")
        try Data(repeating: 32, count: 65_536).write(to: payload)
        let initial = try #require(await MaintenanceModel.capsuleFinding(.init(items: [cacheItem(at: cache)]), home: home))
        #expect(initial.total > 0)

        let current = try #require(await MaintenanceModel.capsuleFinding(initial, home: home) { paths, options, progress in
            let manager = FileManager()
            let loop = backups.appendingPathComponent("Loop")
            try! manager.createSymbolicLink(atPath: loop.path, withDestinationPath: "Loop")
            defer { try! manager.removeItem(at: loop) }
            let result = await Scanner.scan(paths, options: options, progress: progress)
            #expect(result.root?.status == .ok)
            #expect(result.root?.total.freeable == 0)
            #expect(!result.freeableEstimatesAreValid)
            return result
        })
        #expect(!current.measurementIsComplete)
        #expect(current.items.isEmpty)
        #expect(try Data(contentsOf: payload).count == 65_536)
    }

    @Test("Un cache groupé incomplet est écarté, un cache entièrement disparu vaut zéro")
    func groupedCache() async throws {
        let manager = FileManager()
        let home = manager.temporaryDirectory.appendingPathComponent("oust-capsule-group-\(UUID())")
        let first = home.appendingPathComponent("Cache")
        let second = home.appendingPathComponent("Code Cache")
        defer { try? manager.removeItem(at: home) }
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        for path in [first, second] { try Data(repeating: 48, count: 65_536).write(to: path) }
        var group = cacheItem(at: first)
        group.paths = [first, second]
        let initial = try #require(await MaintenanceModel.capsuleFinding(.init(items: [group]), home: home))
        #expect(initial.total >= 131_072)
        #expect(initial.items.first?.paths == [first, second])

        try manager.removeItem(at: first)
        let partial = try #require(await MaintenanceModel.capsuleFinding(initial, home: home))
        #expect(!partial.measurementIsComplete)
        #expect(partial.items.isEmpty)
        #expect(try Data(contentsOf: second).count == 65_536)

        try manager.removeItem(at: second)
        let absent = try #require(await MaintenanceModel.capsuleFinding(initial, home: home))
        #expect(absent.measurementIsComplete)
        #expect(absent.total == 0)
    }

    private func cacheItem(at path: URL) -> CleanupItem {
        CleanupItem(title: "Cache", paths: [path], category: .browsers, owner: "Fixture",
                    ruleID: "browser.cache", safety: .safe, method: .trash,
                    sizes: Sizes(private: 1_048_576), rebuild: .automatic)
    }
}
