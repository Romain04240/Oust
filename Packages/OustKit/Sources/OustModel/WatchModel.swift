import AppKit
import Foundation
import Observation
import OustClean
import OustCore
import OustLocalization
import OustRules
import OustVolume
import OustWatch

/// La veille d'Oust!, fenêtre fermée : la barre de menus, l'alerte disque bas,
/// les règles planifiées (SPEC §10, phase 3).
///
/// Rien n'y part dans le dos de l'utilisateur. Les règles sont désactivées tant
/// qu'il ne les a pas cochées ; elles ne prennent que du sûr ou du régénérable,
/// supprimé par Oust! et jamais envoyé à la corbeille du Mac (`RetentionFilter`) ;
/// elles passent par `CleanupEngine`, qui revalide chaque élément juste avant
/// d'agir et l'inscrit à l'historique ; et chaque passage est raconté par une
/// notification.
@MainActor
@Observable
public final class WatchModel {
    weak var app: AppModel?

    public var settings: WatchSettings {
        didSet {
            guard settings != oldValue else { return }
            defaults.set(settings.encoded(), forKey: Self.settingsKey)
            settingsChanged(from: oldValue)
        }
    }

    /// Le disque de démarrage, relu chaque minute par `statfs` : Foundation garde
    /// sa capacité en cache dans le processus (voir `VolumeService.capacity`).
    public private(set) var boot: VolumeDescriptor?
    public private(set) var notifications: NotificationPermission = .unknown
    /// L'ouverture à la connexion, et ce que macOS a refusé s'il a refusé.
    private var loginItemState = LoginItemState()
    public var loginItem: LoginItemStatus { loginItemState.status }
    public var loginItemNotice: LoginItemNotice? { loginItemState.notice }
    /// La règle qui passe en ce moment.
    public private(set) var runningFamily: RetentionFamily?
    /// Les derniers passages, d'un lancement à l'autre.
    public private(set) var state: WatchState {
        didSet { defaults.set(state.encoded(), forKey: Self.stateKey) }
    }

    /// La barre de menus est affichée.
    public var showsMenuBar: Bool {
        didSet {
            guard showsMenuBar != oldValue else { return }
            defaults.set(showsMenuBar, forKey: WatchSettings.menuBarKey)
            onMenuBarChange?(showsMenuBar)
        }
    }
    /// Prévenu quand la barre de menus apparaît ou disparaît : l'app pose ou
    /// retire l'icône, et sans elle garde son icône dans le Dock.
    @ObservationIgnored public var onMenuBarChange: (@MainActor (Bool) -> Void)?
    /// Le monogramme aux couleurs de l'icône plutôt qu'en image modèle.
    public var menuBarIconInColor: Bool {
        didSet {
            guard menuBarIconInColor != oldValue else { return }
            defaults.set(menuBarIconInColor, forKey: WatchSettings.menuBarColorKey)
            onMenuBarIconChange?(menuBarIconInColor)
        }
    }
    @ObservationIgnored public var onMenuBarIconChange: (@MainActor (Bool) -> Void)?
    /// Montre l'alerte disque bas en capsule (l'app pose le panneau).
    @ObservationIgnored public var onLowDisk: (@MainActor (LowDiskAlert) -> Void)?
    /// L'entretien planifié : il analyse et montre, sans rien supprimer.
    public let maintenance: MaintenanceModel

