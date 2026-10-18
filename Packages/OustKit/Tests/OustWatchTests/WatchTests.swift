import Darwin
import Foundation
import Testing
import OustClean
import OustCore
import OustRules
import OustSafety
@testable import OustWatch

// MARK: - Seuils

@Suite("Seuil d'alerte")
struct ThresholdTests {
    let terabyte: Int64 = 1_000_000_000_000

    @Test("Un pourcentage se lit sur la taille du disque")
    func percent() {
        #expect(LowDiskThreshold.percent(10).bytes(total: terabyte) == 100_000_000_000)
        #expect(LowDiskThreshold.percent(10).bytes(total: 256_000_000_000) == 25_600_000_000)
        // Pas de dépassement sur un très grand volume.
        #expect(LowDiskThreshold.percent(50).bytes(total: .max) > 0)
    }

    @Test("Des gigaoctets en base 1000, comme le Finder")
    func gigabytes() {
        #expect(LowDiskThreshold.gigabytes(20).bytes(total: terabyte) == 20_000_000_000)
        #expect(LowDiskThreshold.gigabytes(20).bytes(total: 0) == 20_000_000_000)
    }

    @Test("Par défaut : 10 %, et 20 Go quand on passe aux gigaoctets")
    func defaults() {
        #expect(LowDiskThreshold.standard == .percent(10))
        #expect(LowDiskThreshold.defaultGigabytes == 20)
        #expect(WatchSettings().threshold == .percent(10))
    }

    @Test("Les valeurs hors bornes sont ramenées dans l'intervalle")
    func clamped() {
        #expect(LowDiskThreshold.percent(150).bytes(total: terabyte) == terabyte)
        #expect(LowDiskThreshold.percent(-5).bytes(total: terabyte) == 0)
        #expect(LowDiskThreshold.gigabytes(-1).bytes(total: terabyte) == 0)
    }

    @Test("Sous le seuil, au-dessus, et un volume sans taille")
    func isLow() {
        let threshold = LowDiskThreshold.gigabytes(20)
        #expect(LowDiskAlarm.isLow(available: 19_999_999_999, total: terabyte, threshold: threshold))
        #expect(!LowDiskAlarm.isLow(available: 20_000_000_000, total: terabyte, threshold: threshold))
        #expect(!LowDiskAlarm.isLow(available: 0, total: 0, threshold: threshold))
    }
}

// MARK: - Une fois par franchissement

@Suite("Alerte disque bas : une fois par passage sous le seuil")
struct AlarmTests {
    let total: Int64 = 1_000_000_000_000
    let threshold = LowDiskThreshold.gigabytes(20)
    let gigabyte: Int64 = 1_000_000_000

    @Test("Prévient en passant sous le seuil, puis se tait tant qu'on y reste")
    func once() {
        var alarm = LowDiskAlarm()
        #expect(alarm.observe(available: 50 * gigabyte, total: total, threshold: threshold) == .quiet)
        #expect(alarm.observe(available: 19 * gigabyte, total: total, threshold: threshold) == .alert)
        #expect(alarm.hasFired)
        for free in [18, 12, 5, 19] {
            #expect(alarm.observe(available: Int64(free) * gigabyte, total: total, threshold: threshold) == .quiet)
        }
    }

    @Test("Déjà sous le seuil au premier regard : une alerte, une seule")
    func alreadyLow() {
        var alarm = LowDiskAlarm()
        #expect(alarm.observe(available: 3 * gigabyte, total: total, threshold: threshold) == .alert)
        #expect(alarm.observe(available: 3 * gigabyte, total: total, threshold: threshold) == .quiet)
    }

    @Test("Osciller autour du seuil ne réarme pas l'alerte")
    func hysteresis() {
        var alarm = LowDiskAlarm()
        _ = alarm.observe(available: 19 * gigabyte, total: total, threshold: threshold)
        // 20,5 Go : au-dessus du seuil, mais sous la marge de 1 Go.
        #expect(alarm.observe(available: 20 * gigabyte + gigabyte / 2, total: total, threshold: threshold) == .quiet)
        #expect(alarm.hasFired)
        #expect(alarm.observe(available: 19 * gigabyte, total: total, threshold: threshold) == .quiet)
    }

