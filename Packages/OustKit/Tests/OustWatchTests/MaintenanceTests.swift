import Foundation
import Testing
import OustCore
import OustRules
import OustSafety
@testable import OustWatch

// MARK: - Planification

@Suite("Entretien : planification")
struct MaintenanceScheduleTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Désactivé par défaut, en pastille, sans notification")
    func defaults() {
        let settings = MaintenanceSettings()
        #expect(!settings.isEnabled)
        #expect(settings.frequency == .weekly)
        #expect(settings.showsCapsule)
        #expect(!settings.notifies)
        #expect(settings.nextRun(lastRun: nil) == nil)
        #expect(!settings.isDue(now: start.addingTimeInterval(365 * 86_400), lastRun: nil))
    }

    @Test("Coché, le premier entretien vient une période plus tard, pas à l'instant",
          arguments: [(RetentionFrequency.daily, 1), (.weekly, 7), (.monthly, 30)])
    func firstRun(frequency: RetentionFrequency, days: Int) {
        let settings = MaintenanceSettings(isEnabled: true, frequency: frequency, enabledSince: start)
        #expect(!settings.isDue(now: start, lastRun: nil))
        #expect(!settings.isDue(now: start.addingTimeInterval(Double(days) * 86_400 - 60), lastRun: nil))
        #expect(settings.isDue(now: start.addingTimeInterval(Double(days) * 86_400), lastRun: nil))
    }

    @Test("Après un entretien, le suivant vient une période plus tard")
    func afterRun() {
        let settings = MaintenanceSettings(isEnabled: true, frequency: .weekly, enabledSince: start)
        let last = start.addingTimeInterval(9 * 86_400)
        #expect(settings.nextRun(lastRun: last) == last.addingTimeInterval(7 * 86_400))
        #expect(!settings.isDue(now: last.addingTimeInterval(6 * 86_400), lastRun: last))
        #expect(settings.isDue(now: last.addingTimeInterval(7 * 86_400), lastRun: last))
    }

    @Test("Décoché, plus jamais dû, même très en retard")
    func disabled() {
        let settings = MaintenanceSettings(isEnabled: false, frequency: .daily, enabledSince: start)
        #expect(!settings.isDue(now: start.addingTimeInterval(400 * 86_400), lastRun: start))
    }

    @Test("Coché sans date connue : jamais d'entretien surprise")
    func noAnchor() {
        let settings = MaintenanceSettings(isEnabled: true, frequency: .daily)
        #expect(settings.nextRun(lastRun: nil) == nil)
    }

    @Test("Aller-retour, fichier abîmé, fichier d'une version plus ancienne")
    func persistence() throws {
        let settings = MaintenanceSettings(isEnabled: true, frequency: .monthly, showsCapsule: false, notifies: true,
                                           enabledSince: start)
        #expect(MaintenanceSettings.decode(settings.encoded()) == settings)
        #expect(MaintenanceSettings.decode(Data("pas du json".utf8)) == MaintenanceSettings())
        #expect(MaintenanceSettings.decode(nil) == MaintenanceSettings())
        let older = try MaintenanceSettings.decode(JSONSerialization.data(withJSONObject: ["isEnabled": true]))
        #expect(older.isEnabled && older.frequency == .weekly && older.showsCapsule && !older.notifies)

        let state = MaintenanceState(lastRun: start, lastTotal: 12_000_000_000, lastCount: 42)
        #expect(MaintenanceState.decode(state.encoded()) == state)
        #expect(MaintenanceState.decode(Data()) == MaintenanceState())
    }
}

// MARK: - Ce qui est annoncé

@Suite("Entretien : ce qui est annoncé")
struct MaintenanceSelectionTests {
    let now = Date()

    func item(_ name: String = "npm", rule: String = "cache.npm", category: ItemCategory = .packageCaches,
              safety: SafetyClass = .safe, method: CleanupMethod = .removeNow, bytes: Int64 = 2_000_000_000,
              ageDays: Double? = 60, notes: [ItemNote] = [], protections: [ProtectionReason] = []) -> CleanupItem {
        CleanupItem(id: "\(rule)|/tmp/\(name)", title: name, paths: [URL(fileURLWithPath: "/tmp/\(name)")],
                    category: category, owner: name, ruleID: rule, safety: safety, protections: protections,
                    notes: notes, method: method, sizes: Sizes(private: bytes),
                    lastActivity: ageDays.map { now.addingTimeInterval(-$0 * 86_400) }, rebuild: .automatic)
    }

