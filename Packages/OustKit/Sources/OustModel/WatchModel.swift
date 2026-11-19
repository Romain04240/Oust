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
    public var menuBarContents: MenuBarContents {
        didSet {
            guard menuBarContents != oldValue else { return }
            defaults.set(menuBarContents.rawValue, forKey: WatchSettings.menuBarContentsKey)
            onMenuBarChange?(showsMenuBar)
        }
    }
    /// Le monogramme aux couleurs de l'icône plutôt qu'en image modèle.
    public var menuBarIconInColor: Bool {
        didSet {
            guard menuBarIconInColor != oldValue else { return }
            defaults.set(menuBarIconInColor, forKey: WatchSettings.menuBarColorKey)
            onMenuBarIconChange?()
        }
    }
    public var menuBarUsesDriveIcon: Bool {
        didSet {
            guard menuBarUsesDriveIcon != oldValue else { return }
            defaults.set(menuBarUsesDriveIcon, forKey: WatchSettings.menuBarDriveIconKey)
            onMenuBarIconChange?()
        }
    }
    @ObservationIgnored public var onMenuBarIconChange: (@MainActor () -> Void)?
    /// Montre l'alerte disque bas en capsule (l'app pose le panneau).
    @ObservationIgnored public var onLowDisk: (@MainActor (LowDiskAlert) -> Void)?
    public private(set) var battery: BatteryReading?
    @ObservationIgnored public var onBatteryAlert: (@MainActor (BatteryAlert) -> Void)?
    @ObservationIgnored private var batteryObserver: BatteryPowerObserver?
    @ObservationIgnored private var batteryAlerts = BatteryAlertTracker()
    @ObservationIgnored private var batteryAsleep = false
    @ObservationIgnored private var sleepObserver: (any NSObjectProtocol)?
    public private(set) var batteryDevices: [BatteryDevice]?
    public private(set) var batteryDevicesReadAt: ContinuousClock.Instant?
    public private(set) var batteryDevicesObservedAt: Date?
    /// Historique d’affichage. Les alertes utilisent exclusivement le relevé courant.
    public private(set) var lastKnownBatteryDevices: [BatteryDevice] = []
    public var orderedLastKnownBatteryDevices: [BatteryDevice] {
        BatteryDevicePreference.ordered(lastKnownBatteryDevices, using: batteryDevicePreferences)
    }

    public private(set) var batteryDevicePreferences: [BatteryDevicePreference] = []
    @ObservationIgnored private var bootPublishedAt: ContinuousClock.Instant?
    @ObservationIgnored private var deviceAlerts = DeviceBatteryAlertTracker()
    @ObservationIgnored private var deviceRead: Task<Void, Never>?
    @ObservationIgnored private var deviceReadCycle = 0
    @ObservationIgnored private var deviceDelivery: Task<Void, Never>?
    @ObservationIgnored private var deviceDeliveryRequested = false
    @ObservationIgnored private var deviceLoop: Task<Void, Never>?
    public private(set) var batteryAlertCycle = 0
    static let batteryDevicesKey = "watch.batteryDevices"
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
        self.menuBarUsesDriveIcon = defaults.object(forKey: WatchSettings.menuBarDriveIconKey) as? Bool
            ?? (defaults.object(forKey: WatchSettings.menuBarColorKey) == nil)
        self.menuBarContents = defaults.string(forKey: WatchSettings.menuBarContentsKey)
            .flatMap(MenuBarContents.init(rawValue:)) ?? .storage
        self.state = WatchState.decode(defaults.data(forKey: Self.stateKey))
        self.maintenance = MaintenanceModel(defaults: defaults)
        if let data = defaults.data(forKey: Self.batteryDevicesKey), let saved = try? JSONDecoder().decode([BatteryDevicePreference].self, from: data) {
            self.batteryDevicePreferences = saved
        }
        maintenance.watch = self
    }

    // MARK: - Démarrage

    /// Au lancement, fenêtre ouverte ou non : c'est la veille qui fait vivre la
    /// barre de menus et l'alerte.
    public func start() {
        guard loop == nil else { return }
        refreshLoginItem()
        refreshBattery()
        batteryObserver = BatteryPowerObserver { [weak self] in self?.refreshBattery() }
        // Les corbeilles du Mac : une application qu'on y jette, et ses restes.
        app?.trashedApps.start()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
        deviceLoop = Task { [weak self] in
            while !Task.isCancelled {
                if (self?.showsMenuBar == true && self?.menuBarContents.showsBattery == true)
                    || self?.batteryDevicePreferences.contains(where: { $0.threshold != nil }) == true {
                    await self?.refreshBatteryDevices()
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        // Au réveil, une règle a pu venir à échéance et le disque s'être rempli.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.batteryAsleep = false
                self?.batteryAlerts.resetBaseline()
                self?.batteryAlertCycle += 1
                self?.refreshBattery()
                Task { await self?.tick() }
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.batteryAsleep = true
                self?.batteryAlerts.resetBaseline()
                self?.deviceAlerts = DeviceBatteryAlertTracker()
                self?.batteryDevices = nil
                self?.batteryDevicesReadAt = nil
                self?.deviceReadCycle += 1
            }
        }
    }

    private func refreshBattery() {
        guard !batteryAsleep else { return }
        let reading = BatteryReading.current()
        if battery.map({ $0.state == .onBattery }) != reading.map({ $0.state == .onBattery }) {
            batteryAlertCycle += 1
        }
        battery = reading
        if let alert = batteryAlerts.observe(reading, settings: settings.batteryAlerts) { onBatteryAlert?(alert) }
    }

    public func currentBatteryAlert(matching alert: BatteryAlert, cycle: Int) -> BatteryAlert? {
        guard cycle == batteryAlertCycle, !batteryAsleep, let reading = battery else { return nil }
        return alert.updated(for: reading, settings: settings.batteryAlerts)
    }

    public var orderedBatteryDevices: [BatteryDevice] {
        BatteryDevicePreference.ordered(batteryDevices ?? [], using: batteryDevicePreferences)
    }

    public var shownBatteryDeviceCount: Int {
        lastKnownBatteryDevices.count { batteryPreference(for: $0.id).shown }
    }

    public func batteryPreference(for id: String) -> BatteryDevicePreference {
        batteryDevicePreferences.first { $0.id == id } ?? BatteryDevicePreference(id: id)
    }

    private func storeBatteryPreferences(_ preferences: [BatteryDevicePreference]) {
        batteryDevicePreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.batteryDevicesKey)
    }

    public func setBatteryPreference(_ preference: BatteryDevicePreference) {
        guard lastKnownBatteryDevices.contains(where: { $0.id == preference.id }) else { return }
        let previous = batteryPreference(for: preference.id)
        guard !preference.shown || previous.shown || shownBatteryDeviceCount < BatteryDevicePreference.maximumShown else { return }
        guard previous != preference else { return }
        let preferences = orderedLastKnownBatteryDevices.map { $0.id == preference.id ? preference : batteryPreference(for: $0.id) }
        let active = Set(preferences.map(\.id))
        storeBatteryPreferences(preferences + batteryDevicePreferences.filter { !active.contains($0.id) })
        if preference.threshold != previous.threshold { deviceAlerts.invalidate(preference.id) }
        if preference.threshold != nil, previous.threshold == nil {
            Task {
                notifications = await Notifier.ensurePermission()
                scheduleDeviceDelivery()
            }
        }
    }

    public func moveBatteryDevice(_ id: String, by offset: Int) {
        var preferences = orderedLastKnownBatteryDevices.map { batteryPreference(for: $0.id) }
        guard let index = preferences.firstIndex(where: { $0.id == id }),
              preferences.indices.contains(index + offset) else { return }
        preferences.swapAt(index, index + offset)
        let active = Set(preferences.map(\.id))
        storeBatteryPreferences(preferences + batteryDevicePreferences.filter { !active.contains($0.id) })
    }

    public func hasFreshBatteryDevices(since start: ContinuousClock.Instant?) -> Bool {
        guard let start, let read = batteryDevicesReadAt else { return false }
        return read >= start && ContinuousClock.now - read <= .seconds(22)
    }

    public func refreshBatteryDevices(since start: ContinuousClock.Instant? = nil, requestBluetoothPermission: Bool = false) async {
        if let running = deviceRead {
            await running.value
            if !(requestBluetoothPermission && BatteryBluetooth.needsAuthorization) {
                guard let start, !hasFreshBatteryDevices(since: start) else { return }
            }
        }
        guard !Task.isCancelled, !batteryAsleep else { return }
        if deviceRead == nil {
            deviceRead = Task { [weak self] in
                guard let self else { return }
                defer { self.deviceRead = nil }
                await self.readBatteryDevices(requestBluetoothPermission: requestBluetoothPermission)
            }
        }
        await deviceRead?.value
    }

    private func readBatteryDevices(requestBluetoothPermission: Bool) async {
        let cycle = deviceReadCycle
        let startedAt = ContinuousClock.now
        let observedAt = Date()
        let remembered = Dictionary(batteryDevicePreferences.compactMap { preference -> (String, UUID)? in
            guard let peer = preference.bluetoothPeer else { return nil }
            return (preference.id, peer)
        }, uniquingKeysWith: { first, _ in first })
        let watches = Dictionary(batteryDevicePreferences.compactMap { preference -> (String, WatchRelayBinding)? in
            guard let binding = preference.watchRelayBinding else { return nil }
            return (preference.id, binding)
        }, uniquingKeysWith: { first, _ in first })
        let fresh = await BatteryDevice.read(requestBluetoothPermission: requestBluetoothPermission, knownBluetooth: remembered, knownWatches: watches)
        guard !Task.isCancelled, cycle == deviceReadCycle, !batteryAsleep else { return }
        batteryDevices = fresh
        batteryDevicesReadAt = fresh == nil ? nil : startedAt
        if let fresh {
            let ids = Set(fresh.map(\.id))
            let absent = lastKnownBatteryDevices.filter { !ids.contains($0.id) && batteryPreference(for: $0.id).shown }
                .map { BatteryDevice(id: $0.id, name: $0.name, connected: false, level: nil) }
            lastKnownBatteryDevices = fresh + absent
            batteryDevicesObservedAt = observedAt
            var preferences = BatteryDevicePreference.reconciled(batteryDevicePreferences, devices: lastKnownBatteryDevices)
            for device in fresh {
                guard let index = preferences.firstIndex(where: { $0.id == device.id }) else { continue }
                if let peer = device.bluetoothPeerID,
                   preferences[index].bluetoothPeer == nil || preferences[index].bluetoothPeer == peer {
                    preferences[index].bluetoothPeer = peer
                }
                if let binding = device.watchRelay?.binding,
                   preferences[index].watchRelayBinding == nil || preferences[index].watchRelayBinding == binding {
                    preferences[index].watchRelayBinding = binding
                }
            }
            if preferences != batteryDevicePreferences { storeBatteryPreferences(preferences) }
        } else {
            lastKnownBatteryDevices = lastKnownBatteryDevices.map { $0.droppingWatchRelay() }
        }
        if !deviceAlerts.observe(fresh ?? [], preferences: batteryDevicePreferences).isEmpty {
            scheduleDeviceDelivery()
        }
    }

    private func scheduleDeviceDelivery() {
        deviceDeliveryRequested = true
        guard deviceDelivery == nil else { return }
        deviceDelivery = Task { [weak self] in
            guard let self else { return }
            defer { self.deviceDelivery = nil }
            repeat {
                self.deviceDeliveryRequested = false
                await self.deliverDeviceAlerts()
            } while self.deviceDeliveryRequested && !Task.isCancelled
        }
    }

    private func deliverDeviceAlerts() async {
        let cycle = deviceReadCycle
        guard await Notifier.permission() == .allowed, cycle == deviceReadCycle,
              let snapshot = batteryDevicesReadAt, ContinuousClock.now - snapshot <= .seconds(45) else { return }
        for id in (batteryDevices ?? []).map(\.id) {
            guard cycle == deviceReadCycle, snapshot == batteryDevicesReadAt,
                  let device = batteryDevices?.first(where: { $0.id == id && $0.connected && $0.watchRelay == nil }),
                  let alert = deviceAlerts.pendingAlert(for: id),
                  let level = device.level, level <= alert.threshold else { continue }
            let preference = batteryPreference(for: device.id)
            guard preference.threshold == alert.threshold else { continue }
            let name = preference.alias.isEmpty ? device.name : preference.alias
            let posted = await Notifier.post(id: "fr.meaillais.oust.battery-device.\(device.id)", title: name,
                                body: L10n.string("watch.battery_device_notification", Formatters.count(level)),
                                opening: .settings(.battery), sound: true)
            if posted, cycle == deviceReadCycle { deviceAlerts.acknowledge(id, alert: alert) }
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
        if settings.batteryAlerts != old.batteryAlerts {
            batteryAlertCycle += 1
            batteryAlerts = BatteryAlertTracker()
            refreshBattery()
        }
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
        return LowDiskAlarm.isLow(available: boot.capacity.availableForImportantUsage, total: boot.capacity.total,
                                  threshold: settings.threshold)
    }

    /// Ce que la dernière analyse a trouvé de sûr, ou `nil` sans analyse.
    public var safeTotal: Int64? {
        guard let app, app.analysis.hasRun else { return nil }
        // Le disque de démarrage seul : c'est lui que l'alerte surveille.
        return app.items.values.filter { $0.safety == .safe && app.canSelectForCleanup($0) && $0.countsInHeadline
            && app.isOnBootVolume($0) }
            .reduce(0) { $0 + $1.sizes.freeable }
    }

    /// Le même échantillon alimente la fenêtre et la barre des menus.
    @discardableResult
    func updateBoot(_ fresh: VolumeDescriptor?, measuredAt: ContinuousClock.Instant = .now) -> Bool {
        if let bootPublishedAt, measuredAt <= bootPublishedAt { return false }
        bootPublishedAt = measuredAt
        if fresh != boot { boot = fresh }
        return true
    }

    /// Relit le disque tout de suite (le panneau de la barre de menus s'ouvre).
    public func refreshDisk() async { await refreshDisk(read: VolumeService.bootVolume) }

    func refreshDisk(read: @escaping @Sendable () async -> VolumeDescriptor?) async {
        let sample = await Task.detached(priority: .utility) {
            let measuredAt = ContinuousClock.now
            return (await read(), measuredAt)
        }.value
        guard !Task.isCancelled, let fresh = sample.0 else { return }
        updateBoot(fresh, measuredAt: sample.1)
    }

    /// Le disque de démarrage et les disques branchés (`WatchedVolumes`), chacun
    /// avec son alerte : une fois par passage sous le seuil, pour chacun.
    func checkDisk() async {
        let measuredAt = ContinuousClock.now
        let fresh = VolumeService.bootVolume()
        updateBoot(fresh, measuredAt: measuredAt)
        guard settings.alertsLowDisk else { return }
        let mounts = await timeMachineMounts()
        // Hors du fil principal : un disque qui tarde à répondre ne fige rien.
        let external = await Task.detached(priority: .utility) { Self.externalVolumes(excluding: mounts) }.value
        var alerts: [LowDiskAlert] = []
        for volume in (fresh.map { [$0] } ?? []) + external {
            let id = Self.identifier(of: volume)
            var alarm = state.alarms[id] ?? LowDiskAlarm()
            let decision = alarm.observe(available: volume.capacity.availableForImportantUsage, total: volume.capacity.total,
                                         threshold: settings.threshold)
            if state.alarms[id] != alarm { state.alarms[id] = alarm }
            if decision == .alert {
                alerts.append(LowDiskAlert(volumeName: volume.name, capacity: volume.capacity, isBoot: volume.isBoot,
                                           safeTotal: safeTotal))
            }
        }
        // Une pastille à la fois : celle du disque le plus plein.
        guard let pressing = alerts.max(by: { $0.capacity.occupiedFraction < $1.capacity.occupiedFraction }) else { return }
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
    public func showAlertPreview() { showAlertPreview(read: VolumeService.bootVolume) }

    func showAlertPreview(read: () -> VolumeDescriptor?) {
        let measuredAt = ContinuousClock.now
        guard let fresh = read() else { return }
        updateBoot(fresh, measuredAt: measuredAt)
        let displayed = boot ?? fresh
        onLowDisk?(LowDiskAlert(volumeName: displayed.name, capacity: displayed.capacity, safeTotal: safeTotal))
    }

    /// L'UUID du volume, qui survit à un renommage ; à défaut, son point de montage.
    static func identifier(of volume: VolumeDescriptor) -> String {
        (try? volume.scanRoot.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? volume.mountURL.path
    }

    // MARK: - Règles planifiées

    public func lastRun(_ family: RetentionFamily) -> Date? { state.lastRun(family) }

    public func nextRun(_ family: RetentionFamily) -> Date? {
        guard app?.engine.supports(.removeNow) == true else { return nil }
        return settings.policy(family).nextRun(lastRun: state.lastRun(family))
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
        guard let app, app.engine.supports(.removeNow) else { return false }
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
        guard app.engine.supports(.removeNow) else { return [] }
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

    public var free: String { Formatters.bytes(capacity.availableForImportantUsage) }

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
