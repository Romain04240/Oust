import Foundation
import Observation
import OustCore
import OustRules
import Testing
@testable import OustModel

@MainActor
struct PreferenceInvalidationTests {
    enum Replacement: CaseIterable {
        case atomic
        case inPlace
        case directory
    }

    @Test("Une fiche affichée disparaît quand son plist change", arguments: Replacement.allCases)
    func externalReplacement(_ replacement: Replacement) async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("oust-pref-observation-\(UUID())")
        let preferences = PreferenceDirectory.url(in: home)
        try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let identifier = "org.fixture.observation"
        let bundle = home.appendingPathComponent("_Applications/\(identifier).app", isDirectory: true)
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        try fm.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metadata = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "CFBundleName": "Fictif"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: info)
        var context = RuleContext(home: home, runningApps: [])
        context.applicationURL = { _ in bundle }

        let app = AppModel(home: home, defaults: MemoryDefaults())
        let file = preferences.appendingPathComponent("\(identifier).plist")
        let invalid = Data(#"<?xml version="1.0"?><plist version="1.0"><dict><key>value</key>"#.utf8)
        let valid = try PropertyListSerialization.data(fromPropertyList: ["flag": true], format: .xml, options: 0)
        // La deuxième analyse vérifie que le suivi redémarre après disparition
        // de la dernière fiche, sans provoquer de rafraîchissement de la vue.
        for attempt in 0..<2 {
            try invalid.write(to: file, options: .atomic)
            var iterator = RuleEngine.run(context, finders: [.preferenceDiagnostics]).makeAsyncIterator()
            let batch = try #require(await iterator.next())
            let diagnostic = try #require(batch.items.first)
            app.recordAnalyzedBatch(batch, preselect: false, policy: PreselectionPolicy())

            try await confirmation("La vue reçoit le retrait de la fiche") { changed in
                let visible = withObservationTracking {
                    app.visibleItems(in: [.preferenceDiagnostics], section: .system)
                } onChange: { changed() }
                #expect(visible.map(\.id) == [diagnostic.id])
                switch replacement {
                case .atomic:
                    try valid.write(to: file, options: .atomic)
                case .inPlace:
                    try valid.write(to: file)
                case .directory:
                    try fm.moveItem(at: preferences, to: home.appendingPathComponent("AnciennesPréférences-\(attempt)"))
                    try fm.createDirectory(at: preferences, withIntermediateDirectories: false)
                    try valid.write(to: file)
                }
                for _ in 0..<40 {
                    // Ce dictionnaire ne revalide pas le disque à la lecture.
                    if app.items[diagnostic.id] == nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(app.items[diagnostic.id] == nil)
            }
        }
    }
}
