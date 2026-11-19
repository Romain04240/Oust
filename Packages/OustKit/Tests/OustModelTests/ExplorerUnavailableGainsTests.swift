import Foundation
import OustCore
import OustScan
import Testing
@testable import OustModel

@Suite("L'Explorateur n'exporte pas de gain indisponible") @MainActor
struct ExplorerUnavailableGainsTests {
    @Test("Un fichier ordinaire garde ses octets occupés dans le CSV, sans promettre sa suppression",
          arguments: [false, true])
    func exportOrdinaryFileWithoutAvailableCleanup(replacingExisting: Bool) async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-explorer-unavailable-\(UUID())")
            .resolvingSymlinksInPath()
        let folder = home.appendingPathComponent("Ordinaire")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let source = folder.appendingPathComponent("ordinary.bin")
        let contents = Data(repeating: 87, count: 131_072)
        try contents.write(to: source)
        let index = await ScanIndex.refresh(nil, root: folder, options: ScanOptions(leafThreshold: 1)).index
        let leaf = try #require(index.root.files.first { $0.name == source.lastPathComponent })
        #expect(!index.hasDeviceBackupProtection && !index.hasWithheldGains)
        #expect(leaf.sizes.allocated > 0 && leaf.sizes.freeable > 0 && index.root.total.freeable > 0)

        let analytics = TreeAnalytics.compute(index.root)
        let baseline = try fileRow(in: analytics.csv(for: index.root, includeGains: true))
        let baselineAllocated = try #require(Int64(baseline[2]))
        let baselineGain = try #require(Int64(baseline[3]))
        #expect(baselineAllocated > 0 && baselineGain > 0)

        let app = AppModel(home: home, defaults: UnavailableGainsDefaults(),
            disk: DiskIndexModel(store: TreeStore(directory: home.appendingPathComponent("Index"))))
        let volume = VolumeDescriptor(name: "Fictif", mountURL: folder, scanRoot: folder, isBoot: false,
            isInternal: true, isRemovable: false,
            capacity: Capacity(total: 1_000_000, available: 500_000, availableForImportantUsage: 500_000))
        app.showExplorerIndex(index, volume: volume)
        let kept = CleanupItem(title: "Choix conservé", paths: [home.appendingPathComponent("keep")],
            category: .toolVersions, owner: "Fixture", ruleID: "tool.brew_cleanup", safety: .safe,
            method: .brewCleanup(executable: home.appendingPathComponent("bin/brew").path),
            sizes: .zero, rebuild: .nothing)
        app.items[kept.id] = kept
        app.toggle(kept)
        let cart = app.cart
        #expect(cart == [kept.id] && !app.canMoveFiles)
        let item = app.item(for: leaf, in: index.root)
        #expect(item.method == .trash && !app.canSelectForCleanup(item))
        app.toggle(item)
        #expect(app.cart == cart)

        let destination = home.appendingPathComponent("Fictif.csv")
        if replacingExisting {
            try "ancienne version".write(to: destination, atomically: false, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        let exported = try await app.exportExplorerCSV(to: destination, for: index.root, render: { includeGains in
            analytics.csv(for: index.root, includeGains: includeGains)
        })
        #expect(exported)
        let published = try fileRow(in: String(contentsOf: destination, encoding: .utf8))
        let occupied = try #require(Int64(published[2]))
        let gain = try #require(Int64(published[3]))
        #expect(occupied == baselineAllocated && occupied > 0 && gain == 0)
        #expect(published[0] == baseline[0] && published[1] == "fichier")
        if replacingExisting {
            let mode = try fm.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
        #expect(app.tree === index.root && index.root.total.freeable > 0)
        #expect(index.root.files.first?.sizes.freeable == baselineGain)
        #expect(app.cart == cart && app.cartItems.map(\.id) == [kept.id] && app.cleaning == .idle)
        #expect(app.items[item.id] == nil && !app.canSelectForCleanup(item))
        #expect(try Data(contentsOf: source) == contents)
    }

    private func fileRow(in csv: String) throws -> [String] {
        let lines = csv.split(separator: "\n")
        try #require(lines.count == 2)
        let header = lines[0].split(separator: ";", omittingEmptySubsequences: false)
        let fields = lines[1].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        try #require(header.count == 8 && fields.count == 8)
        #expect(header[2] == "Octets alloués" && header[3] == "Octets libérables")
        #expect(fields[0].contains("/ordinary.bin\"") && fields[1] == "fichier")
        return fields
    }
}

private final class UnavailableGainsDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey key: String) -> Any? { nil }
    override func data(forKey key: String) -> Data? { nil }
    override func stringArray(forKey key: String) -> [String]? { nil }
    override func bool(forKey key: String) -> Bool { false }
    override func set(_ value: Any?, forKey key: String) {}
}