    @ObservationIgnored private let defaults: UserDefaults
    /// Les destinations Time Machine, relues toutes les dix minutes au plus.
    @ObservationIgnored private var timeMachine: (mounts: Set<String>, read: Date)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    static let settingsKey = "watch.settings"
    static let stateKey = "watch.state"
    /// Une lecture de `statfs` coûte quelques microsecondes : une par minute ne
    /// se voit pas, et un disque ne se remplit pas plus vite que ça sans prévenir.
    static let interval: Duration = .seconds(60)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = WatchSettings.decode(defaults.data(forKey: Self.settingsKey))
        self.showsMenuBar = defaults.object(forKey: WatchSettings.menuBarKey) as? Bool ?? true
        self.menuBarIconInColor = defaults.bool(forKey: WatchSettings.menuBarColorKey)
        self.state = WatchState.decode(defaults.data(forKey: Self.stateKey))
        self.maintenance = MaintenanceModel(defaults: defaults)
        maintenance.watch = self
    }

    // MARK: - Démarrage

    /// Au lancement, fenêtre ouverte ou non : c'est la veille qui fait vivre la
    /// barre de menus et l'alerte.
    public func start() {
        guard loop == nil else { return }
        refreshLoginItem()
        // Les corbeilles du Mac : une application qu'on y jette, et ses restes.
        app?.trashedApps.start()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
        // Au réveil, une règle a pu venir à échéance et le disque s'être rempli.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    func tick() async {
        await checkDisk()
        await runDuePolicies()
        await maintenance.runIfDue()
    }

    /// Relit ce que macOS seul connaît : la permission de notifier, l'ouverture
    /// à la connexion (Réglages, au moment où on les ouvre).
    public func refreshPermissions() async {
        notifications = await Notifier.permission()
        refreshLoginItem()
    }

    private func settingsChanged(from old: WatchSettings) {
        if settings.alsoNotifies, !old.alsoNotifies {
            // Cocher la notification, c'est le bon moment pour demander la
            // permission : l'utilisateur sait pourquoi on la demande.
            Task { notifications = await Notifier.ensurePermission() }
        }
        if settings.alertsLowDisk != old.alertsLowDisk || settings.threshold != old.threshold {
            Task { await checkDisk() }
        }
    }

    // MARK: - Disque bas

    /// Le seuil d'alerte du disque de démarrage, en octets.
    public var thresholdBytes: Int64? {
        boot.map { settings.threshold.bytes(total: $0.capacity.total) }
    }

    /// Le disque de démarrage est sous le seuil (la barre de menus le montre).
    public var isLow: Bool {
        guard settings.alertsLowDisk, let boot else { return false }
        return LowDiskAlarm.isLow(available: boot.capacity.available, total: boot.capacity.total,
                                  threshold: settings.threshold)
    }

    /// Ce que la dernière analyse a trouvé de sûr, ou `nil` sans analyse.
    public var safeTotal: Int64? {
        guard let app, app.analysis.hasRun else { return nil }
        // Le disque de démarrage seul : c'est lui que l'alerte surveille.
        return app.items.values.filter { $0.safety == .safe && $0.isSelectable && $0.countsInHeadline
            && app.isOnBootVolume($0) }
            .reduce(0) { $0 + $1.sizes.freeable }
    }

    /// Relit le disque tout de suite (le panneau de la barre de menus s'ouvre).
    public func refreshDisk() async { await checkDisk() }

    /// Le disque de démarrage et les disques branchés (`WatchedVolumes`), chacun
    /// avec son alerte : une fois par passage sous le seuil, pour chacun.
    func checkDisk() async {
        let fresh = VolumeService.bootVolume()
        if fresh != boot { boot = fresh }
        guard settings.alertsLowDisk else { return }
        let mounts = await timeMachineMounts()
        // Hors du fil principal : un disque qui tarde à répondre ne fige rien.
        let external = await Task.detached(priority: .utility) { Self.externalVolumes(excluding: mounts) }.value
        var alerts: [LowDiskAlert] = []
        for volume in (fresh.map { [$0] } ?? []) + external {
            let id = Self.identifier(of: volume)
            var alarm = state.alarms[id] ?? LowDiskAlarm()
            let decision = alarm.observe(available: volume.capacity.available, total: volume.capacity.total,
                                         threshold: settings.threshold)
            if state.alarms[id] != alarm { state.alarms[id] = alarm }
            if decision == .alert {
                alerts.append(LowDiskAlert(volumeName: volume.name, capacity: volume.capacity, isBoot: volume.isBoot,
                                           safeTotal: safeTotal))
            }
        }
        // Une pastille à la fois : celle du disque le plus plein.
        guard let pressing = alerts.max(by: { $0.capacity.usedFraction < $1.capacity.usedFraction }) else { return }
        onLowDisk?(pressing)
        guard settings.alsoNotifies else { return }
        notifications = await Notifier.ensurePermission()
        guard notifications == .allowed else { return }
        for alert in alerts {
            await Notifier.post(id: "fr.meaillais.oust.low-disk.\(alert.volumeName)", title: alert.title,
                                body: alert.message, opening: .overview, sound: alert == pressing)
        }
    }

    /// Les disques branchés à surveiller, avec leur capacité (`statfs`).
    nonisolated static func externalVolumes(excluding timeMachine: Set<String>) -> [VolumeDescriptor] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey,
            .volumeIsRootFileSystemKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let candidate = WatchedVolumes.Candidate(
                path: url.path, isLocal: values.volumeIsLocal ?? false, isBrowsable: values.volumeIsBrowsable ?? false,
                isReadOnly: values.volumeIsReadOnly ?? true, isRootFileSystem: values.volumeIsRootFileSystem ?? false)
            guard WatchedVolumes.accepts(candidate, timeMachine: timeMachine),
                  let capacity = VolumeService.capacity(of: url) else { return nil }
            return VolumeDescriptor(name: values.volumeLocalizedName ?? url.lastPathComponent, mountURL: url,
                                    scanRoot: url, isBoot: false, isInternal: values.volumeIsInternal ?? false,
                                    isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false),
                                    capacity: capacity)
        }
    }

    /// `tmutil destinationinfo -X`, gardé dix minutes : la liste ne change
    /// qu'au branchement d'un disque de sauvegarde.
    private func timeMachineMounts() async -> Set<String> {
        if let timeMachine, Date().timeIntervalSince(timeMachine.read) < 600 { return timeMachine.mounts }
        let result = await Command.run("/usr/bin/tmutil", ["destinationinfo", "-X"], timeout: 10)
        let mounts = result.succeeded ? WatchedVolumes.timeMachineMountPoints(in: result.stdout) : []
        timeMachine = (mounts, Date())
        return mounts
    }

    /// La pastille telle qu'elle apparaîtrait maintenant (Réglages, « Essayer »),
    /// avec les chiffres du disque relus à l'instant. Ne touche ni au seuil ni à
    /// l'état de l'alerte : un essai ne compte pas comme « déjà prévenu ».
    public func showAlertPreview() {
        guard let fresh = VolumeService.bootVolume() else { return }
        if fresh != boot { boot = fresh }
        onLowDisk?(LowDiskAlert(volumeName: fresh.name, capacity: fresh.capacity, safeTotal: safeTotal))
    }

    /// L'UUID du volume, qui survit à un renommage ; à défaut, son point de montage.
    static func identifier(of volume: VolumeDescriptor) -> String {
        (try? volume.scanRoot.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? volume.mountURL.path
    }

    // MARK: - Règles planifiées

    public func lastRun(_ family: RetentionFamily) -> Date? { state.lastRun(family) }

    public func nextRun(_ family: RetentionFamily) -> Date? {
        settings.policy(family).nextRun(lastRun: state.lastRun(family))
    }

    /// Cocher une règle : son premier passage viendra une période plus tard, et
    /// la permission de notifier est demandée maintenant, pas au milieu d'un passage.
    public func setEnabled(_ enabled: Bool, for family: RetentionFamily) {
        settings.update(family) { policy in
            policy.isEnabled = enabled
            policy.enabledSince = enabled ? Date() : nil
        }
        if enabled { Task { notifications = await Notifier.ensurePermission() } }
    }

    public func update(_ family: RetentionFamily, _ change: (inout RetentionPolicy) -> Void) {
        settings.update(family, change)
    }

    /// Un passage peut-il commencer : un seul à la fois, et jamais pendant que
    /// l'utilisateur analyse ou fait le vide lui-même.
    public var canRun: Bool {
        guard let app else { return false }
        return runningFamily == nil && app.cleaning != .running && !app.analysis.isRunning && !maintenance.isRunning
    }

    /// Ce qu'un passage prendrait maintenant, sans rien toucher.
    public func preview(_ family: RetentionFamily) async -> [CleanupItem] {
        guard let app else { return [] }
        return await candidates(for: settings.policy(family), app: app)
    }

    /// Faire le vide maintenant, sur ce que l'aperçu a montré : le filtre repasse,
    /// puis la revalidation, comme pour un passage planifié.
    public func runNow(_ family: RetentionFamily, items: [CleanupItem]) async {
        await run(settings.policy(family), items: items)
    }

    func runDuePolicies() async {
        let now = Date()
        for policy in settings.policies where policy.isDue(now: now, lastRun: state.lastRun(policy.family)) {
            guard canRun else { return }
            await run(policy, items: nil)
        }
    }

    private func candidates(for policy: RetentionPolicy, app: AppModel) async -> [CleanupItem] {
        let preferences = app.preferences
        let context = RuleContext(home: app.home, projectRoots: preferences.projectRoots,
                                  historyRetentionDays: preferences.historyRetentionDays,
                                  compressionAgeDays: preferences.compressionAgeMonths * 30)
        // Mesurés sur le disque, pas d'après l'arbre partagé : l'âge doit être
        // celui d'aujourd'hui, et la fenêtre n'est peut-être jamais venue le charger.
        let found = await RuleEngine.collect(context, finders: policy.family.finders, measurer: .disk)
        return RetentionFilter.eligible(found, policy: policy, recencyDays: preferences.recencyDays)
    }

    private func run(_ policy: RetentionPolicy, items preset: [CleanupItem]?) async {
        guard let app, canRun else { return }
        runningFamily = policy.family
        defer { runningFamily = nil }
        let items: [CleanupItem]
        if let preset {
            items = RetentionFilter.eligible(preset, policy: policy, recencyDays: app.preferences.recencyDays)
        } else {
            items = await candidates(for: policy, app: app)
        }
        state.lastRuns[policy.family.rawValue] = Date()
        guard !items.isEmpty else { return }

        var report: CleanupReport?
        for await event in app.engine.run(items) {
            if case .finished(let finished) = event { report = finished }
        }
        guard let report else { return }
        await app.retentionFinished(report)
        let permission = await Notifier.ensurePermission()
        notifications = permission
        guard permission == .allowed, let message = Self.runMessage(report, family: policy.family) else { return }
        await Notifier.post(id: "fr.meaillais.oust.retention.\(policy.family.rawValue)", title: message.title,
                            body: message.body, opening: .history, sound: false)
    }

    /// Ce que la notification raconte d'un passage : ce qui est parti, et ce
    /// qui est resté parce qu'il avait changé ou servait.
    static func runMessage(_ report: CleanupReport, family: RetentionFamily) -> (title: String, body: String)? {
        let gone = report.outcomes.filter(\.result.succeeded)
        let kept = report.outcomes.count - gone.count
        guard !report.outcomes.isEmpty else { return nil }
        let familyName = L10n.string(family.localizationKey)
        var body: String
        if gone.isEmpty {
            body = L10n.string("watch.run.nothing", familyName)
        } else {
            var names: [String] = []
            for title in gone.map(\.title) where !names.contains(title) { names.append(title) }
            var list = names.prefix(3).joined(separator: ", ")
            if names.count > 3 { list = L10n.string("watch.run.more", list, Formatters.count(names.count - 3)) }
            let bytes = gone.reduce(Int64(0)) { $0 + $1.bytes }
            body = L10n.string("watch.run.body", familyName, Formatters.bytes(bytes), list)
        }
        if kept == 1 {
            body += " " + L10n.string("watch.run.kept_one")
        } else if kept > 1 {
            body += " " + L10n.string("watch.run.kept_other", Formatters.count(kept))
        }
        let title = L10n.string(gone.isEmpty ? "watch.run.title_kept" : "watch.run.title")
        return (title, body)
    }

    // MARK: - Ouverture à la connexion

    public func refreshLoginItem() {
        loginItemState.refreshed(LoginItem.status)
    }

    public func setOpensAtLogin(_ enabled: Bool) {
        var failure: (any Error)?
        do {
            try LoginItem.set(enabled)
        } catch {
            failure = error
        }
        loginItemState.requested(enabled, error: failure, status: LoginItem.status)
    }

    public func openLoginItemsSettings() { LoginItem.openSystemSettings() }

    public func openNotificationSettings() { Notifier.openSettings() }
}