    func announced(_ items: [CleanupItem], recency: Int = 7) -> [String] {
        MaintenanceSelection.announced(items, recencyDays: recency, now: now).map(\.title)
    }

    @Test("Le sûr : annoncé, même s'il a servi hier")
    func safe() {
        #expect(announced([item(ageDays: 1), item("brew", rule: "cache.homebrew", ageDays: nil)]) == ["npm", "brew"])
    }

    @Test("Ce qui se reconstruit : seulement au-delà de la garde de récence, comme la présélection")
    func rebuilds() {
        let young = item("DerivedData récent", rule: "xcode.derived_data", category: .xcode, safety: .rebuilds, ageDays: 3)
        let old = item("DerivedData ancien", rule: "xcode.derived_data", category: .xcode, safety: .rebuilds, ageDays: 30)
        let unknown = item("sans date", rule: "xcode.derived_data", category: .xcode, safety: .rebuilds, ageDays: nil)
        #expect(announced([young, old, unknown]) == ["DerivedData ancien"])
        #expect(announced([young, old], recency: 2) == ["DerivedData ancien", "DerivedData récent"]
            || announced([young, old], recency: 2) == ["DerivedData récent", "DerivedData ancien"])
    }

    @Test("Jamais l'« À examiner », jamais le protégé ni l'inaccessible")
    func classes() {
        let review = item("Téléchargement", rule: "downloads.large", category: .downloads, safety: .review, method: .trash)
        let model = item("Qwen", rule: "model.huggingface", category: .aiModels, safety: .review)
        let open = item("Spotify", rule: "cache.app", category: .appCaches, protections: [.appRunning(name: "Spotify")])
        let locked = item("Safari", rule: "browser.history", category: .browsers, safety: .inaccessible)
        #expect(announced([review, model, open, locked]).isEmpty)
    }

    @Test("Rendu tout de suite : rien qui attende la corbeille du Mac, ni Photos, ni un snapshot")
    func freesNow() {
        let trash = item("capture", rule: "screenshots.desktop", category: .screenshots, method: .trash)
        let snapshot = item("snapshot", rule: "snapshot.time_machine", category: .snapshots,
                            method: .localSnapshot(date: "2026-10-18-120000"))
        let photo = item("photo", rule: "photo.screenshot", category: .screenshots, method: .photoAsset(localIdentifier: "x"))
        let manual = item("Docker.raw", rule: "vm.docker", category: .virtualMachines, method: .manual)
        #expect(announced([trash, snapshot, photo, manual]).isEmpty)
    }

    @Test("Ni gain estimé, ni « géré à part », ni rien à rendre")
    func truthful() {
        let estimated = item("projet", rule: "compress.project", category: .compressibleProjects,
                             method: .compressInPlace, notes: [.estimated])
        let vm = item("VM", rule: "vm.image", category: .virtualMachines, notes: [.managedSeparately])
        let empty = item("vide", bytes: 0)
        #expect(announced([estimated, vm, empty]).isEmpty)
    }

    @Test("Un même élément compte une fois ; le plus gros d'abord")
    func uniqueSorted() {
        let small = item("pip", rule: "cache.pip", bytes: 1_000_000)
        let big = item("npm", bytes: 9_000_000_000)
        let found = MaintenanceSelection.announced([small, big, big], recencyDays: 7, now: now)
        #expect(found.map(\.title) == ["npm", "pip"])
        #expect(MaintenanceFinding(items: found).total == 9_001_000_000)
    }

    @Test("Au-dessous de 100 Mo, l'entretien se tait")
    func worthTelling() {
        #expect(!MaintenanceFinding(items: [item(bytes: 99_000_000)]).isWorthTelling)
        #expect(MaintenanceFinding(items: [item(bytes: 100_000_000)]).isWorthTelling)
        #expect(!MaintenanceFinding(items: []).isWorthTelling)
    }

    @Test("D'où vient le chiffre : les propriétaires les plus généreux, une fois chacun")
    func owners() {
        let finding = MaintenanceFinding(items: [item("Xcode", bytes: 9), item("Xcode", bytes: 8), item("npm", bytes: 7),
                                                 item("Safari", bytes: 6), item("pip", bytes: 5)])
        #expect(finding.leadingOwners() == ["Xcode", "npm", "Safari"])
    }
}