    @Test("Remonter au-dessus du seuil et de sa marge réarme, et le passage suivant prévient")
    func rearm() {
        var alarm = LowDiskAlarm()
        _ = alarm.observe(available: 19 * gigabyte, total: total, threshold: threshold)
        #expect(alarm.observe(available: 21 * gigabyte, total: total, threshold: threshold) == .quiet)
        #expect(!alarm.hasFired)
        #expect(alarm.observe(available: 15 * gigabyte, total: total, threshold: threshold) == .alert)
    }

    @Test("La marge : 5 % du seuil, au moins 1 Go ou 1 % du disque")
    func margin() {
        #expect(LowDiskAlarm.rearmMargin(threshold: 20 * gigabyte, total: total) == gigabyte)
        #expect(LowDiskAlarm.rearmMargin(threshold: 100 * gigabyte, total: total) == 5 * gigabyte)
        // Une clé de 200 Mo : 2 Mo, pas 1 Go.
        #expect(LowDiskAlarm.rearmMargin(threshold: 20_000_000, total: 200_000_000) == 2_000_000)
    }

    @Test("Un petit disque se réarme aussi")
    func smallDiskRearms() {
        let small: Int64 = 200_000_000
        let tenPercent = LowDiskThreshold.percent(10)
        var alarm = LowDiskAlarm()
        #expect(alarm.observe(available: 5_000_000, total: small, threshold: tenPercent) == .alert)
        #expect(alarm.observe(available: 150_000_000, total: small, threshold: tenPercent) == .quiet)
        #expect(!alarm.hasFired)
        #expect(alarm.observe(available: 5_000_000, total: small, threshold: tenPercent) == .alert)
    }

    @Test("Un volume qui ne dit pas sa taille ne déclenche rien")
    func unknownTotal() {
        var alarm = LowDiskAlarm()
        #expect(alarm.observe(available: 0, total: 0, threshold: threshold) == .quiet)
        #expect(!alarm.hasFired)
    }

    @Test("L'état survit à un relancement : pas de seconde alerte au lancement suivant")
    func persisted() throws {
        var alarm = LowDiskAlarm()
        _ = alarm.observe(available: 10 * gigabyte, total: total, threshold: threshold)
        let state = WatchState(alarms: ["disque": alarm])
        var reloaded = try #require(WatchState.decode(state.encoded()).alarms["disque"])
        #expect(reloaded.observe(available: 10 * gigabyte, total: total, threshold: threshold) == .quiet)
    }
}

// MARK: - Échéances

@Suite("Règles planifiées : quand elles passent")
struct ScheduleTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    @Test("Désactivées par défaut, et jamais dues tant qu'elles le sont")
    func offByDefault() {
        let settings = WatchSettings()
        #expect(settings.policies.count == RetentionFamily.allCases.count)
        for policy in settings.policies {
            #expect(!policy.isEnabled)
            #expect(!policy.isDue(now: start.addingTimeInterval(365 * day), lastRun: nil))
            #expect(policy.nextRun(lastRun: nil) == nil)
        }
    }

    @Test("Cochée, la règle passe une période plus tard, pas à l'instant")
    func firstRunAfterOnePeriod() {
        let policy = RetentionPolicy(family: .packageCaches, isEnabled: true, frequency: .weekly, enabledSince: start)
        #expect(!policy.isDue(now: start, lastRun: nil))
        #expect(!policy.isDue(now: start.addingTimeInterval(6 * day), lastRun: nil))
        #expect(policy.isDue(now: start.addingTimeInterval(7 * day), lastRun: nil))
    }

    @Test("Après un passage, la suivante vient une période plus tard")
    func afterRun() {
        let policy = RetentionPolicy(family: .buildCaches, isEnabled: true, frequency: .daily, enabledSince: start)
        let lastRun = start.addingTimeInterval(10 * day)
        #expect(policy.nextRun(lastRun: lastRun) == lastRun.addingTimeInterval(day))
        #expect(!policy.isDue(now: lastRun.addingTimeInterval(day - 60), lastRun: lastRun))
        #expect(policy.isDue(now: lastRun.addingTimeInterval(day), lastRun: lastRun))
    }

    @Test("Recochée après un vieux passage : on repart de la date où on l'a cochée")
    func reenabled() {
        let oldRun = start
        let policy = RetentionPolicy(family: .packageCaches, isEnabled: true, frequency: .monthly,
                                     enabledSince: start.addingTimeInterval(100 * day))
        #expect(!policy.isDue(now: start.addingTimeInterval(101 * day), lastRun: oldRun))
        #expect(policy.isDue(now: start.addingTimeInterval(130 * day), lastRun: oldRun))
    }

    @Test("Cochée sans date connue : jamais de passage surprise")
    func noAnchor() {
        let policy = RetentionPolicy(family: .packageCaches, isEnabled: true)
        #expect(!policy.isDue(now: start, lastRun: nil))
    }
}

