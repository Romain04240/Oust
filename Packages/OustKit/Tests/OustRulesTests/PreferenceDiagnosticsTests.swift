import Foundation
import Testing
import OustClean
import OustCore
import OustSafety
import OustScan
@testable import OustRules

@Suite("Le diagnostic des préférences est en lecture seule")
struct PreferenceDiagnosticsTests {
    private static let broken = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>value</key>"
    private static let badID = "org.fixture.invalide"

    private func application(_ home: FakeHome, _ identifier: String, folder: String? = nil) throws -> URL {
        let relative = folder ?? "_Applications/\(identifier).app"
        try home.text(relative + "/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(identifier)</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleName</key><string>App fictive</string>
        </dict></plist>
        """)
        return home.root.appendingPathComponent(relative, isDirectory: true)
    }

    @Test("Seul le plist invalidé d'une application tierce identifiée et fermée est signalé")
    func formatsAndOwnership() async throws {
        let home = try FakeHome()
        let root = home.root.appendingPathComponent("Library/Preferences", isDirectory: true)
        var locations: [String: URL] = [:]
        for identifier in [Self.badID, "org.fixture.xml", "org.fixture.binary", "org.fixture.link", "org.fixture.hardlink",
                           "org.fixture.running", "org.fixture.gros", "com.apple.fixture", "org.bitwarden.fixture"] {
            locations[identifier] = try application(home, identifier)
        }
        locations["org.fixture.mismatch"] = locations[Self.badID]
        locations["org.fixture.deleted"] = try application(home, "org.fixture.deleted", folder: ".Trash/Removed.app")
        for id in [Self.badID, "org.fixture.running", "com.apple.fixture", "org.bitwarden.fixture",
                   "org.fixture.uninstalled", "org.fixture.mismatch", "org.fixture.deleted"] {
            try home.text("Library/Preferences/\(id).plist", Self.broken)
        }
        let valid: [String: Any] = ["flag": true]
        try PropertyListSerialization.data(fromPropertyList: valid, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("org.fixture.xml.plist"))
        try PropertyListSerialization.data(fromPropertyList: valid, format: .binary, options: 0)
            .write(to: root.appendingPathComponent("org.fixture.binary.plist"))
        try home.file("Library/Preferences/org.fixture.gros.plist", bytes: 1_048_577)
        try home.text("Other/External.plist", Self.broken)
        let outside = home.root.appendingPathComponent("Other/External.plist")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: root.appendingPathComponent("org.fixture.link.plist"), withDestinationURL: outside)
        try fm.linkItem(at: outside, to: root.appendingPathComponent("org.fixture.hardlink.plist"))
        var context = home.context(runningApps: ["org.fixture.running"])
        let applications = locations
        context.applicationURL = { applications[$0] }

        let items = await RuleEngine.collect(context, finders: [.preferenceDiagnostics])
        #expect(items.map(\.detail) == [Self.badID + ".plist"])
        let item = try #require(items.first)
        #expect(item.category == .preferenceDiagnostics && item.category.section == .system)
        #expect(item.ruleID == CleanupItem.invalidPreferenceRuleID && item.safety == .protected && item.method == .manual)
        #expect(item.sizes == .zero && !item.isSelectable && !PreselectionPolicy().preselects(item))
        #expect(try String(contentsOf: root.appendingPathComponent(Self.badID + ".plist"), encoding: .utf8) == Self.broken)
    }

    @Test("Le diagnostic ignore une bibliothèque ou un dossier Preferences redirigé", arguments: ["Library", "Library/Preferences"])
    func refusesRedirectedDirectory(relative: String) async throws {
        let home = try FakeHome()
        let app = try application(home, Self.badID)
        let target = try makeRedirectTarget(home, relative: relative)
        let link = home.root.appendingPathComponent(relative)
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        var context = home.context()
        context.applicationURL = { _ in app }
        let items = await RuleEngine.collect(context, finders: [.preferenceDiagnostics])
        #expect(items.isEmpty)
    }

    private func makeRedirectTarget(_ home: FakeHome, relative: String) throws -> URL {
        let target = home.root.appendingPathComponent("Other", isDirectory: true)
        let preferences = relative == "Library" ? "Other/Preferences" : "Other"
        try home.text(preferences + "/\(Self.badID).plist", Self.broken)
        return target
    }

    @Test("Le diagnostic refuse la Corbeille même si la méthode ou la catégorie est modifiée")
    func refusesTrash() async throws {
        let home = try FakeHome()
        let app = try application(home, Self.badID)
        let relative = "Library/Preferences/\(Self.badID).plist"
        try home.text(relative, Self.broken)
        var context = home.context()
        context.applicationURL = { _ in app }
        let detected = try #require(await RuleEngine.collect(context, finders: [.preferenceDiagnostics]).first)
        var altered = detected
        altered.method = .trash
        altered.safety = .review
        var generic = altered
        generic.category = .explorer
        var renamed = altered
        renamed.ruleID = "explorer.item"
        let trash = home.root.appendingPathComponent("CorbeilleFictive")
        let engine = CleanupEngine(trasher: FolderTrasher(folder: trash), history: nil, pathGuard: PathGuard(home: home.root),
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil })
        #expect(engine.supports(.trash))
        #expect(!FinderTrasher().isAvailable && !FileManagerTrasher().isAvailable)
        var report: CleanupReport?
        for await event in engine.run([detected, generic, renamed]) {
            if case .finished(let result) = event { report = result }
        }
        let result = try #require(report)
        #expect(result.outcomes.isEmpty && result.expectedNow == 0 && result.pendingInTrash == 0)
        #expect(!FileManager.default.fileExists(atPath: trash.path))
        #expect(try String(contentsOf: home.root.appendingPathComponent(relative), encoding: .utf8) == Self.broken)
    }

    @Test("Un diagnostic remplacé par un plist valide est écarté après la mesure")
    func skipsReplacedPreference() async throws {
        let home = try FakeHome()
        let app = try application(home, Self.badID)
        let relative = "Library/Preferences/\(Self.badID).plist"
        try home.text(relative, Self.broken)
        try home.file("Downloads/Temoin.bin")
        let file = home.root.appendingPathComponent(relative)
        let control = home.root.appendingPathComponent("Downloads/Temoin.bin")
        let guardPaths = PathGuard(home: home.root)
        var context = home.context()
        context.applicationURL = { _ in app }
        let found = PreferenceDiagnosticsFinder(context: context).find()
        #expect(found.count == 1)
        let withoutMeasurement = await RuleEngine.measure(found, using: Measurer { _ in
            Issue.record("Un diagnostic sans mesure n’a pas à attendre l’arbre")
            return [:]
        }, pathGuard: guardPaths)
        #expect(withoutMeasurement.count == 1)
        let measured = Candidate(item: CleanupItem(title: "Témoin", paths: [control], category: .downloads,
                                                   owner: "", ruleID: "downloads.large", safety: .review,
                                                   method: .trash, rebuild: .irreversible))
        let valid = try PropertyListSerialization.data(fromPropertyList: ["flag": true], format: .xml, options: 0)
        let items = await RuleEngine.measure(found + [measured], using: Measurer { urls in
            #expect(urls == [control])
            do { try valid.write(to: file, options: .atomic) }
            catch { Issue.record("Remplacement du plist fictif impossible : \(error)") }
            return await Scanner.measure(urls)
        }, pathGuard: guardPaths)
        #expect(items.map(\.title) == ["Témoin"])
        #expect(try Data(contentsOf: file) == valid)
    }
}
