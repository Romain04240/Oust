import Darwin
import Foundation
import Observation
import OustBrowsers
import OustCore
import OustLocalization
import OustRules
import OustSafety
import OustScan
import OustVolume
import OustWatch

/// L'entretien planifié (Romain, 18/10/2026) : chaque jour, chaque semaine ou
/// chaque mois, l'analyse complète par règles tourne en arrière-plan, et ce
/// que la présélection cocherait se montre en pastille (et, si on le veut, en
/// notification). Un clic ouvre la corbeille d'Oust! avec ces éléments.
///
/// L'entretien ne supprime rien. Le vide se fait dans la corbeille, après la
/// revue et la confirmation habituelles, par `CleanupEngine`, qui revalide
/// chaque élément juste avant d'agir.
@MainActor
@Observable
public final class MaintenanceModel {
    weak var watch: WatchModel?
    private var app: AppModel? { watch?.app }

    public var settings: MaintenanceSettings {
        didSet {
            guard settings != oldValue else { return }
            defaults.set(settings.encoded(), forKey: Self.settingsKey)
            // Cocher la notification, c'est le bon moment pour demander la
            // permission : l'utilisateur sait pourquoi on la demande.
            if settings.notifies, !oldValue.notifies {
                Task {
                    _ = await Notifier.ensurePermission()
                    await watch?.refreshPermissions()
                }
            }
        }
    }

    /// Le dernier entretien, d'un lancement à l'autre (Réglages).
    public private(set) var state: MaintenanceState {
        didSet { defaults.set(state.encoded(), forKey: Self.stateKey) }
    }
    /// L'analyse de l'entretien tourne.
    public private(set) var isRunning = false
    /// Ce que le dernier entretien a trouvé, le temps qu'Oust! reste ouvert :
    /// de quoi répondre au clic sur la notification.
    public private(set) var finding: MaintenanceFinding?
    /// Montre ce qu'a trouvé l'entretien en pastille (l'app pose le panneau).
    @ObservationIgnored public var onFinding: (@MainActor (MaintenanceFinding) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let launchedAt = Date()
    /// Cinq minutes après le lancement, au plus tôt, pour un entretien planifié.
    static let settleDelay: TimeInterval = 300

    static let settingsKey = "watch.maintenance"
    static let stateKey = "watch.maintenance.state"
    /// L'action portée par la notification : remplir la corbeille, puis l'ouvrir.
    public static let reviewAction = "maintenance.review"
    static let notificationID = "fr.meaillais.oust.maintenance"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.settings = MaintenanceSettings.decode(defaults.data(forKey: Self.settingsKey))
        self.state = MaintenanceState.decode(defaults.data(forKey: Self.stateKey))
    }

    // MARK: - Planification

    public var nextRun: Date? { settings.nextRun(lastRun: state.lastRun) }