// MARK: - Le contour de la pastille

@Suite("Entretien : la jauge de la pastille")
struct MaintenanceGaugeTests {
    func finding(_ bytes: Int64, total: Int64 = 1_000_000_000_000, available: Int64 = 250_000_000_000) -> MaintenanceFinding {
        let item = CleanupItem(title: "npm", paths: [], category: .packageCaches, owner: "npm", ruleID: "cache.npm",
                               safety: .safe, method: .removeNow, sizes: Sizes(private: bytes), rebuild: .automatic)
        return MaintenanceFinding(items: [item], capacity: Capacity(total: total, available: available,
                                                                     availableForImportantUsage: available))
    }

    @Test("La part occupée, et au bout ce que l'entretien rendrait")
    func exact() {
        let gauge = finding(100_000_000_000).gauge
        #expect(abs(gauge.filled - 0.75) < 0.000_1)
        #expect(abs(gauge.giveBack - 0.1) < 0.000_1)
    }

    @Test("Trop peu pour se voir : un trait visible quand même")
    func visible() {
        #expect(finding(1_000_000_000).gauge.giveBack == MaintenanceFinding.minimumVisible)
    }

    @Test("Jamais plus que la part occupée ; rien sans disque connu")
    func bounded() {
        let gauge = finding(900_000_000_000).gauge
        #expect(gauge.giveBack == gauge.filled)
        let unknown = MaintenanceFinding(items: []).gauge
        #expect(unknown.filled == 0 && unknown.giveBack == 0)
        #expect(finding(0).gauge.giveBack == 0)
    }
}

// MARK: - De bout en bout, sans rien supprimer

/// L'analyse de l'entretien sur un faux dossier personnel, dans un dossier
/// temporaire à soi (RULES.md, règle 8) : elle trouve, elle compte, elle ne
/// touche à rien.
@Suite("Entretien : l'analyse ne supprime rien")
struct MaintenanceScanTests {
    final class Home {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("oust-entretien-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 300_000, ageDays: Double = 60) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: bytes).write(to: url)
            let date = Date().addingTimeInterval(-ageDays * 86_400)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }

        var context: RuleContext {
            RuleContext(home: root, projectRoots: [root.appendingPathComponent("Developpement")],
                        processes: ProcessSnapshot(processes: []),
                        applications: root.appendingPathComponent("_Applications"),
                        systemLibrary: root.appendingPathComponent("_Library"),
                        sharedFolder: root.appendingPathComponent("_Shared"),
                        temporaryDirectory: root.appendingPathComponent("_tmp"),
                        tools: .none, runningApps: [], applicationName: { _ in nil })
        }

        /// Tout ce qui existe sous le faux dossier personnel.
        var everything: Set<String> {
            let paths = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
            return Set(paths)
        }
    }

    @Test("Les caches sont comptés, le personnel ne l'est pas, et rien n'a bougé")
    func countsWithoutDeleting() async throws {
        let home = try Home()
        try home.file(".npm/_cacache/content-v2/a", bytes: 400_000)
        try home.file("Library/Caches/pip/http/b", bytes: 300_000, ageDays: 1)
        try home.file(".m2/repository/org/x.jar", bytes: 500_000)
        try home.file("Downloads/Installeur.dmg", bytes: 600_000, ageDays: 120)
        let before = home.everything

        let found = await RuleEngine.collect(home.context, finders: [.packageCaches, .userContent], measurer: .disk)
        let finding = MaintenanceFinding(items: MaintenanceSelection.announced(found, recencyDays: 7))

        // Les caches de paquets sûrs, même celui qui a servi hier ; pas Maven
        // (à examiner), pas l'installeur des Téléchargements (personnel).
        #expect(Set(finding.items.map(\.ruleID)) == ["cache.npm", "cache.pip"])
        #expect(finding.total > 0)
        #expect(finding.total == finding.items.reduce(0) { $0 + $1.sizes.freeable })
        #expect(found.contains { $0.ruleID == "cache.maven" })
        // Trouver, compter, montrer : aucun fichier n'a quitté le disque.
        #expect(home.everything == before)
    }
}