// MARK: - Ce qu'une règle a le droit de prendre

@Suite("Règles planifiées : le filtre")
struct RetentionFilterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let policy = RetentionPolicy(family: .packageCaches, isEnabled: true, minimumAgeDays: 30)
    let build = RetentionPolicy(family: .buildCaches, isEnabled: true, minimumAgeDays: 30)

    func item(rule: String = "cache.npm", category: ItemCategory = .packageCaches, safety: SafetyClass = .safe,
              method: CleanupMethod = .removeNow, ageDays: Double? = 60, freeable: Int64 = 1_000_000,
              notes: [ItemNote] = [], protections: [ProtectionReason] = []) -> CleanupItem {
        CleanupItem(title: rule, paths: [URL(fileURLWithPath: "/tmp/oust-filtre/\(UUID().uuidString)")],
                    category: category, owner: "test", ruleID: rule, safety: safety, protections: protections,
                    notes: notes, method: method, sizes: Sizes(allocated: freeable, freeable: freeable),
                    lastActivity: ageDays.map { now.addingTimeInterval(-$0 * 86_400) }, rebuild: .automatic)
    }

    func admits(_ item: CleanupItem, _ policy: RetentionPolicy? = nil, recency: Int = 7) -> Bool {
        RetentionFilter.admits(item, policy: policy ?? self.policy, recencyDays: recency, now: now)
    }

    @Test("Un cache de paquets sûr, inutilisé depuis longtemps : pris")
    func admitsOldSafeCache() {
        #expect(admits(item()))
        #expect(admits(item(rule: "cache.gradle", safety: .rebuilds)))
    }

    @Test("Rien d'« à examiner », rien de protégé, rien d'inaccessible")
    func classes() {
        #expect(!admits(item(rule: "cache.maven", safety: .review)))
        #expect(!admits(item(safety: .review)))
        #expect(!admits(item(protections: [.daemonRunning(name: "Gradle")])))
        #expect(!admits(item(safety: .inaccessible)))
    }

    @Test("Rien qui aille à la corbeille du Mac, rien qu'un outil supprimerait")
    func methods() {
        #expect(!admits(item(method: .trash)))
        #expect(!admits(item(method: .archive(copy: "/Volumes/Archive/x"))))
        #expect(!admits(item(method: .brewCleanup(executable: "/opt/homebrew/bin/brew"))))
        #expect(!admits(item(method: .localSnapshot(date: "2026-10-18-120000"))))
        #expect(!admits(item(method: .manual)))
    }

    @Test("Rien de personnel, même marqué sûr par erreur : seules les règles nommées passent")
    func personal() {
        #expect(!admits(item(rule: "downloads.large", category: .downloads)))
        #expect(!admits(item(rule: "trash.contents", category: .trash)))
        #expect(!admits(item(rule: "duplicate.copy", category: .duplicates)))
        #expect(!admits(item(rule: "model.ollama", category: .aiModels)))
        #expect(!admits(item(rule: "cache.app", category: .appCaches)))
        // La bonne règle dans la mauvaise catégorie ne passe pas non plus.
        #expect(!admits(item(rule: "cache.npm", category: .downloads)))
    }

    @Test("Chaque famille garde ses règles")
    func families() {
        let derived = item(rule: "xcode.derived_data", category: .xcode, safety: .rebuilds)
        #expect(!admits(derived))
        #expect(admits(derived, build))
        #expect(!admits(item(), build))
        // Des artefacts qui ne sont pas des caches : leur date dit l'installation,
        // pas le dernier usage du projet.
        #expect(!admits(item(rule: "artifact.node_modules", category: .projectArtifacts, safety: .rebuilds), build))
        #expect(!admits(item(rule: "artifact.output", category: .projectArtifacts, safety: .rebuilds), build))
        #expect(!admits(item(rule: "xcode.device_support", category: .xcode), build))
        #expect(!admits(item(rule: "xcode.archive", category: .xcode, safety: .review, method: .trash), build))
        #expect(admits(item(rule: "artifact.build_cache", category: .projectArtifacts), build))
    }

    @Test("L'âge : connu, et au-delà du minimum")
    func age() {
        #expect(!admits(item(ageDays: 29)))
        #expect(admits(item(ageDays: 30)))
        #expect(!admits(item(ageDays: nil)))
        // Une date dans le futur (horloge déréglée) n'est pas un vieil élément.
        #expect(!admits(item(ageDays: -3)))
    }

    @Test("Ce qui se reconstruit garde la garde de récence, même avec un âge minimal plus court")
    func recency() {
        var short = policy
        short.minimumAgeDays = 0
        #expect(!admits(item(rule: "cache.pnpm", safety: .rebuilds, ageDays: 3), short, recency: 7))
        #expect(admits(item(rule: "cache.pnpm", safety: .rebuilds, ageDays: 8), short, recency: 7))
        #expect(admits(item(ageDays: 1), short, recency: 7))
    }

    @Test("Une note qui appelle un regard écarte l'élément ; un orphelin ou des blocs partagés non")
    func notes() {
        #expect(!admits(item(notes: [.recentlyModified(days: 2)])))
        #expect(!admits(item(notes: [.managedSeparately])))
        #expect(!admits(item(notes: [.usedByProject(name: "app")])))
        #expect(!admits(item(notes: [.estimated])))
        #expect(admits(item(notes: [.partlyShared])))
        #expect(admits(item(rule: "xcode.derived_data_orphan", category: .xcode, notes: [.orphan]), build))
    }

    @Test("Rien à rendre, rien à prendre")
    func empty() {
        #expect(!admits(item(freeable: 0)))
    }

    @Test("Le tri : le plus gros d'abord")
    func sorted() {
        let small = item(freeable: 1_000)
        let large = item(freeable: 9_000)
        let review = item(safety: .review, freeable: 50_000)
        let eligible = RetentionFilter.eligible([small, review, large], policy: policy, recencyDays: 7, now: now)
        #expect(eligible.map(\.id) == [large.id, small.id])
    }

    @Test("Chaque règle d'une famille existe au catalogue des règles")
    func knownRules() {
        let known = Set(RuleCatalog.ruleIDs)
        for family in RetentionFamily.allCases {
            #expect(family.ruleIDs.isSubset(of: known), "règle inconnue dans \(family)")
        }
    }
}