    /// Cocher l'entretien : le premier viendra une période plus tard, jamais à
    /// l'instant où l'on coche.
    public func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        settings.enabledSince = enabled ? Date() : nil
    }

    /// Un entretien peut-il commencer : jamais pendant que l'utilisateur
    /// analyse, cherche des doublons ou fait le vide, ni pendant une règle planifiée.
    public var canRun: Bool {
        guard let app, let watch else { return false }
        return !isRunning && watch.runningFamily == nil && app.cleaning != .running && !app.analysis.isRunning
            && !app.duplicates.isRunning && !app.explorer.isRunning
    }

    /// À chaque tour de la veille. Dû mais empêché : on réessaie au tour suivant.
    func runIfDue(now: Date = Date()) async {
        // Un entretien en retard (Mac éteint, Oust! fermé) attend que la session
        // se soit posée : à la connexion, le Mac a mieux à faire qu'analyser.
        guard now.timeIntervalSince(launchedAt) >= Self.settleDelay else { return }
        guard settings.isDue(now: now, lastRun: state.lastRun), canRun else { return }
        await run(manual: false)
    }

    /// « Faire l'entretien maintenant » : un vrai entretien, compté comme tel,
    /// dont la pastille part même si on l'a coupée : on vient de la demander.
    public func runNow() async {
        await run(manual: true)
    }

    private func run(manual: Bool) async {
        guard canRun, let app else { return }
        isRunning = true
        defer { isRunning = false }
        let found = await scan(app)
        finding = found
        state = MaintenanceState(lastRun: found.date, lastTotal: found.total, lastCount: found.items.count)
        // Quelques mégaoctets ne valent pas une pastille ; les Réglages le disent.
        guard manual || found.isWorthTelling else { return }
        if manual || settings.showsCapsule { onFinding?(found) }
        guard !manual, settings.notifies else { return }
        let permission = await Notifier.ensurePermission()
        await watch?.refreshPermissions()
        guard permission == .allowed else { return }
        await Notifier.post(id: Self.notificationID, title: L10n.string("maintenance.notification.title"),
                            body: Self.notificationBody(found), opening: .cart, sound: false,
                            action: Self.reviewAction)
    }

    /// « 12 Go à récupérer sans risque : Xcode, npm, Safari. »
    static func notificationBody(_ finding: MaintenanceFinding) -> String {
        let owners = finding.leadingOwners().joined(separator: ", ")
        return L10n.string("maintenance.notification.body", Formatters.bytes(finding.total), owners)
    }

    // MARK: - Analyse

    /// L'analyse complète par règles, plus les caches des navigateurs, sans
    /// rien toucher ; puis ce que la présélection cocherait.
    private func scan(_ app: AppModel) async -> MaintenanceFinding {
        let preferences = app.preferences
        var context = RuleContext(home: app.home, projectRoots: preferences.projectRoots,
                                  historyRetentionDays: preferences.historyRetentionDays,
                                  compressionAgeDays: preferences.compressionAgeMonths * 30)
        // L'arbre partagé s'il est déjà là (la fenêtre l'a chargé) : les mêmes
        // tailles que l'analyse, en une seconde ou deux. Sinon chaque élément
        // est mesuré sur le disque, plutôt que de garder en mémoire l'arbre de
        // tout le disque pour une app qui vit dans la barre de menus.
        let measurer: Measurer
        if app.disk.currentTree != nil {
            let tree = app.disk.treeProvider()
            context.tree = tree
            measurer = .tree(tree)
        } else {
            measurer = .disk
        }
        let home = app.home
        let recency = preferences.recencyDays
        let engine = app.engine
        let items = await Task.detached(priority: .utility) {
            let found = await RuleEngine.collect(context, measurer: measurer)
            let browsers = await Self.measured(BrowserFinder.caches(home: home))
            return MaintenanceSelection.announced((found + browsers).filter { engine.supports($0.method) }, recencyDays: recency)
        }.value
        return MaintenanceFinding(items: items.filter(Self.stillThere), capacity: VolumeService.bootVolume()?.capacity)
    }

    /// Les caches des navigateurs, mesurés à part : ils ne viennent pas des règles.
    nonisolated static func measured(_ items: [CleanupItem]) async -> [CleanupItem] {
        let measures = await Scanner.measure(items.flatMap(\.paths))
        return items.map { item in
            var item = item
            item.sizes = item.paths.compactMap { measures[$0]?.sizes }.total()
            return item
        }
    }

    /// Parti depuis l'analyse (un vide fait entre-temps) : on ne l'annonce pas.
    nonisolated static func stillThere(_ item: CleanupItem) -> Bool {
        guard let first = item.paths.first else { return true }
        var info = stat()
        return lstat(first.path, &info) == 0
    }

    /// La mesure d'origine ne suit pas un cache qui a été vidé ou recréé.
    public nonisolated static func capsuleFinding(
        _ finding: MaintenanceFinding, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> MaintenanceFinding? {
        await capsuleFinding(finding, home: home) { paths, options, progress in
            await Scanner.scan(paths, options: options, progress: progress)
        }
    }

    nonisolated static func capsuleFinding(
        _ finding: MaintenanceFinding, home: URL,
        scan: @escaping @Sendable ([URL], ScanOptions, ScanProgress) async -> ScanResult
    ) async -> MaintenanceFinding? {
        guard !finding.items.isEmpty else { return finding }
        let progress = ScanProgress()
        let (results, continuation) = AsyncStream<MaintenanceFinding?>.makeStream()
        let work = Task.detached(priority: .utility) {
            continuation.yield(await measureCapsule(finding, home: home, progress: progress, scan: scan))
            continuation.finish()
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            progress.cancel()
            continuation.finish()
        }
        defer { progress.cancel(); work.cancel(); deadline.cancel(); continuation.finish() }
        var iterator = results.makeAsyncIterator()
        if let result = await iterator.next() ?? nil { return result }
        guard !Task.isCancelled else { return nil }
        var unavailable = finding
        unavailable.items = []
        unavailable.measurementIsComplete = false
        return unavailable
    }

    private struct CapsulePathStamp: Equatable {
        let device: Int32
        let inode: UInt64
        let birth: timespec
        let modified: timespec
        let changed: timespec

        init(_ info: stat) {
            device = info.st_dev
            inode = UInt64(info.st_ino)
            birth = info.st_birthtimespec
            modified = info.st_mtimespec
            changed = info.st_ctimespec
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            func same(_ lhs: timespec, _ rhs: timespec) -> Bool {
                lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
            }
            return lhs.device == rhs.device && lhs.inode == rhs.inode
                && same(lhs.birth, rhs.birth) && same(lhs.modified, rhs.modified) && same(lhs.changed, rhs.changed)
        }
    }

    private struct CapsuleTarget: Equatable {
        let path: URL
        let stamp: CapsulePathStamp
    }

    private enum CapsulePathProbe {
        case present(CapsuleTarget), missing, unavailable

        static func read(_ path: URL, guardPaths: PathGuard) -> Self {
            var info = stat()
            guard lstat(path.path, &info) == 0 else {
                return errno == ENOENT || errno == ENOTDIR ? .missing : .unavailable
            }
            let kind = info.st_mode & S_IFMT
            guard [S_IFDIR, S_IFREG].contains(kind),
                  let resolved = guardPaths.allowedMeasurementPath(path) else { return .unavailable }
            let flags = O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC
            let fd = open(resolved.path, flags | (kind == S_IFDIR ? O_DIRECTORY : 0))
            guard fd >= 0 else { return .unavailable }
            defer { close(fd) }
            var actual = stat()
            let stamp = CapsulePathStamp(info)
            guard fstat(fd, &actual) == 0, stamp == CapsulePathStamp(actual) else { return .unavailable }
            return .present(CapsuleTarget(path: resolved, stamp: stamp))
        }
    }

    private nonisolated static func measureCapsule(
        _ finding: MaintenanceFinding, home: URL, progress: ScanProgress,
        scan: @Sendable ([URL], ScanOptions, ScanProgress) async -> ScanResult
    ) async -> MaintenanceFinding? {
        let guardPaths = PathGuard(home: home)
        var targets: [URL: CapsuleTarget] = [:]
        var seen: Set<URL> = []
        var paths: [URL] = []
        var complete = finding.measurementIsComplete
        for path in finding.items.flatMap(\.paths) where seen.insert(path).inserted {
            guard !progress.isCancelled else { return nil }
            switch CapsulePathProbe.read(path, guardPaths: guardPaths) {
            case .present(let target):
                targets[path] = target
                paths.append(path)
            case .missing: break
            case .unavailable: complete = false
            }
        }
        let candidates = finding.items.filter { item in
            let present = item.paths.compactMap { targets[$0] }
            guard let first = present.first else { return false }
            // Le panier conserve l'opération groupée d'origine. Si un chemin
            // manque, le gain de l'ensemble reste indéterminé.
            guard present.count == item.paths.count else {
                complete = false
                return false
            }
            return item.fingerprint?.fileID.map { $0 == first.stamp.inode } ?? true
        }
        let wanted = Set(candidates.flatMap(\.paths))
        paths = paths.filter(wanted.contains)
        var options = ScanOptions.measuring
        options.threads = 2
        options.bindMeasurementsToRoots = true
        options.readOnlyPreferencesDirectory = PreferenceDirectory.url(in: home).path
        options.deviceBackupsDirectory = DeviceBackupPath.root(in: home).path
        var sizes: [URL: Sizes] = [:]
        let requests = paths.compactMap { path in targets[path].map { (path, $0) } }
        if !requests.isEmpty {
            var requested: Set<URL> = []
            let resolvedPaths = requests.map { $0.1.path }.filter { requested.insert($0).inserted }
            let measured = await scan(resolvedPaths, options, progress)
            guard !progress.isCancelled else { return nil }
            guard measured.freeableEstimatesAreValid else {
                var unavailable = finding
                unavailable.items = []
                unavailable.measurementIsComplete = false
                return unavailable
            }
            if measured.roots.count != resolvedPaths.count || !measured.skippedVolumes.isEmpty { complete = false }
            let roots = Dictionary(uniqueKeysWithValues: zip(resolvedPaths, measured.roots))
            for (path, target) in requests {
                guard !progress.isCancelled else { return nil }
                guard let node = roots[target.path], node.status == .ok, node.inaccessibleCount == 0,
                      node.fileID == target.stamp.inode, node.verifiedMeasurementDevice == target.stamp.device,
                      case .present(let after) = CapsulePathProbe.read(path, guardPaths: guardPaths), after == target
                else {
                    complete = false
                    continue
                }
                sizes[path] = node.total
            }
        }
        guard !progress.isCancelled else { return nil }
        var used: Set<URL> = []
        var current = finding
        current.measurementIsComplete = complete
        current.items = candidates.compactMap { item in
            guard item.paths.allSatisfy({ sizes[$0] != nil }) else { return nil }
            var item = item
            item.sizes = item.paths.compactMap { path in
                guard let target = targets[path], used.insert(target.path).inserted else { return nil }
                return sizes[path]
            }.total()
            return item.sizes.freeable > 0 ? item : nil
        }
        return current
    }

    // MARK: - La revue

    /// La pastille ou la notification cliquée : la corbeille d'Oust! s'ouvre
    /// avec ce que l'entretien a trouvé, pour la revue et la confirmation
    /// habituelles. Ce que la corbeille contenait déjà y reste.
    public func review(_ finding: MaintenanceFinding) {
        guard let app else { return }
        // La version de l'entretien est la plus fraîche, sauf si l'analyse a vu
        // depuis une raison de protéger l'élément (RULES.md, règle 3). Un cache
        // de navigateur ouvert entre quand même : la revue propose de fermer le
        // navigateur, et la revalidation le garde s'il ne l'est pas.
        let fresh = finding.items.filter(Self.stillThere).filter { item in
            guard app.engine.supports(item.method) else { return false }
            guard let known = app.items[item.id], !known.protections.isEmpty else { return true }
            return BrowserFinder.browser(of: known) != nil && known.protections.allSatisfy(\.isAppRunning)
        }
        app.refreshItems(fresh, addingToCart: true)
        app.searchText = ""
        app.section = .cart
    }

    /// Une notification cliquée porte son action (`NotificationRouter`).
    public func perform(_ action: String) {
        guard action == Self.reviewAction, let finding else { return }
        review(finding)
    }

    // MARK: - Essayer

    /// « Essayer » (Réglages) : la pastille tout de suite, avec les chiffres
    /// d'une analyse connue, celle de la fenêtre ou le dernier entretien. Rien
    /// n'est enregistré : ni passage, ni date du prochain. Sans rien de connu,
    /// l'analyse de l'entretien tourne une fois, sans compter comme un passage.
    public func showPreview() async {
        guard let app else { return }
        let capacity = VolumeService.bootVolume()?.capacity
        if app.analysis.hasRun {
            // Les caches de navigateurs comptés comme navigateurs fermés, comme
            // le fait l'entretien, avec les tailles que l'analyse a mesurées.
            let browsers = BrowserFinder.caches(home: app.home).compactMap { fresh -> CleanupItem? in
                guard let known = app.items[fresh.id] else { return nil }
                var item = fresh
                item.sizes = known.sizes
                return item
            }
            let items = MaintenanceSelection.announced((browsers + Array(app.items.values)).filter { app.engine.supports($0.method) },
                                                       recencyDays: app.preferences.recencyDays)
            onFinding?(MaintenanceFinding(items: items, capacity: capacity))
        } else if var known = finding {
            known.items = known.items.filter { app.engine.supports($0.method) }
            known.capacity = capacity ?? known.capacity
            onFinding?(known)
        } else {
            guard canRun else { return }
            isRunning = true
            defer { isRunning = false }
            onFinding?(await scan(app))
        }
    }
}

extension ProtectionReason {
    var isAppRunning: Bool {
        if case .appRunning = self { return true }
        return false
    }
}