/// Ce que l'alerte disque bas a à dire, en capsule comme en notification.
public struct LowDiskAlert: Sendable, Equatable {
    public var volumeName: String
    public var capacity: Capacity
    /// Le disque de démarrage, ou un disque branché.
    public var isBoot: Bool
    /// Ce que la dernière analyse a trouvé de sûr, ou `nil` sans analyse.
    /// L'analyse ne porte que sur le disque de démarrage.
    public var safeTotal: Int64?

    public init(volumeName: String, capacity: Capacity, isBoot: Bool = true, safeTotal: Int64?) {
        self.volumeName = volumeName
        self.capacity = capacity
        self.isBoot = isBoot
        self.safeTotal = isBoot ? safeTotal : nil
    }

    public var free: String { Formatters.bytes(capacity.available) }

    public var title: String {
        isBoot ? L10n.string("watch.alert.title") : L10n.string("watch.alert.title_volume", volumeName)
    }

    /// Ce qu'Oust! peut rendre en sûr, si une analyse le sait ; sinon, l'inviter.
    public var advice: String {
        switch safeTotal {
        case .none: L10n.string("watch.alert.analyze")
        case .some(0): L10n.string("watch.alert.nothing_safe")
        case .some(let bytes): L10n.string("watch.alert.safe", Formatters.bytes(bytes))
        }
    }

    public var message: String { L10n.string("watch.alert.body", free, volumeName) + " " + advice }
}