// MARK: - Réglages

@Suite("Réglages de la veille")
struct WatchSettingsTests {
    @Test("Alerte active, règles désactivées, par défaut")
    func defaults() {
        let settings = WatchSettings()
        #expect(settings.alertsLowDisk)
        #expect(settings.policies.allSatisfy { !$0.isEnabled })
    }

    @Test("Un fichier abîmé rend les réglages par défaut, règles désactivées")
    func tolerant() {
        #expect(WatchSettings.decode(Data("{ pas du json".utf8)) == WatchSettings())
        #expect(WatchSettings.decode(nil) == WatchSettings())
        #expect(WatchState.decode(Data([0, 1, 2])) == WatchState())
    }

    @Test("Un fichier d'une version plus ancienne garde ce qu'il sait ; le reste prend sa valeur par défaut")
    func olderFile() {
        let old = Data(#"{"showsMenuBar": false, "threshold": {"gigabytes": {"_0": 30}}}"#.utf8)
        let settings = WatchSettings.decode(old)
        #expect(settings.threshold == .gigabytes(30))
        #expect(settings.alertsLowDisk)
        #expect(!settings.alsoNotifies)
        #expect(settings.policies.allSatisfy { !$0.isEnabled })
    }

    @Test("La notification de macOS est une option, désactivée par défaut : l'alerte part en capsule")
    func notificationOptional() {
        #expect(!WatchSettings().alsoNotifies)
    }

    @Test("Aller-retour, et une règle modifiée garde sa place")
    func roundTrip() {
        var settings = WatchSettings()
        settings.threshold = .gigabytes(50)
        settings.update(.buildCaches) { $0.isEnabled = true; $0.frequency = .daily }
        settings.update(.packageCaches) { $0.minimumAgeDays = 90 }
        #expect(settings.policies.map(\.family) == RetentionFamily.allCases)
        #expect(WatchSettings.decode(settings.encoded()) == settings)
        #expect(settings.policy(.buildCaches).frequency == .daily)
    }
}

// MARK: - Catalogue

@Suite("Les clés construites de la veille sont au catalogue")
struct WatchCatalogTests {
    static let catalog: Set<String> = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OustLocalization/Resources/Localizable.xcstrings")
        let data = (try? Data(contentsOf: url)) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return Set((object?["strings"] as? [String: Any] ?? [:]).keys)
    }()

