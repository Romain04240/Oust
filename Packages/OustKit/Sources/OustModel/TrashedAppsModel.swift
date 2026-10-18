import AppKit
import Foundation
import Observation
import os
import OustCore
import OustLocalization
import OustSafety
import OustUninstall

/// Les applications qu'on met à la corbeille du Mac, et ce qu'elles laissent
/// (accepté par Romain le 18/10/2026, sur le modèle de CleanMacJoe).
///
/// Tant qu'Oust! tourne, les corbeilles du Mac sont surveillées. Quand un
/// paquet `.app` y arrive, Oust! attend un peu (une mise à jour pose la version
/// neuve juste après avoir jeté l'ancienne), puis cherche ses restes en
/// correspondance stricte (`TrashedAppFinder`). Au-delà de 1 Mo, il le dit par
/// une notification ; un clic mène à la revue, dans la section Applications.
/// Rien n'est retiré ici : la revue jette dans la corbeille d'Oust!, d'où le
/// vide se fait avec sa confirmation, comme tout le reste (SPEC §6.3).
@MainActor
@Observable
public final class TrashedAppsModel {
    weak var app: AppModel?

    /// Proposer les restes d'une application mise à la corbeille du Mac.
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                start()
                Task { notifications = await Notifier.ensurePermission() }
            } else {
                stop()
            }
        }
    }

    /// Les applications mises à la corbeille dont les restes attendent la revue,
    /// la plus récente en tête.
    public private(set) var reports: [TrashedApp] = []
    /// Ce que l'utilisateur a coché, par application (identifiants d'éléments).
    public private(set) var chosen: [String: Set<String>] = [:]
    /// Les applications qu'on relit en ce moment (à l'ouverture de la revue).
    public private(set) var refreshing: Set<String> = []
    /// Les rapports devenus caducs : l'application est revenue, ou une autre
    /// copie est là. Gardés pour le dire dans la revue.
    public private(set) var withdrawn: [String: TrashedAppSkip] = [:]
    /// Les corbeilles qu'on lit vraiment. Vide sans l'Accès complet au disque :
    /// macOS refuse alors de laisser lire `~/.Trash`.
    public private(set) var watchedFolders: [URL] = []
    public private(set) var notifications: NotificationPermission = .unknown

    /// Point d'accroche de la pastille façon Juicy (`FeatureMenuBar`), à
    /// brancher quand elle saura montrer autre chose que le disque bas. Appelé
    /// à chaque proposition, en plus de la notification.
    @ObservationIgnored public var onLeftovers: (@MainActor (TrashedApp) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watcher: TrashWatcher?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Les arrivées en cours d'examen, par chemin et numéro de fichier. Oubliées
    /// ensuite : remise en place puis rejetée, l'application est réexaminée.
    @ObservationIgnored private var inFlight: Set<String> = []

    /// Ce qui arrive dans les corbeilles et ce qu'on en décide, dans le journal
    /// système : la proposition elle-même ne se voit qu'au-delà du seuil.
    @ObservationIgnored private let log = Logger(subsystem: "fr.meaillais.oust", category: "trashed-apps")

    public static let enabledKey = "watch.trashedAppLeftovers"
    /// Ce qu'on laisse à une mise à jour pour poser la version neuve, et à
    /// l'utilisateur pour se raviser (⌘Z, « Remettre »). La revue revérifie de
    /// toute façon à l'ouverture.
    static let settleDelay: Duration = .seconds(10)
    static let notificationPrefix = "fr.meaillais.oust.trashed-app."
    static let focusPrefix = "trashed-app|"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Activé par défaut : la proposition ne naît que d'un geste de
        // l'utilisateur (jeter une application), ne retire rien, et ne sort
        // pas du Mac. Désactivée, presque personne ne la découvrirait.
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - Surveillance

    /// Au lancement, fenêtre ouverte ou non (`WatchModel.start`).
    public func start() {
        NotificationRouter.focusHandler = { [weak self] focus in self?.focus(focus) }
        guard isEnabled, watcher == nil, let home = app?.home else { return }
        let watcher = TrashWatcher { [weak self] arrival in
            Task { @MainActor in self?.arrived(arrival) }
        }
        self.watcher = watcher
        refreshFolders(home: home)
        // Un disque qu'on branche apporte sa corbeille ; un disque qu'on éjecte
        // emporte la sienne.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFolders(home: home) }
            })
        }
        // L'Accès complet au disque accordé après coup : `~/.Trash` devient lisible.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.watchedFolders.isEmpty else { return }
                self.refreshFolders(home: home)
            }
        })
        Task { notifications = await Notifier.permission() }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        watchedFolders = []
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    private func refreshFolders(home: URL) {
        guard let watcher else { return }
        Task {
            // Hors du fil principal : un disque qui tarde à répondre ne fige rien.
            let folders = await Task.detached(priority: .utility) { MacTrash.folders(home: home) }.value
            let watched = await Task.detached(priority: .utility) { watcher.watch(folders) }.value
            if watched != watchedFolders { watchedFolders = watched }
            log.notice("Corbeilles surveillées : \(watched.count, privacy: .public) sur \(folders.count, privacy: .public)")
        }
    }

    /// Un paquet vient d'arriver dans une corbeille du Mac.
    func arrived(_ arrival: TrashArrival) {
        let key = "\(arrival.url.path)|\(arrival.fileID)"
        guard isEnabled, inFlight.insert(key).inserted else { return }
        Task {
            await examine(arrival)
            inFlight.remove(key)
        }
    }

    /// Lu tout de suite, jugé après un délai, mesuré hors du fil principal.
    func examine(_ arrival: TrashArrival, settle: Duration = settleDelay) async {
        guard let app else { return }
        let signature: @Sendable (URL) -> SigningFacts = Entitlements.signingFacts(of:)
        // Priorité de l'utilisateur : c'est son geste qui déclenche la recherche,
        // et le 18/10/2026 elle a pris 48 s en `.utility`, à côté de la première
        // analyse du disque.
        let read = await Task.detached(priority: .userInitiated) {
            (TrashedAppFinder.read(arrival, signature: signature), signature(arrival.url).teamID)
        }.value
        guard let trashed = read.0, trashed.bundleID != nil else {
            log.notice("Arrivée illisible, ignorée : \(arrival.url.lastPathComponent, privacy: .public)")
            return
        }
        log.notice("Arrivée : \(trashed.bundleID ?? "", privacy: .public)")
        try? await Task.sleep(for: settle)
        // Oust! lui-même vient de désinstaller l'application : ce qu'on a laissé
        // dans la bibliothèque l'a été exprès.
        while app.cleaning == .running { try? await Task.sleep(for: .seconds(5)) }
        // Le journal relu ici : fenêtre jamais ouverte, ou nettoyage d'un agent
        // par `oust`, l'historique en mémoire ne le sait pas.
        let outcomes = app.liveOutcomes + (await app.history.load())
        guard isEnabled, !TrashedAppFinder.isOwnCleanup(arrival, outcomes: outcomes) else {
            log.notice("Désinstallée par Oust!, ou réglage coupé : rien à proposer")
            return
        }
        guard let report = await evaluate(trashed, arrival: arrival, team: read.1), report.isWorthOffering else {
            log.notice("Rien à proposer pour \(trashed.bundleID ?? "", privacy: .public)")
            return
        }
        log.notice("Proposé : \(report.leftovers.count, privacy: .public) restes, \(report.freeable, privacy: .public) octets")
        reports.removeAll { $0.app.bundleID == report.app.bundleID }
        reports.insert(report, at: 0)
        withdrawn[report.id] = nil
        chosen[report.id] = report.preselectedIDs
        onLeftovers?(report)
        await notify(report)
    }

    /// La recherche, puis la mesure. `nil` s'il n'y a rien à proposer.
    private func evaluate(_ trashed: InstalledApp, arrival: TrashArrival, team: String?) async -> TrashedApp? {
        guard let app else { return nil }
        let home = app.home
        let recency = app.preferences.recencyDays
        // Sans l'Accès complet au disque, ni la corbeille ni les conteneurs ne
        // se lisent : on ne cherche rien (RULES.md, règle 3).
        guard FullDiskAccess.isGranted(home: home) == true else { return nil }
        let started = ContinuousClock.now
        let examination = await Task.detached(priority: .userInitiated) {
            TrashedAppFinder.examine(trashed, arrival: arrival, home: home, team: team,
                                     sources: .standard(home: home, canReadContainers: true))
        }.value
        log.notice("Recherche : \(String(describing: ContinuousClock.now - started), privacy: .public)")
        guard case .offer(let found) = examination else {
            if case .skip(let reason) = examination {
                withdrawn[trashed.url.path] = reason
                log.notice("Écartée : \(String(describing: reason), privacy: .public)")
            }
            return nil
        }
        let measuring = ContinuousClock.now
        let measured = await TrashedAppFinder.measured(found, recencyDays: recency)
        log.notice("Mesure : \(String(describing: ContinuousClock.now - measuring), privacy: .public)")
        return measured
    }

    // MARK: - Notification

    private func notify(_ report: TrashedApp) async {
        notifications = await Notifier.ensurePermission()
        log.notice("Permission de notifier : \(String(describing: self.notifications), privacy: .public)")
        guard notifications == .allowed else { return }
        await Notifier.post(
            id: Self.notificationPrefix + (report.app.bundleID ?? report.id),
            title: L10n.string("trashed.notification.title", report.app.name),
            body: L10n.string("trashed.notification.body", Formatters.bytes(report.freeable)),
            opening: .applications, sound: false, focus: Self.focusPrefix + report.id
        )
    }

    /// Le clic sur la notification : la section Applications est déjà ouverte
    /// (`NotificationRouter`), on y montre la revue.
    func focus(_ focus: String) {
        guard focus.hasPrefix(Self.focusPrefix) else { return }
        review(String(focus.dropFirst(Self.focusPrefix.count)))
    }

    public func openNotificationSettings() { Notifier.openSettings() }

    public func refreshPermission() async { notifications = await Notifier.permission() }

    // MARK: - Revue

    public func report(_ id: String) -> TrashedApp? { reports.first { $0.id == id } }

    /// Montre la revue d'une application, après l'avoir relue : depuis la
    /// notification, elle a pu revenir, ou un reste changer.
    public func review(_ id: String) {
        guard let app else { return }
        app.searchText = ""
        app.section = .applications
        app.applications.showTrashed(id)
        Task { await refresh(id) }
    }

    /// Relit une application : toujours partie ? Ses restes, toujours là et
    /// toujours à elle ? Ce qui était coché et l'est encore le reste.
    public func refresh(_ id: String) async {
        guard let old = report(id), refreshing.insert(id).inserted else { return }
        defer { refreshing.remove(id) }
        let arrival = TrashArrival(url: old.app.url, fileID: old.app.fileID, date: old.trashedAt)
        guard let fresh = await evaluate(old.app, arrival: arrival, team: old.teamID) else {
            // Revenue, ou plus rien à lire : la revue le dit, la corbeille
            // d'Oust! n'en garde rien.
            reports.removeAll { $0.id == id }
            chosen[id] = nil
            if let app { app.remove(old.items.map(\.id)) }
            return
        }
        let previous = chosen[id] ?? []
        let selectable = Set(fresh.items.filter(\.isSelectable).map(\.id))
        if let index = reports.firstIndex(where: { $0.id == id }) { reports[index] = fresh }
        chosen[id] = previous.intersection(selectable)
    }

    public func items(of report: TrashedApp) -> [CleanupItem] { report.items }

    public func isChosen(_ item: CleanupItem, in report: TrashedApp) -> Bool {
        chosen[report.id]?.contains(item.id) == true
    }

    public func toggle(_ item: CleanupItem, in report: TrashedApp) {
        guard item.isSelectable else { return }
        var set = chosen[report.id] ?? []
        if set.contains(item.id) { set.remove(item.id) } else { set.insert(item.id) }
        chosen[report.id] = set
    }

    public func allChosen(_ report: TrashedApp) -> Bool {
        let selectable = report.items.filter(\.isSelectable)
        return !selectable.isEmpty && selectable.allSatisfy { isChosen($0, in: report) }
    }

    /// Tout cocher, ou tout décocher si tout l'est déjà.
    public func toggleAll(_ report: TrashedApp) {
        chosen[report.id] = allChosen(report) ? [] : Set(report.items.filter(\.isSelectable).map(\.id))
    }

    public func chosenItems(_ report: TrashedApp) -> [CleanupItem] {
        report.items.filter { $0.isSelectable && isChosen($0, in: report) }
    }

    public func chosenBytes(_ report: TrashedApp) -> Int64 {
        chosenItems(report).reduce(0) { $0 + $1.sizes.freeable }
    }

    /// Jette dans la corbeille d'Oust! ce qui est coché, puis l'ouvre : le vide
    /// se fait de là, avec sa revue et sa confirmation. Un chemin déjà dans la
    /// corbeille d'Oust! (par les restes d'applications disparues) n'y entre
    /// pas deux fois : il serait compté deux fois (RULES.md, règle 9).
    public func sendToBin(_ report: TrashedApp) {
        guard let app else { return }
        let items = chosenItems(report)
        guard !items.isEmpty else { return }
        let already = Set(app.cartItems.flatMap(\.paths).map { PathNormalizer.normalize($0.path) })
        app.add(items.filter { item in !item.paths.contains { already.contains(PathNormalizer.normalize($0.path)) } })
        dismiss(report)
        app.section = .cart
    }

    /// Ne plus en parler : les restes restent où ils sont. Ceux d'une
    /// application disparue réapparaîtront dans « Restes d'applications ».
    public func dismiss(_ report: TrashedApp) {
        reports.removeAll { $0.id == report.id }
        chosen[report.id] = nil
        app?.applications.hideTrashed(report.id)
        Task { await Notifier.remove(id: Self.notificationPrefix + (report.app.bundleID ?? report.id)) }
    }

    /// Retire ce qui a quitté le disque depuis (vidé par la corbeille d'Oust!,
    /// ou à la main).
    public func pruneMissing() {
        for index in reports.indices.reversed() {
            reports[index].leftovers.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
            if reports[index].leftovers.isEmpty {
                let id = reports[index].id
                reports.remove(at: index)
                chosen[id] = nil
            }
        }
    }

    public var totalFreeable: Int64 { reports.reduce(0) { $0 + $1.freeable } }
}
