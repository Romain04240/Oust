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
    @ObservationIgnored public var onPowerAlert: (@MainActor (String, BatteryAlert, @escaping @MainActor () -> BatteryAlert?, @escaping @MainActor () -> PreparedWatchAlert<BatteryAlert>?) -> Void)?
    @ObservationIgnored private var powerConfirmation: Task<Void, Never>?
    @ObservationIgnored private var powerLoop: Task<Void, Never>?
    @ObservationIgnored private var powerEpisodes = PowerAlertEpisodes()
    @ObservationIgnored private var alertLedger = AlertDeliveryLedger()
    @ObservationIgnored public var onDiskAlert: (@MainActor (String, LowDiskAlert, @escaping @MainActor () async -> LowDiskAlert?, @escaping @MainActor () -> PreparedWatchAlert<LowDiskAlert>?) -> Void)?
    @ObservationIgnored private var diskEpisodes: [String: String] = [:]
    @ObservationIgnored private var diskGeneration = 0
    @ObservationIgnored private var storageWakeCycle = 0
    @ObservationIgnored private var failedPowerIntents = FailedPowerIntents()
    @ObservationIgnored private var sourceOccurrence = UUID()
    @ObservationIgnored private var hasPowerContinuitySample = false
    @ObservationIgnored private var queuedPower: Set<String> = []
    @ObservationIgnored private var notificationJobs: [@MainActor () async -> Void] = []
    @ObservationIgnored private var notificationWorker: Task<Void, Never>?
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
    @ObservationIgnored private var bootCapacityPublishedAt: ContinuousClock.Instant?
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

    typealias PowerPost = @MainActor (String, String, String, Bool, String, Date) async -> Bool
    @ObservationIgnored private let readPower: @MainActor () -> BatteryReading?
    @ObservationIgnored private let powerPermission: @MainActor () async -> Bool
    @ObservationIgnored private let powerPost: PowerPost
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

    init(defaults: UserDefaults = .standard,
         powerRead: (@MainActor () -> BatteryReading?)? = nil,
         powerPermission: (@MainActor () async -> Bool)? = nil,
         powerPost: PowerPost? = nil) {
        self.readPower = powerRead ?? { BatteryReading.current() }
        self.powerPermission = powerPermission ?? { await Notifier.permission() == .allowed }
        self.powerPost = powerPost ?? { id, title, body, sound, file, time in
            await Notifier.post(id: id, title: title, body: body, opening: .settings(.battery),
                                sound: sound, originalSound: file, observedAt: time)
        }
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
        if let data = defaults.data(forKey: "watch.powerEpisodes"), let saved = try? JSONDecoder().decode(PowerAlertEpisodes.self, from: data) { powerEpisodes = saved }
        if let data = defaults.data(forKey: "watch.alertLedger"), let saved = try? JSONDecoder().decode(AlertDeliveryLedger.self, from: data) { alertLedger = saved }
        alertLedger.retryFailures()
        diskEpisodes = defaults.dictionary(forKey: "watch.diskEpisodes") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: "watch.failedPowerIntents"), let saved = try? JSONDecoder().decode(FailedPowerIntents.self, from: data) { failedPowerIntents = saved }
        maintenance.watch = self
    }

    // MARK: - Démarrage

    /// Au lancement, fenêtre ouverte ou non : c'est la veille qui fait vivre la
    /// barre de menus et l'alerte.
    public func start() {
        guard loop == nil else { return }
        refreshLoginItem()
        refreshBattery()
        powerLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.refreshBattery()
            }
        }
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
                self?.sourceOccurrence = UUID()
                self?.storageWakeCycle += 1
                self?.batteryAsleep = false
                self?.batteryAlerts.resetBaseline()
                self?.powerEpisodes.baseline()
                self?.powerConfirmation?.cancel()
                self?.batteryAlertCycle += 1
                self?.refreshBattery()
                Task { await self?.tick() }
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sourceOccurrence = UUID()
                self?.storageWakeCycle += 1
                self?.batteryAsleep = true
                self?.batteryAlerts.resetBaseline()
                self?.powerEpisodes.baseline()
                self?.powerConfirmation?.cancel()
                self?.deviceAlerts = DeviceBatteryAlertTracker()
                self?.batteryDevices = nil
                self?.batteryDevicesReadAt = nil
                self?.deviceReadCycle += 1
            }
        }
    }

    /// Toute lecture fraîche publie sa continuité, même si son appelant va
    /// abandonner un contrôle. Le premier relevé est une baseline silencieuse.
    private func samplePower() -> BatteryReading? {
        let reading = readPower()
        let changed = hasPowerContinuitySample && battery.map({ $0.state == .onBattery }) != reading.map({ $0.state == .onBattery })
        hasPowerContinuitySample = true
        if battery != reading { battery = reading }
        if changed {
            batteryAlertCycle += 1
            sourceOccurrence = UUID()
            powerConfirmation?.cancel()
            queuedPower = queuedPower.filter { $0.hasPrefix("os:") }
        }
        if reading == nil {
            powerConfirmation?.cancel()
            powerEpisodes.baseline()
        } else if changed, !batteryAsleep, let reading {
            schedulePowerConfirmation(reading)
        }
        return reading
    }

    private func refreshBattery() {
        guard !batteryAsleep else { return }
        guard let reading = samplePower() else { return }
        queuedPower = queuedPower.filter { $0.hasPrefix("os:") }
        schedulePowerConfirmation(reading)
    }

    private func schedulePowerConfirmation(_ reading: BatteryReading) {
        powerConfirmation?.cancel()
        let cycle = batteryAlertCycle
        powerConfirmation = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !self.batteryAsleep else { return }
            let fresh = self.samplePower()
            // samplePower peut invalider notre occurrence ET armer sa remplaçante.
            guard !Task.isCancelled, cycle == self.batteryAlertCycle, let fresh else { return }
            guard fresh.state == reading.state else {
                self.schedulePowerConfirmation(fresh)
                return
            }
            let alerts = self.powerEpisodes.observe(fresh, settings: self.settings.batteryAlerts)
            self.saveAlertState()
            self.deliverPowerComponents(PowerAlertComponent.split(alerts), cycle: cycle)
        }
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
        let fresh = await Notifier.permission()
        if fresh != notifications { alertLedger.retryFailures(); saveAlertState(); refreshBattery(); retryFailedPowerAlerts() }
        notifications = fresh
        refreshLoginItem()
    }

    private func settingsChanged(from old: WatchSettings) {
        alertLedger.retryFailures()
        saveAlertState()
        if settings.batteryAlerts != old.batteryAlerts {
            batteryAlertCycle += 1
            powerConfirmation?.cancel()
            queuedPower.removeAll()
            refreshBattery()
        }
        if (settings.alsoNotifies && !old.alsoNotifies) || (settings.batteryAlerts.notifies && !old.batteryAlerts.notifies) {
            // Cocher la notification, c'est le bon moment pour demander la
            // permission : l'utilisateur sait pourquoi on la demande.
            Task { notifications = await Notifier.ensurePermission() }
        }
        retryFailedPowerAlerts()
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
        var accepted = fresh
        if var fresh, let previous = boot, sameBootTarget(previous, fresh),
           let capacityDate = bootCapacityPublishedAt, capacityDate > measuredAt {
            fresh.capacity = previous.capacity
            accepted = fresh
        } else { bootCapacityPublishedAt = measuredAt }
        if accepted != boot { boot = accepted }
        // All full reads, including monitor failures, publish qualification here.
        app?.startupQualificationChanged(accepted)
        return true
    }

    private func sameBootTarget(_ lhs: VolumeDescriptor, _ rhs: VolumeDescriptor) -> Bool {
        lhs.id == rhs.id && lhs.scanRoot == rhs.scanRoot && lhs.mountIdentity == rhs.mountIdentity
            && lhs.isBoot == rhs.isBoot && lhs.isInternal == rhs.isInternal && lhs.isRemovable == rhs.isRemovable
    }

    @discardableResult
    func updateBootCapacity(_ capacity: Capacity, for target: VolumeDescriptor,
                            measuredAt: ContinuousClock.Instant) -> Bool {
        guard var current = boot, sameBootTarget(current, target),
              bootPublishedAt.map({ measuredAt > $0 }) != false,
              bootCapacityPublishedAt.map({ measuredAt > $0 }) != false else { return false }
        current.capacity = capacity
        bootCapacityPublishedAt = measuredAt
        boot = current
        return true
    }

    /// Relit le disque tout de suite (le panneau de la barre de menus s'ouvre).
    public func refreshDisk() async { await refreshDisk(read: VolumeService.bootVolume) }

    enum DiskRefreshResult { case published, unavailable, superseded }

    @discardableResult
    func refreshDisk(read: @escaping @Sendable () async -> VolumeDescriptor?) async -> DiskRefreshResult {
        let sample = await Task.detached(priority: .utility) {
            let measuredAt = ContinuousClock.now
            return (await read(), measuredAt)
        }.value
        guard !Task.isCancelled, updateBoot(sample.0, measuredAt: sample.1) else { return .superseded }
        return sample.0 == nil ? .unavailable : .published
    }

    /// Le disque de démarrage et les disques branchés (`WatchedVolumes`), chacun
    /// avec son alerte : une fois par passage sous le seuil, pour chacun.
    func checkDisk(read: @escaping @Sendable () async -> [VolumeDescriptor] = VolumeService.alertVolumes, excluding: Set<String>? = nil) async {
        queuedPower = queuedPower.filter { $0.hasPrefix("os:") }
        diskGeneration += 1
        let generation = diskGeneration
        let cycle = storageWakeCycle
        let mounts: Set<String>
        if let excluding { mounts = excluding } else { mounts = await timeMachineMounts() }
        let measuredAt = ContinuousClock.now
        let samples = await read()
        guard generation == diskGeneration, cycle == storageWakeCycle, !Task.isCancelled, !batteryAsleep else { return }
        guard updateBoot(samples.first(where: \.isBoot), measuredAt: measuredAt) else { return }
        guard settings.alertsLowDisk else { return }
        let candidates = samples.filter {
            $0.isBoot || (!$0.isInternal && $0.mountedReadOnly == false && !mounts.contains($0.mountURL.path))
        }.sorted { $0.capacity.occupiedFraction > $1.capacity.occupiedFraction }
        var sounded = false
        for volume in candidates {
            guard let snapshot = await VolumeService.readAlertSnapshot(volume),
                  generation == diskGeneration, cycle == storageWakeCycle, !Task.isCancelled, !batteryAsleep else { continue }
            let key = snapshot.uuid
            let prior = state.alarms[key]
            var alarm = prior ?? LowDiskAlarm()
            let decision = alarm.observe(available: snapshot.volume.capacity.availableForImportantUsage,
                                         total: snapshot.volume.capacity.total, threshold: settings.threshold)
            if !alarm.hasFired {
                diskEpisodes[key] = nil
                defaults.set(diskEpisodes, forKey: "watch.diskEpisodes")
                state.alarms[key] = alarm
                continue
            }
            if diskEpisodes[key] == nil {
                diskEpisodes[key] = UUID().uuidString
                if prior?.hasFired == true, let id = diskEpisodes[key] {
                    // L'ancien accusé ne prouve pas la présentation : migration prudente.
                    _ = alertLedger.reserve(id, channel: .capsule)
                    if settings.alsoNotifies { _ = alertLedger.reserve(id, channel: .notification) }
                }
            }
            guard decision == .alert || prior?.hasFired == true, let id = diskEpisodes[key] else { continue }
            state.alarms[key] = alarm
            defaults.set(diskEpisodes, forKey: "watch.diskEpisodes")
            saveAlertState()
            var preparedDisk: LowDiskAlert?
            let current: @MainActor () async -> LowDiskAlert? = { [weak self] in
                guard let self, self.settings.alertsLowDisk, !self.batteryAsleep,
                      let fresh = await VolumeService.readAlertSnapshot(snapshot.volume), fresh.uuid == key,
                      !Task.isCancelled, generation == self.diskGeneration, cycle == self.storageWakeCycle,
                      self.settings.alertsLowDisk, !self.batteryAsleep,
                      LowDiskAlarm.isLow(available: fresh.volume.capacity.availableForImportantUsage,
                                         total: fresh.volume.capacity.total, threshold: self.settings.threshold),
                      self.diskEpisodes[key] == id else { return nil }
                let alert = LowDiskAlert(volumeName: fresh.volume.name, capacity: fresh.volume.capacity,
                                         isBoot: fresh.volume.isBoot, safeTotal: nil)
                preparedDisk = alert
                return alert
            }
            guard let alert = await current() else { continue }
            if !alertLedger.contains(id, channel: .capsule), queuedPower.insert("disk:" + id).inserted {
                if let onDiskAlert {
                    onDiskAlert(id, alert, current, { [weak self] in
                        guard let self, let value = preparedDisk else { return nil }
                        return PreparedWatchAlert(value: value) { [weak self] in
                            guard let self, generation == self.diskGeneration, cycle == self.storageWakeCycle,
                                  !self.batteryAsleep, self.settings.alertsLowDisk,
                                  self.alertLedger.reserve(id, channel: .capsule) else { return false }
                            self.queuedPower.remove("disk:" + id); self.saveAlertState()
                            return true
                        }
                    })
                } else { queuedPower.remove("disk:" + id) }
            }
            guard settings.alsoNotifies, alertLedger.canAttempt(id, channel: .notification),
                  queuedPower.insert("os:" + id).inserted else { continue }
            let sound = !sounded
            sounded = true
            enqueueNotification { [weak self] in
                guard let self else { return }
                defer { self.queuedPower.remove("os:" + id) }
                let requestID = "fr.meaillais.oust.disk." + id
                await AlertNotificationGate.send(
                    permission: { await Notifier.permission() == .allowed },
                    enabled: { self.settings.alsoNotifies && self.settings.alertsLowDisk },
                    current: current,
                    reserve: { _ in
                        guard self.alertLedger.canAttempt(id, channel: .notification),
                              self.alertLedger.reserve(id, channel: .notification) else { return false }
                        self.saveAlertState(); return true
                    },
                    post: { fresh in
                        await Notifier.post(id: requestID, title: fresh.title, body: fresh.message,
                            opening: .section(.overview), sound: sound && self.settings.playsAlertSounds,
                            originalSound: "oust-warning-v1.wav", observedAt: Date())
                    },
                    complete: { accepted in
                        self.alertLedger.completed(id, channel: .notification, accepted: accepted)
                        self.saveAlertState()
                    },
                    withdraw: { await Notifier.removeAlert(id: requestID) })
            }
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
        let sample = read()
        guard updateBoot(sample, measuredAt: measuredAt), let fresh = sample else { return }
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

    private func saveAlertState() {
        defaults.set(try? JSONEncoder().encode(powerEpisodes), forKey: "watch.powerEpisodes")
        defaults.set(try? JSONEncoder().encode(alertLedger), forKey: "watch.alertLedger")
        defaults.set(try? JSONEncoder().encode(failedPowerIntents), forKey: "watch.failedPowerIntents")
    }

    private func enqueueNotification(_ job: @escaping @MainActor () async -> Void) {
        notificationJobs.append(job)
        guard notificationWorker == nil else { return }
        notificationWorker = Task { [weak self] in
            guard let self else { return }
            defer { self.notificationWorker = nil }
            while !self.notificationJobs.isEmpty { await self.notificationJobs.removeFirst()() }
        }
    }

    func retryFailedPowerAlerts() {
        let pending = failedPowerIntents.pending(now: .now, occurrence: sourceOccurrence)
        saveAlertState()
        for entry in pending {
            guard let deadline = entry.deadline else { continue }
            deliverPowerComponents(entry.components, cycle: batteryAlertCycle, observedAt: entry.observedAt, deadline: deadline)
        }
    }

    func deliverPowerComponents(_ components: [PowerAlertComponent], cycle: Int, observedAt: Date = Date(), deadline: ContinuousClock.Instant? = nil) {
        let deadline = deadline ?? ContinuousClock.now.advanced(by: .seconds(15))
        guard !components.isEmpty, ContinuousClock.now < deadline else { return }
        let occurrence = sourceOccurrence
        let validate: @MainActor ([PowerAlertComponent]) -> [PowerAlertComponent] = { [weak self] input in
            guard let self, !self.batteryAsleep else { return [] }
            let reading = self.samplePower()
            guard cycle == self.batteryAlertCycle, occurrence == self.sourceOccurrence,
                  let reading else { return [] }
            return input.compactMap { component in
                if case .low = component.alert {
                    guard self.powerEpisodes.lowID == component.id else { return nil }
                } else if ContinuousClock.now >= deadline { return nil }
                return component.alert.updated(for: reading, settings: self.settings.batteryAlerts)
                    .map { PowerAlertComponent(id: component.id, alert: $0) }
            }
        }
        let queueID = components.map(\.id).joined(separator: ":")
        var presentedComponents: [PowerAlertComponent]?
        let capsuleCurrent: @MainActor () -> BatteryAlert? = { [weak self] in
            guard let self else { return nil }
            let input = presentedComponents ?? components.filter { !self.alertLedger.contains($0.id, channel: .capsule) }
            return PowerAlertComponent.message(validate(input))
        }
        if let alert = capsuleCurrent(), queuedPower.insert(queueID).inserted, let onPowerAlert {
            onPowerAlert(queueID, alert, capsuleCurrent, { [weak self] in
                guard let self else { return nil }
                let delivered = validate(components.filter { !self.alertLedger.contains($0.id, channel: .capsule) })
                guard let message = PowerAlertComponent.message(delivered) else { return nil }
                return PreparedWatchAlert(value: message) { [weak self] in
                    guard let self, !self.batteryAsleep, cycle == self.batteryAlertCycle,
                          occurrence == self.sourceOccurrence,
                          delivered.allSatisfy({ !self.alertLedger.contains($0.id, channel: .capsule) }) else { return false }
                    presentedComponents = delivered
                    for c in delivered { _ = self.alertLedger.reserve(c.id, channel: .capsule) }
                    self.queuedPower.remove(queueID); self.saveAlertState()
                    return true
                }
            })
        }
        guard settings.batteryAlerts.notifies, components.contains(where: { alertLedger.canAttempt($0.id, channel: .notification) }),
              queuedPower.insert("os:" + queueID).inserted else { return }
        enqueueNotification { [weak self] in
            guard let self else { return }
            defer { self.queuedPower.remove("os:" + queueID) }
            var sending: [PowerAlertComponent] = []
            let requestID = "fr.meaillais.oust.power." + UUID().uuidString
            await AlertNotificationGate.send(
                permission: { await self.powerPermission() },
                enabled: { self.settings.batteryAlerts.notifies },
                current: { () async -> BatteryAlert? in
                    sending = validate(components.filter { self.alertLedger.canAttempt($0.id, channel: .notification) })
                    return PowerAlertComponent.message(sending)
                },
                reserve: { _ in
                    guard !sending.isEmpty, sending.allSatisfy({ self.alertLedger.canAttempt($0.id, channel: .notification) }) else { return false }
                    for c in sending { _ = self.alertLedger.reserve(c.id, channel: .notification) }
                    self.saveAlertState(); return true
                },
                post: { valid in
                    let title: String
                    let sound: String
                    switch valid {
                    case .connected: title = L10n.string("watch.power.connected"); sound = "oust-connect-v1.wav"
                    case .disconnected: title = L10n.string("watch.power.disconnected"); sound = "oust-disconnect-v1.wav"
                    case .disconnectedLow: title = L10n.string("watch.power.disconnected_low"); sound = "oust-warning-v1.wav"
                    case .low: title = L10n.string("watch.battery_capsule.low"); sound = "oust-warning-v1.wav"
                    case .charged: title = L10n.string("watch.battery_capsule.charged"); sound = "oust-charged-v1.wav"
                    }
                    return await self.powerPost(requestID, title,
                        L10n.string("menubar.battery_percent", Formatters.count(valid.reading.level)),
                        self.settings.playsAlertSounds, sound, Date())
                },
                complete: { accepted in
                    for c in sending { self.alertLedger.completed(c.id, channel: .notification, accepted: accepted) }
                    if accepted { self.failedPowerIntents.remove(queueID) }
                    else { self.failedPowerIntents.record(id: queueID, components: sending, observedAt: observedAt, occurrence: occurrence, deadline: deadline) }
                    self.saveAlertState()
                },
                withdraw: { await Notifier.removeAlert(id: requestID) })
        }
    }

    func waitForAlertDelivery() async { await notificationWorker?.value }

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