    @Test("Familles et fréquences")
    func keys() {
        let keys = RetentionFamily.allCases.flatMap { [$0.localizationKey, $0.detailKey] }
            + RetentionFrequency.allCases.map(\.localizationKey)
        for key in keys { #expect(Self.catalog.contains(key), "clé absente : \(key)") }
    }
}

// MARK: - Un passage, de bout en bout

/// Le filtre puis le moteur, comme un passage planifié, dans un dossier
/// temporaire à soi (RULES.md, règle 8).
@Suite("Un passage planifié ne supprime que ce que le filtre admet")
struct RetentionRunTests {
    final class Bench {
        let root: URL
        var home: URL { root.appendingPathComponent("maison") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("oust-veille-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func folder(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 20_000).write(to: url.appendingPathComponent("blob"))
            return url
        }

        func item(_ url: URL, rule: String, category: ItemCategory, safety: SafetyClass, method: CleanupMethod,
                  ageDays: Double) -> CleanupItem {
            var info = stat()
            lstat(url.path, &info)
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            return CleanupItem(title: url.lastPathComponent, paths: [url], category: category, owner: "test",
                               ruleID: rule, safety: safety, method: method, sizes: Sizes(private: 20_000),
                               lastActivity: Date().addingTimeInterval(-ageDays * 86_400), rebuild: .automatic,
                               fingerprint: Fingerprint(modificationDate: modified, fileID: UInt64(info.st_ino)))
        }

        var engine: CleanupEngine {
            CleanupEngine(trasher: FolderTrasher(folder: root.appendingPathComponent("_corbeille")),
                          history: HistoryStore(directory: root.appendingPathComponent("_historique")),
                          pathGuard: PathGuard(home: home), processes: { ProcessSnapshot(processes: []) },
                          capacity: { _ in nil }, deleteSnapshots: { _ in false }, runningApps: { [] })
        }
    }

    @Test("Le vieux cache part, le reste ne bouge pas, et tout est au journal")
    func endToEnd() async throws {
        let bench = try Bench()
        let old = try bench.folder(".npm/_cacache")
        let young = try bench.folder("Library/Caches/pip")
        let maven = try bench.folder(".m2/repository")
        let download = try bench.folder("Downloads/gros")
        let items = [
            bench.item(old, rule: "cache.npm", category: .packageCaches, safety: .safe, method: .removeNow, ageDays: 45),
            bench.item(young, rule: "cache.pip", category: .packageCaches, safety: .safe, method: .removeNow, ageDays: 2),
            bench.item(maven, rule: "cache.maven", category: .packageCaches, safety: .review, method: .removeNow, ageDays: 400),
            bench.item(download, rule: "downloads.large", category: .downloads, safety: .review, method: .trash, ageDays: 400),
        ]
        let policy = RetentionPolicy(family: .packageCaches, isEnabled: true, minimumAgeDays: 30)
        let eligible = RetentionFilter.eligible(items, policy: policy, recencyDays: 7)
        #expect(eligible.map(\.ruleID) == ["cache.npm"])

        var report: CleanupReport?
        for await event in bench.engine.run(eligible) {
            if case .finished(let finished) = event { report = finished }
        }
        let outcomes = try #require(report).outcomes
        #expect(outcomes.map(\.result) == [.removed])
        #expect(!FileManager.default.fileExists(atPath: old.path))
        for kept in [young, maven, download] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
        #expect(!FileManager.default.fileExists(atPath: bench.root.appendingPathComponent("_corbeille").path))
        let journal = await HistoryStore(directory: bench.root.appendingPathComponent("_historique")).load()
        #expect(journal.map(\.itemID) == [eligible[0].id])
    }

