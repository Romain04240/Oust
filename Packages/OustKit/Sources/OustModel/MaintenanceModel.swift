import Darwin
import Foundation
import Observation
import OustBrowsers
import OustCore
import OustLocalization
import OustRules
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