    @Test("Changé depuis l'aperçu : la revalidation le garde")
    func revalidated() async throws {
        let bench = try Bench()
        let cache = try bench.folder("Library/Caches/Homebrew")
        let item = bench.item(cache, rule: "cache.homebrew", category: .packageCaches, safety: .safe,
                              method: .removeNow, ageDays: 90)
        let policy = RetentionPolicy(family: .packageCaches, isEnabled: true, minimumAgeDays: 30)
        let eligible = RetentionFilter.eligible([item], policy: policy, recencyDays: 7)
        #expect(eligible.count == 1)
        // Remplacé entre l'aperçu et le passage : un autre inode.
        try FileManager.default.removeItem(at: cache)
        _ = try bench.folder("Library/Caches/Homebrew")

        var report: CleanupReport?
        for await event in bench.engine.run(eligible) {
            if case .finished(let finished) = event { report = finished }
        }
        #expect(try #require(report).outcomes.map(\.result) == [.skipped(.changedSinceScan)])
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }
}

// MARK: - Disques branchés

@Suite("Alerte disque bas : quels disques branchés sont surveillés")
struct WatchedVolumesTests {
    func volume(_ path: String, local: Bool = true, browsable: Bool = true, readOnly: Bool = false,
                root: Bool = false) -> WatchedVolumes.Candidate {
        WatchedVolumes.Candidate(path: path, isLocal: local, isBrowsable: browsable, isReadOnly: readOnly,
                                 isRootFileSystem: root)
    }

    @Test("Un disque externe ordinaire est surveillé")
    func external() {
        #expect(WatchedVolumes.accepts(volume("/Volumes/Samsung T7"), timeMachine: []))
    }

    @Test("Pas les disques réseau, les images en lecture seule, ni ce qu'on ne voit pas dans le Finder")
    func excluded() {
        #expect(!WatchedVolumes.accepts(volume("/Volumes/NAS", local: false), timeMachine: []))
        #expect(!WatchedVolumes.accepts(volume("/Volumes/Installer", readOnly: true), timeMachine: []))
        #expect(!WatchedVolumes.accepts(volume("/Volumes/Cache", browsable: false), timeMachine: []))
    }

    @Test("Pas le disque de démarrage ni les volumes du système : ils ont leur propre relevé")
    func system() {
        #expect(!WatchedVolumes.accepts(volume("/", root: true), timeMachine: []))
        #expect(!WatchedVolumes.accepts(volume("/System/Volumes/Data"), timeMachine: []))
    }

    @Test("Pas les sauvegardes Time Machine, pleines par nature")
    func timeMachine() {
        let plist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Destinations</key><array>
        <dict><key>Kind</key><string>Local</string><key>MountPoint</key><string>/Volumes/Sauvegarde/</string>
        <key>Name</key><string>Sauvegarde</string></dict>
        <dict><key>Kind</key><string>Network</string><key>Name</key><string>NAS</string></dict>
        </array></dict></plist>
        """.utf8)
        let mounts = WatchedVolumes.timeMachineMountPoints(in: plist)
        #expect(mounts == ["/Volumes/Sauvegarde"])
        #expect(!WatchedVolumes.accepts(volume("/Volumes/Sauvegarde"), timeMachine: mounts))
        #expect(WatchedVolumes.accepts(volume("/Volumes/Photos"), timeMachine: mounts))
    }

    @Test("Une sortie de tmutil illisible n'écarte rien")
    func unreadable() {
        #expect(WatchedVolumes.timeMachineMountPoints(in: Data("No destinations configured.".utf8)).isEmpty)
    }
}

@Suite("Barre de menus : ce qu'on peut éjecter")
struct EjectTests {
    @Test("Les disques externes et amovibles, jamais le disque de démarrage ni un disque interne fixe")
    func ejectable() {
        #expect(WatchedVolumes.isEjectable(isBoot: false, isInternal: false, isRemovable: true))
        #expect(WatchedVolumes.isEjectable(isBoot: false, isInternal: false, isRemovable: false))
        #expect(WatchedVolumes.isEjectable(isBoot: false, isInternal: true, isRemovable: true))
        #expect(!WatchedVolumes.isEjectable(isBoot: false, isInternal: true, isRemovable: false))
        #expect(!WatchedVolumes.isEjectable(isBoot: true, isInternal: true, isRemovable: false))
        #expect(!WatchedVolumes.isEjectable(isBoot: true, isInternal: false, isRemovable: true))
    }
}
