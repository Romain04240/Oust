import AppKit
import Foundation
import Observation
import OustBrowsers
import OustClean
import OustCore
import OustDuplicates
import OustLocalization
import OustRules
import OustSafety
import OustScan
import OustVolume

/// L'état de l'application : ce qui a été trouvé, ce qui est dans le panier,
/// ce qui part en ce moment.
@MainActor
@Observable
public final class AppModel {

    public enum Phase: Equatable, Sendable {
        case idle
        case running
        case done(Date)

        public var isRunning: Bool { self == .running }
        public var hasRun: Bool { if case .done = self { return true } else { return false } }
    }

    public enum Cleaning: Equatable, Sendable {
        case idle
        case running
        case finished(CleanupReport)
    }

    // MARK: Environnement

    public let home: URL
    private var storedPreferences: Preferences
    public var preferences: Preferences {
        get { storedPreferences }
        set {
            var updated = newValue
            updated.duplicateExclusions = storedPreferences.duplicateExclusions
            storedPreferences = updated
            updated.save(defaults: defaults)
        }
    }
    private let defaults: UserDefaults

    func persistDuplicateExclusions(_ exclusions: DuplicateExclusions) {
        storedPreferences.duplicateExclusions = exclusions
        storedPreferences.save(defaults: defaults)
    }

    // Partagés avec les sections de la phase 2 : un seul journal, un seul
    // moteur, pour que deux écritures ne se croisent jamais dans le fichier.
    let history: HistoryStore
    let engine: CleanupEngine

    // MARK: Navigation

    public var section: AppSection = .overview {
        didSet { if section != oldValue { guidedReviewNavigationChanged() } }
    }
    public internal(set) var guidedReview: GuidedReviewSession?
    /// L'onglet de la fenêtre Réglages : le dernier ouvert, ou celui où mène un lien.
    public var settingsTab: SettingsTab = .general

    // MARK: Recherche et filtres

    /// La recherche globale : nom, chemin, propriétaire, sur tout ce qui a été trouvé.
    public var searchText = "" {
        didSet { if isSearching { pauseGuidedReviewForNavigation() } }
    }
    /// Les filtres de chaque section, oubliés à la fermeture : un filtre resté
    /// posé d'une fois sur l'autre cacherait des éléments sans qu'on s'en souvienne.
    public var filters: [AppSection: ItemFilter] = [:]

    // MARK: Volumes

    public internal(set) var volumes: [VolumeDescriptor] = [] {
        didSet {
            invalidateReplacedVolumeAnalyses()
            invalidateStaleGuidedReview()
        }
    }
    @ObservationIgnored private var volumeRead: Task<Bool, Never>?
    @ObservationIgnored private var volumeRevision = 0
    @ObservationIgnored private(set) var mountGeneration = 0
    @ObservationIgnored var timeMachineReadSequence = 0
    @ObservationIgnored var timeMachineRetry: Task<Void, Never>?
    public private(set) var snapshots: [LocalSnapshot] = []
    public private(set) var snapshotReadFailed = false
    public private(set) var snapshotSizing = false
    public private(set) var snapshotRetainedBytes: Int64?
    private var snapshotMeasuredIDs: Set<String> = []
    public private(set) var snapshotsRefreshing = false
    private var snapshotsRevision = 0
    @ObservationIgnored var snapshotSizeTask: Task<Void, Never>?
    /// Un disque qu'on vient de brancher, à proposer à l'analyse.
    public var offeredVolume: VolumeDescriptor?
    public var bootVolume: VolumeDescriptor? { watch.boot ?? volumes.first(where: \.isBoot) }

    // MARK: Analyse par règles

    public internal(set) var analysis: Phase = .idle {
        didSet {
            invalidateStaleGuidedReview()
            if oldValue.isRunning && !analysis.isRunning { drainOverviewAnalysisRequest() }
        }
    }
    public internal(set) var items: [String: CleanupItem] = [:]
    @ObservationIgnored private var analysisLocations: [String: AnalyzedItemLocation] = [:]
    @ObservationIgnored private var backupAnalysisTokens: [String: UUID] = [:]
    @ObservationIgnored private var readOnlyRevalidationTask: Task<Void, Never>?
    public internal(set) var finishedFinders: Set<FinderKind> = []

    // MARK: Explorateur

    public internal(set) var explorer: Phase = .idle
    public internal(set) var tree: TreeNode? {
        didSet { if oldValue !== tree { largeFiles.invalidateResult() } }
    }
    public internal(set) var treeVolume: VolumeDescriptor? {
        didSet { guidedReviewExplorerChanged() }
    }
    @ObservationIgnored var displayedExplorerIndex: ScanIndex?
    @ObservationIgnored var explorerGainCheck: (root: TreeNode, work: Task<ScanIndex, Never>)?
    public internal(set) var scanProgress = ScanProgress()
    var scanTask: Task<Void, Never>?
    @ObservationIgnored var volumeAnalysisAttempt: UUID?
    /// L'analyse gardée de chaque autre disque, par son point de montage : relue
    /// du disque à la première demande, et non refaite à chaque ouverture
    /// (Romain, 18/10/2026).
    public internal(set) var volumeIndexes: [String: ScanIndex] = [:]

    // MARK: Disque analysé

    /// Le disque que la vue d'ensemble analyse, choisi en haut de celle-ci
    /// (demande de Romain, 18/10/2026) ; `nil` : le disque de démarrage.
    public internal(set) var analysisVolumeID: String? {
        didSet { invalidateStaleGuidedReview() }
    }
    @ObservationIgnored var analysisVolumeGainCheck: Task<Void, Never>?
    /// Quand chaque disque a été analysé par les règles, par son point de montage.
    public internal(set) var volumeAnalysisDates: [String: Date] = [:] {
        didSet { invalidateStaleGuidedReview() }
    }
    var startupReadUnverified = false
    var startupQualificationRevision: UInt64 = 0
    var completedVolumeAnalyses: [String: CompletedVolumeAnalysis] = [:]
    var analysisReviews: [String: AnalysisReview] = [:]
    /// Le disque dont l'analyse par règles tourne en ce moment.
    public internal(set) var analyzingVolumeID: String?
    /// Les destinations Time Machine branchées : jamais proposées à l'analyse.
    public internal(set) var timeMachineMounts: Set<String> = []
    var confirmedOrdinaryMounts: [String: VolumeMountIdentity] = [:]
    var pendingTimeMachineMounts: Set<String> = []
    var unresolvedMounts: Set<String> = []
    /// Les disques dont l'arbre a été fait depuis leur branchement : FSEvents
    /// dit ce qui y a bougé depuis, sans qu'un autre ordinateur ait pu y écrire.
    var liveVolumeScans: Set<String> = []

    // MARK: Doublons

    public internal(set) var duplicates: Phase = .idle
    public internal(set) var duplicateGroups: [DuplicateGroup] = []
    @ObservationIgnored var duplicatePreviewRoots: DuplicatePreviewRoots?
    public internal(set) var duplicateProgress = DuplicateProgress()
    /// Le disque des doublons montrés.
    public internal(set) var duplicatesVolumeID: String?
    public var duplicatesAsClones = false
    public internal(set) var duplicateExclusionRevision = 0
    public internal(set) var duplicateExclusionBlocked = false
    public internal(set) var changingDuplicateExclusions = false
    public internal(set) var duplicateExclusionsWaitingForQuickLook = false
    @ObservationIgnored var duplicateNativePanelClosed: () -> Bool = { AppModel.isNativeDuplicatePreviewClosed() }
    @ObservationIgnored var duplicateExclusionWaitBudget: Duration = .seconds(2)
    public internal(set) var duplicateExclusionsTimedOut = false
    @ObservationIgnored var duplicateReadSession = DuplicateReadSession()
    @ObservationIgnored var duplicatePreviewRevokers: [UUID: () -> Void] = [:]
    /// Les images qui se ressemblent, hors photothèque : l'onglet « Similaires ».
    public let similarImages: SimilarImagesModel

    // MARK: Navigateurs

    public private(set) var browserProfiles: [BrowserProfile] = []
    public private(set) var unavailableBrowserInventories: Set<BrowserKind> = []

    public var suspendedBrowserSelectionCount: Int {
        cart.count { id in
            items[id].map { $0.category == .browsers && $0.protections.contains(.unknownState) } == true
        }
    }

    func preservesBrowserIntent(_ item: CleanupItem) -> Bool {
        // Un choix suspendu reste effaçable par l'utilisateur, sans entrer dans
        // cartItems ni aucune file d'exécution tant que le doute subsiste.
        canSelectForCleanup(item) || (item.category == .browsers && item.protections.contains(.unknownState))
    }

    // MARK: Panier

    @ObservationIgnored var cartSelectionRevision: UInt64 = 0
    public internal(set) var cart: Set<String> = [] {
        didSet { if cart != oldValue { cartSelectionRevision &+= 1 } }
    }

    // MARK: Nettoyage en direct

    public private(set) var cleaning: Cleaning = .idle {
        didSet { invalidateStaleGuidedReview() }
    }
    public private(set) var liveQueue: [CleanupItem] = []
    public private(set) var liveOutcomes: [CleanupOutcome] = []
    public private(set) var currentItemID: String?
    /// Les éléments en cours : quatre au plus partent à la fois.
    public private(set) var currentItemIDs: Set<String> = []
    public private(set) var cleanupProgress = CleanupProgress()
    public private(set) var cleaningStopRequested = false
    public private(set) var freedSoFar: Int64 = 0
    public private(set) var beat = 0
    public private(set) var reclaimed: Capacity?
    private var cleaningTask: Task<Void, Never>?
    private var cancellation: CleanupCancellation?

    // MARK: Historique et permissions

    public private(set) var historyEntries: [CleanupOutcome] = []
    public private(set) var restoredIDs: Set<String> = []
    public private(set) var fullDiskAccess: Bool?

    // MARK: Sections de la phase 2

    public let applications: ApplicationsModel
    public var storageAdvice: [StorageAdvice] = []
    public var adviceSearch: Phase = .idle
    public let updates = UpdateModel()
    public let archive: ArchiveModel
    public let transfer = TransferModel()
    public let largeFiles: LargeFilesModel

    // MARK: Photothèque

    public let photos: PhotosModel

    // MARK: Nuages

    public let clouds: CloudsModel

    // MARK: Analyse partagée et transit

    /// L'arborescence du disque de démarrage, partagée par l'Explorateur, les
    /// règles et les doublons.
    public let disk: DiskIndexModel
    /// Le dossier où le régénérable est renommé avant d'être effacé.
    let transit: Transit

    // MARK: Veille

    /// Barre de menus, alerte disque bas, règles planifiées : ce qui vit sans la fenêtre.
    public let watch: WatchModel
    /// Les applications qu'on met à la corbeille du Mac, et leurs restes.
    public let trashedApps: TrashedAppsModel
    /// `start()` ne se fait qu'une fois : la fenêtre, la barre de menus et une
    /// règle planifiée peuvent chacune le demander.
    private var started = false
    @ObservationIgnored var startupTask: Task<Void, Never>?
    @ObservationIgnored var bootAnalysisRequest: BootAnalysisRequest?
    @ObservationIgnored var overviewAnalysisRequested = false
    @ObservationIgnored var overviewAnalysisStarted = false
    @ObservationIgnored var overviewAnalysisTask: Task<Void, Never>?
    public internal(set) var overviewAnalysisInterrupted = false
    public private(set) var overviewAnalysisStopping = false
    @ObservationIgnored var browserRefreshTask: Task<Void, Never>?
    @ObservationIgnored var browserRefreshGeneration = UUID()

    public convenience init(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard) {
        self.init(home: home, defaults: defaults, disk: DiskIndexModel())
    }

    init(home: URL, defaults: UserDefaults, disk: DiskIndexModel) {
        self.home = home
        self.defaults = defaults
        self.storedPreferences = Preferences.load(home: home, defaults: defaults)
        let history = HistoryStore.standard()
        self.history = history
        let transit = Transit.standard()
        self.transit = transit
        self.engine = CleanupEngine(history: history, transit: transit)
        self.disk = disk
        self.applications = ApplicationsModel()
        self.archive = ArchiveModel()
        self.largeFiles = LargeFilesModel()
        self.watch = WatchModel()
        self.trashedApps = TrashedAppsModel()
        self.photos = PhotosModel()
        self.clouds = CloudsModel()
        self.similarImages = SimilarImagesModel(home: home)
        applications.app = self
        archive.app = self
        transfer.app = self
        largeFiles.app = self
        photos.app = self
        clouds.app = self
        similarImages.app = self
        disk.app = self
        watch.app = self
        trashedApps.app = self
    }

    // MARK: - Démarrage

    public func start() async {
        if let startupTask { await startupTask.value; return }
        guard !started else { return }
        let task = Self.backgroundStorageTask { [self] in
            defer { startupTask = nil }
            await prepareStartup()
        }
        startupTask = task
        await task.value
    }

    private func prepareStartup() async {
        guard !started else { return }
        started = true
        // Le disque local devient utilisable sans attendre un partage distant.
        await refreshVolumeInventory(waitForOtherVolumes: false)
        // Un composant changé est signalé à l'utilisateur ; aucune opération
        // administrateur en cours dans une autre copie n'est interrompue.
        Task { await PrivilegedHelper.synchronizeApprovedInstallation() }
        // Ce qu'un lancement précédent n'a pas fini d'effacer.
        if engine.supports(.removeNow) {
            transit.resume(volumes: volumes.filter { !$0.isBoot }.map(\.mountURL))
        }
        disk.scheduleStartupCache()
        fullDiskAccess = FullDiskAccess.isGranted(home: home)
        await refreshSnapshots()
        await engine.recoverUserLogs()
        await loadHistory()
        Task { await watchVolumes() }
        Task { await refreshTimeMachineMounts() }
        Task { await watchHistory() }
        Task { await keepVolumesFresh() }
    }

    public func refreshVolumes() {
        volumeRevision += 1
        Self.backgroundStorageTask { [self] in
            _ = await refreshVolumeInventory(waitForOtherVolumes: true)
        }
    }

    /// An autonomous refresh has its own bounded reads and cannot inherit
    /// an analysis permit or report progress to a completed analysis.
    nonisolated static func backgroundStorageTask(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        CommandCancellationContext.$cancelsReadOnlyCommands.withValue(false) {
            StorageOperationContext.withUnboundContext {
                Task { @MainActor in await operation() }
            }
        }
    }

    /// L'espace libre bouge sans qu'Oust! le sache : des fichiers effacés dans
    /// le Finder sur un disque externe laissaient « 368 Go libres » affichés
    /// quand il y en avait 1,6 To (Romain, 18/10/2026). Relu toutes les
    /// 20 secondes hors du fil principal (un disque réseau perdu peut faire
    /// attendre `statfs`), et dès qu'Oust! revient au premier plan.
    private func keepVolumesFresh() async {
        Task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await self.refreshVolumeInventory(waitForOtherVolumes: false)
            }
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            await refreshVolumeInventory(waitForOtherVolumes: false)
        }
    }

    public func refreshVolumesInBackground(invalidate: Bool = false) async {
        await refreshVolumeInventory(invalidate: invalidate, waitForOtherVolumes: true)
    }

    func refreshStartupVolume(read: @escaping @Sendable () async -> VolumeDescriptor? = VolumeService.bootVolume) async {
        await watch.refreshDisk(read: read)
        guard !Task.isCancelled else { return }
        drainOverviewAnalysisRequest()
    }

    /// Called synchronously by the common full-read publisher, never by capacity updates.
    func startupQualificationChanged(_ startup: VolumeDescriptor?) {
        guard let startup else {
            startupReadUnverified = true
            startupQualificationRevision &+= 1
            for stamp in completedVolumeAnalyses.values.filter({ $0.volume.isBoot }) {
                completedVolumeAnalyses.removeValue(forKey: stamp.volume.id)
                volumeAnalysisDates.removeValue(forKey: stamp.volume.id)
            }
            invalidateStaleGuidedReview()
            return
        }
        if let previous = volumes.first(where: \.isBoot),
           previous.id != startup.id || previous.scanRoot != startup.scanRoot
            || previous.mountIdentity != startup.mountIdentity || previous.isInternal != startup.isInternal
            || previous.isRemovable != startup.isRemovable || previous.isBoot != startup.isBoot {
            startupQualificationRevision &+= 1
        }
        startupReadUnverified = false
        if let index = volumes.firstIndex(where: \.isBoot) {
            if volumes[index] != startup { volumes[index] = startup }
        } else {
            volumes.insert(startup, at: 0)
        }
    }

    @discardableResult
    func refreshVolumeInventory(
        invalidate: Bool = false, waitForOtherVolumes: Bool, generation: Int? = nil,
        readStartup: @escaping @Sendable () async -> VolumeDescriptor? = VolumeService.bootVolume,
        readVolumes: (@Sendable () async -> [VolumeDescriptor])? = nil
    ) async -> Bool {
        await refreshStartupVolume(read: readStartup)
        guard !Task.isCancelled, generation == nil || generation == mountGeneration else { return false }
        if invalidate { volumeRevision += 1 }
        if generation == nil { scheduleTimeMachineRetry() }
        while !Task.isCancelled, generation == nil || generation == mountGeneration {
            let revision = volumeRevision
            let read: Task<Bool, Never>
            if let existing = volumeRead {
                read = existing
            } else {
                read = Task {
                    let inventory: VolumeService.Inventory?
                    let fresh: [VolumeDescriptor]?
                    if let readVolumes {
                        inventory = nil
                        fresh = await Task.detached(priority: .utility, operation: readVolumes).value
                    } else {
                        inventory = await VolumeService.readInventory()
                        fresh = inventory?.volumes
                    }
                    volumeRead = nil
                    guard revision == volumeRevision else { return false }
                    let pending = inventory?.unverified ?? (fresh == nil ? Set(volumes.filter { !$0.isBoot }.map { $0.mountURL.path }) : [])
                    unresolvedMounts = Set(pending.map(PathNormalizer.normalize))
                    guard let fresh else { return true }
                    let hasNewMount = generation == nil && fresh.contains { candidate in
                        !volumes.contains { $0.id == candidate.id && $0.mountIdentity == candidate.mountIdentity }
                    }
                    publishVolumeInventory(fresh)
                    if generation == nil { scheduleTimeMachineRetry(force: hasNewMount) }
                    return true
                }
                volumeRead = read
            }
            guard waitForOtherVolumes else { return false }
            if await read.value, revision == volumeRevision, generation == nil || generation == mountGeneration {
                return !Task.isCancelled
            }
        }
        return false
    }

    public func refreshSnapshots(using listing: (@Sendable () async -> [LocalSnapshot]?)? = nil,
                                 inventory: (@Sendable () async -> SnapshotInventory?)? = nil) async {
        snapshotsRevision += 1
        snapshotRetainedBytes = nil
        snapshotMeasuredIDs = []
        snapshotSizing = false
        snapshotSizeTask = nil
        let revision = snapshotsRevision
        snapshotsRefreshing = true
        let fresh = await (listing ?? { await VolumeService.readLocalSnapshots() })()
        guard revision == snapshotsRevision else { return }
        snapshotsRefreshing = false
        guard let fresh else { snapshotReadFailed = true; return }
        snapshotReadFailed = false
        snapshots = fresh
        let currentIDs = Set(fresh.map { "snapshot|" + $0.name })
        let obsolete = Set(items.values.filter { $0.category == .snapshots && !currentIDs.contains($0.id) }.map(\.id))
        for id in obsolete { items.removeValue(forKey: id) }
        cart.subtract(obsolete)
        snapshotRetainedBytes = nil
        for snapshot in snapshots {
            let item = snapshotItem(snapshot)
            items[item.id] = item
        }
        if listing == nil || inventory != nil {
            snapshotSizing = true
            snapshotSizeTask = Task {
                let inventory = await (inventory ?? { await SnapshotInventoryReader.shared.read() })()
                guard revision == snapshotsRevision else { return }
                snapshotSizing = false
                if let inventory,
                   Set(inventory.snapshots.filter(\.isDeletable).map(\.name)) == Set(snapshots.filter(\.isDeletable).map(\.name)) {
                    let byName = Dictionary(inventory.snapshots.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                    snapshots = snapshots.map { byName[$0.name] ?? $0 }
                    snapshotRetainedBytes = inventory.retainedBytes
                    snapshotMeasuredIDs = Set(snapshots.filter(\.isDeletable).map { "snapshot|" + $0.name })
                    for snapshot in snapshots {
                        let item = snapshotItem(snapshot)
                        items[item.id] = item
                    }
                }
            }
        }
    }

    func registerVolumeEvent(_ event: VolumeEvent) {
        mountGeneration += 1
        volumeRevision += 1
        switch event {
        case .mounted(let url):
            let path = PathNormalizer.normalize(url.standardizedFileURL.path)
            pendingTimeMachineMounts.insert(path)
            confirmedOrdinaryMounts.removeValue(forKey: path)
        case .unmounted(let url):
            let path = PathNormalizer.normalize(url.standardizedFileURL.path)
            unresolvedMounts.remove(path)
            volumes.removeAll { PathNormalizer.normalize($0.mountURL.standardizedFileURL.path) == path }
            if offeredVolume.map({ PathNormalizer.normalize($0.mountURL.standardizedFileURL.path) }) == path {
                offeredVolume = nil
            }
            forgetVolume(at: url)
        }
    }

    private func watchVolumes() async {
        for await event in VolumeMonitor.events() {
            registerVolumeEvent(event)
            let generation = mountGeneration
            if case .mounted(let url) = event, engine.supports(.removeNow) {
                transit.resume(volumes: [url])
            }
            Task {
                guard await refreshVolumeInventory(waitForOtherVolumes: true, generation: generation),
                      generation == mountGeneration else { return }
                if case .mounted(let url) = event {
                    await classifyVolumeForOffer(at: url, generation: generation)
                } else {
                    await refreshTimeMachineMounts()
                }
            }
        }
    }

    // MARK: - Analyse

    /// Lance tous les chercheurs ; les catégories se remplissent au fil de l'eau.
    public func analyze() async {
        guard !analysis.isRunning else { return }
        // Un autre disque, choisi dans la vue d'ensemble : ses propres chercheurs.
        if let volume = analyzedVolume, !volume.isBoot {
            await analyzeOtherVolume(volume)
            return
        }
        guard let request = reserveBootAnalysis(bootVolume, preselect: true) else { return }
        await runBootAnalysis(request)
    }

    func runBootAnalysis(_ request: BootAnalysisRequest, context supplied: RuleContext? = nil,
                         finders: [FinderKind] = FinderKind.allCases,
                         readBrowsers: (@MainActor @Sendable () async -> BrowserAnalysisSnapshot?)? = nil,
                         readLocation: (@Sendable (URL) -> AnalysisReview.Location?)? = nil,
                         readRunningBrowsers: (@MainActor @Sendable () -> Set<BrowserKind>)? = nil) async {
        // Le retour d’une lecture native, y compris après Arrêter, appartient
        // encore à cette opération : aucune nouvelle admission entre-temps.
        await StorageOperationContext.$isBound.withValue(true) {
            await CommandCancellationContext.$cancelsReadOnlyCommands.withValue(true) {
                await collectBootAnalysis(request, context: supplied, finders: finders,
                                          readBrowsers: readBrowsers, readLocation: readLocation,
                                          readRunningBrowsers: readRunningBrowsers)
            }
        }
    }

    private func collectBootAnalysis(_ request: BootAnalysisRequest, context supplied: RuleContext?,
                                     finders: [FinderKind],
                                     readBrowsers: (@MainActor @Sendable () async -> BrowserAnalysisSnapshot?)?,
                                     readLocation: (@Sendable (URL) -> AnalysisReview.Location?)?,
                                     readRunningBrowsers: (@MainActor @Sendable () -> Set<BrowserKind>)?) async {
        var completed = false
        defer {
            if bootAnalysisRequest?.id == request.id {
                bootAnalysisRequest = nil
                analyzingVolumeID = nil
                overviewAnalysisStopping = false
                cart = cart.filter { items[$0].map(preservesBrowserIntent) == true }
                if !completed { overviewAnalysisInterrupted = true }
                analysis = completed ? .done(Date()) : .idle
            }
        }
        // Une mesure lancée depuis Navigateurs ne doit pas survivre dans la
        // génération suivante. Son retrait réel précède la nouvelle collecte.
        browserRefreshGeneration = UUID()
        let precedingBrowserRead = browserRefreshTask
        precedingBrowserRead?.cancel()
        await precedingBrowserRead?.value
        browserRefreshTask = nil
        guard !Task.isCancelled, let reviewVolume = request.volume,
              let reviewLocation = await checkStorageIO({
                  if let readLocation { return readLocation(reviewVolume.scanRoot) }
                  return AnalysisReview.Location(reviewVolume.scanRoot)
              }) ?? nil,
              await isCurrentBootAnalysis(request, location: reviewLocation) else { return }
        let firstTime = request.preselect && !cart.contains { items[$0].map { isOnBootVolume($0) } ?? false }
        var context = supplied ?? RuleContext(home: home, projectRoots: preferences.projectRoots,
                                  historyRetentionDays: preferences.historyRetentionDays,
                                  compressionAgeDays: preferences.compressionAgeMonths * 30)
        let tree = request.preselect && supplied == nil ? disk.treeProvider() : context.tree
        context.tree = tree
        let measurer: Measurer = tree.map(Measurer.tree) ?? .disk
        let policy = PreselectionPolicy(recencyDays: preferences.recencyDays)
        let operation = RuleEngine.runWithinStorageOperation(context, finders: finders, measurer: measurer)
        var batches: [RuleBatch] = []
        var findersDone = Set<FinderKind>()
        let accepted = await withTaskCancellationHandler { @MainActor in
            for await batch in operation.batches {
                guard await isCurrentBootAnalysis(request, location: reviewLocation) else { return false }
                batches.append(batch)
                findersDone.insert(batch.finder)
            }
            return !Task.isCancelled
        } onCancel: {
            operation.completion.cancel()
        }
        operation.completion.cancel()
        // Annuler le flux ne signifie pas que simctl ou la lecture a fini.
        await operation.completion.value
        guard accepted, Set(finders).isSubset(of: findersDone),
              await isCurrentBootAnalysis(request, location: reviewLocation) else { return }
        let browserSnapshot: BrowserAnalysisSnapshot?
        if let readBrowsers {
            guard let snapshot = await readBrowsers() else { return }
            browserSnapshot = snapshot
        } else if supplied == nil {
            guard let snapshot = await readBrowserSnapshot() else { return }
            browserSnapshot = snapshot
        } else { browserSnapshot = nil }
        guard await isCurrentBootAnalysis(request, location: reviewLocation) else { return }
        if request.preselect && supplied == nil { await refreshSnapshots() }
        // Les preuves des lots se relisent hors du fil d’interface, sans
        // publier les tailles d’une génération arrêtée ou remplacée.
        let staged = batches
        guard let fresh = await checkStorageIO({ () -> [(CleanupItem, AnalyzedItemLocation?)]? in
            let rows = staged.flatMap { batch in batch.revalidatedItems().map { ($0, batch.analysisLocation(for: $0)) } }
            guard reviewLocation.matches(reviewVolume.scanRoot) else { return nil }
            return rows
        }) ?? nil, await isCurrentBootAnalysis(request, location: reviewLocation) else { return }
        // L’ancien résultat reste visible en cas d’arrêt. Le panier vivant est
        // conservé : une case décochée pendant l’attente ne revient jamais.
        let mayPreselect = firstTime && cartSelectionRevision == request.selectionRevision
        items = items.filter { $0.value.category == .browsers || $0.value.category == .snapshots || $0.value.category.section == .duplicates
            || $0.value.category.section == .photos || $0.value.category.section == .clouds
            || !isOnBootVolume($0.value) }
        analysisLocations = analysisLocations.filter { items[$0.key] != nil }
        backupAnalysisTokens = backupAnalysisTokens.filter { analysisLocations[$0.key] != nil }
        stopReadOnlyRevalidationIfEmpty()
        var reviewIDs = Set<String>()
        for (item, location) in fresh {
            recordAnalyzedItem(item, analysisLocation: location, preselect: mayPreselect, policy: policy)
            reviewIDs.insert(item.id)
        }
        if let browserSnapshot { publishBrowserSnapshot(browserSnapshot, readRunningBrowsers: readRunningBrowsers) }
        finishedFinders = findersDone
        cart = cart.filter { items[$0].map(preservesBrowserIntent) == true }
        saveAnalysisReview(for: reviewVolume, location: reviewLocation, ids: reviewIDs, locationWasVerified: true)
        recordVolumeAnalysis(for: reviewVolume)
        completed = true
        if supplied == nil { refreshVolumes() }
    }

    func setOverviewAnalysisStopping(_ value: Bool) { overviewAnalysisStopping = value }

    public func refreshBrowsers() { _ = startBrowserRefresh() }

    @discardableResult
    func startBrowserRefresh(read: (@MainActor @Sendable () async -> BrowserAnalysisSnapshot?)? = nil,
                             readRunningBrowsers: (@MainActor @Sendable () -> Set<BrowserKind>)? = nil) -> Task<Void, Never>? {
        guard bootAnalysisRequest == nil else { return nil }
        let previous = browserRefreshTask
        previous?.cancel()
        let generation = UUID()
        browserRefreshGeneration = generation
        let task = Self.backgroundStorageTask { [self] in
            defer { if browserRefreshGeneration == generation { browserRefreshTask = nil } }
            await previous?.value
            guard !Task.isCancelled, browserRefreshGeneration == generation, bootAnalysisRequest == nil else { return }
            let snapshot = await StorageOperationContext.$isBound.withValue(true) {
                if let read { return await read() }
                return await readBrowserSnapshot()
            }
            guard !Task.isCancelled, browserRefreshGeneration == generation, bootAnalysisRequest == nil,
                  let snapshot else { return }
            publishBrowserSnapshot(snapshot, readRunningBrowsers: readRunningBrowsers)
        }
        browserRefreshTask = task
        return task
    }

    func readBrowserSnapshot() async -> BrowserAnalysisSnapshot? {
        let home = home
        let running = Set(BrowserKind.allCases.filter { BrowserFinder.isRunning($0) })
        guard !Task.isCancelled, let snapshot = await checkStorageIO({
            let inventory = BrowserFinder.inventory(home: home)
            let rows = inventory.profiles.flatMap { BrowserFinder.items(for: $0, isRunning: running.contains($0.browser)) }
            return BrowserAnalysisSnapshot(profiles: inventory.profiles, items: rows,
                                           unavailableBrowsers: inventory.unavailableBrowsers)
        }), !Task.isCancelled else { return nil }
        let measures = await Scanner.measure(snapshot.items.flatMap(\.paths))
        guard !Task.isCancelled else { return nil }
        var result = snapshot
        for index in result.items.indices {
            result.items[index].sizes = result.items[index].paths.compactMap { measures[$0]?.sizes }.total()
        }
        return result
    }

    private func publishBrowserSnapshot(_ snapshot: BrowserAnalysisSnapshot,
                                       readRunningBrowsers: (@MainActor @Sendable () -> Set<BrowserKind>)? = nil) {
        // La catégorie définit ce que cette lecture possède : un préfixe d’ID
        // ne suffit pas à retirer le résultat ou le choix d’un autre outil.
        let previousIDs = Set(items.filter { $0.value.category == .browsers }.keys)
        // Le même chemin après une lecture indéterminée ne prouve pas la même
        // identité : une lecture complète ne réactive jamais le choix ancien.
        let requiresNewChoice = items.values.filter { item in
            item.category == .browsers && item.protections.contains(.unknownState)
                && BrowserFinder.browser(of: item).map { !snapshot.unavailableBrowsers.contains($0) } == true
        }.map(\.id)
        var refreshed = items.filter { $0.value.category != .browsers }
        for (id, original) in items where original.category == .browsers
            && BrowserFinder.browser(of: original).map({ snapshot.unavailableBrowsers.contains($0) }) == true {
            var item = original
            item.protect(.unknownState)
            item.sizes.freeable = 0
            refreshed[id] = item
        }
        let running = readRunningBrowsers?() ?? Set(BrowserKind.allCases.filter { BrowserFinder.isRunning($0) })
        for var item in snapshot.items where item.category == .browsers {
            if let browser = BrowserFinder.browser(of: item) {
                guard !snapshot.unavailableBrowsers.contains(browser) else { continue }
                if running.contains(browser) { item.protect(.appRunning(name: browser.displayName)) }
            }
            guard refreshed[item.id].map({ $0.category == .browsers }) ?? true else { continue }
            refreshed[item.id] = item
        }
        let current = refreshed.filter { $0.value.category == .browsers }
        let retiredIDs = previousIDs.subtracting(current.keys)
        let forbiddenIDs = current.compactMap { preservesBrowserIntent($0.value) ? nil : $0.key }
        items = refreshed
        browserProfiles = browserProfiles.filter { snapshot.unavailableBrowsers.contains($0.browser) }
            + snapshot.profiles.filter { !snapshot.unavailableBrowsers.contains($0.browser) }
        unavailableBrowserInventories = snapshot.unavailableBrowsers
        cart.subtract(retiredIDs)
        cart.subtract(forbiddenIDs)
        cart.subtract(requiresNewChoice)
    }

    /// Les éléments d'une section, triés du plus libérable au moins. Ceux des
    /// sections qui portent sur un disque (Développement, Système, Doublons)
    /// sont ceux du disque choisi dans la vue d'ensemble.
    public func items(in categories: Set<ItemCategory>) -> [CleanupItem] {
        let scope = itemScope()
        return orderedForDisplay(items.values.filter { categories.contains($0.category) && scope($0) && isCurrentAnalyzedItem($0) })
    }

    /// Les points de restauration se lisent par date ; les autres propositions
    /// restent classées par place récupérable. Les égalités ont un ordre stable.
    private func orderedForDisplay(_ candidates: [CleanupItem]) -> [CleanupItem] {
        candidates.sorted { left, right in
            let lhs = left.method.isSnapshot, rhs = right.method.isSnapshot
            if lhs != rhs { return lhs }
            if lhs {
                let first = left.lastActivity ?? .distantPast, second = right.lastActivity ?? .distantPast
                if first != second { return first > second }
            } else if left.sizes.freeable != right.sizes.freeable {
                return left.sizes.freeable > right.sizes.freeable
            }
            return left.id < right.id
        }
    }

    // MARK: - Recherche et filtres

    public func filter(for section: AppSection) -> ItemFilter { filters[section] ?? .none }

    public func setFilter(_ filter: ItemFilter, for section: AppSection) {
        filters[section] = filter.isActive ? filter : nil
    }

    /// Les éléments d'une section qui passent son filtre.
    public func visibleItems(in categories: Set<ItemCategory>, section: AppSection) -> [CleanupItem] {
        let filter = filter(for: section)
        let all = items(in: categories)
        guard filter.isActive else { return all }
        let now = Date()
        return all.filter { filter.matches($0, now: now) }
    }

    /// Combien d'éléments d'une section son filtre cache.
    public func hiddenCount(in categories: Set<ItemCategory>, section: AppSection) -> Int {
        let filter = filter(for: section)
        guard filter.isActive else { return 0 }
        let now = Date()
        return items(in: categories).count(where: { !filter.matches($0, now: now) })
    }

    /// Ce que la recherche globale trouve, du plus libérable au moins.
    public var searchResults: [CleanupItem] {
        let filter = ItemFilter(query: searchText)
        guard filter.isActive else { return [] }
        return orderedForDisplay(items.values.filter { filter.matchesQuery($0) && isCurrentAnalyzedItem($0) })
    }

    public var isSearching: Bool { ItemFilter(query: searchText).isActive }

    public func total(of categories: Set<ItemCategory>, headlineOnly: Bool = true) -> Int64 {
        let scope = itemScope()
        return items.values.filter { categories.contains($0.category) && (!headlineOnly || $0.countsInHeadline)
            && canSelectForCleanup($0) && scope($0) }
            .reduce(0) { $0 + $1.sizes.freeable }
    }

    // MARK: - Explorateur

    /// Ouvre un volume dans l'Explorateur. `rescan` relit tout, même si une
    /// analyse est gardée.
    ///
    /// `previous` : l'arbre fait depuis le branchement du disque, que FSEvents
    /// sait mettre à jour sans tout relire (l'analyse de la vue d'ensemble).
    public func explore(_ volume: VolumeDescriptor, rescan: Bool = false) {
        explore(volume, rescan: rescan, previous: nil)
    }

    func explore(_ volume: VolumeDescriptor, rescan: Bool, previous: ScanIndex?) {
        guard canAnalyzeVolume(volume) else { return }
        // Le disque de démarrage : l'arbre partagé, gardé d'une fois sur l'autre.
        if volume.isBoot {
            if treeVolume?.isBoot != true {
                scanTask?.cancel()
                scanProgress.cancel()
                displayedExplorerIndex = nil
                treeVolume = nil
                tree = nil
            }
            disk.explore()
            return
        }
        disk.cancelCacheDisplay()
        // Le parcours partagé continue sans l'Explorateur : les règles
        // l'attendent peut-être.
        if treeVolume?.isBoot != true {
            scanTask?.cancel()
            scanProgress.cancel()
        }
        let progress = ScanProgress()
        scanProgress = progress
        displayedExplorerIndex = nil
        treeVolume = volume
        tree = nil
        explorer = .running
        // Gardé seulement pour un disque monté, pas pour un dossier choisi ; sur
        // le disque seulement s'il a un UUID.
        let isMounted = volumes.contains { $0.id == volume.id }
        scanTask = Task {
            defer {
                if scanProgress === progress, explorer.isRunning { explorer = .idle }
            }
            let roots = [volume.scanRoot]
            guard let resolved = await resolveAnalysisRoots(roots), let anchor = resolved.directories.first,
                  !progress.isCancelled, self.treeVolume?.id == volume.id, self.canAnalyzeVolume(volume) else { return }
            var physicalVolume = volume
            physicalVolume.scanRoot = anchor.url
            let scanningVolume = physicalVolume
            // Les fichiers de 100 Ko et plus sont gardés un à un : assez pour que
            // les onglets Types et Âge de l'Explorateur portent sur l'essentiel
            // des octets, sans un nœud par fichier sur un disque de 5 millions.
            // Un parcours complet, sauf si l'arbre a été fait depuis que le
            // disque est branché : avant, il a pu changer sur un autre
            // ordinateur, sans que les événements de ce Mac le sachent.
            // Les mêmes réglages que l'arbre partagé, et de quoi trouver les
            // traces de macOS : les règles du disque y lisent leurs marqueurs.
            let home = home
            guard let options = await checkStorageIO({ Self.volumeScanOptions(for: scanningVolume, home: home) }),
                  await resolveAnalysisRoots(roots) == resolved, !progress.isCancelled,
                  self.treeVolume?.id == volume.id, self.canAnalyzeVolume(volume) else {
                if !progress.isCancelled, self.treeVolume?.id == volume.id { self.explorer = .idle }
                return
            }
            let cached = previous ?? (rescan ? nil : self.volumeIndexes[volume.id])
            let (scanned, _) = await ScanIndex.refreshBound(cached, root: anchor, options: options, progress: progress)
            guard !progress.isCancelled else { return }
            let fresh = await scanned.revalidatedForDisplay()
            guard await resolveAnalysisRoots(roots) == resolved, !progress.isCancelled,
                  self.treeVolume?.id == volume.id, self.canAnalyzeVolume(volume) else { return }
            if isMounted {
                self.volumeIndexes[volume.id] = fresh
                self.liveVolumeScans.insert(volume.id)
            }
            self.showExplorerIndex(fresh, volume: volume)
            if isMounted {
                Task.detached(priority: .utility) { try? Self.volumeStore(for: volume)?.save(fresh) }
            }
            Self.backgroundStorageTask { await self.refreshVolumesInBackground() }
        }
    }

    public func explore(folder: URL) {
        guard canAnalyzePath(folder) else { return }
        let name = folder.lastPathComponent
        let capacity = Capacity(total: 0, available: 0, availableForImportantUsage: 0)
        explore(VolumeDescriptor(name: name, mountURL: folder, scanRoot: folder, isBoot: false, isInternal: true,
                                 isRemovable: false, capacity: capacity))
    }

    public func cancelExploration() {
        disk.cancelCacheDisplay()
        scanProgress.cancel()
        scanTask?.cancel()
        explorer = tree == nil ? .idle : .done(Date())
    }

    /// Un nœud de l'arborescence comme élément du panier. Si une règle connaît ce
    /// chemin, c'est son élément (et sa méthode) qui sert.
    public func item(for node: TreeNode) -> CleanupItem {
        let path = PathNormalizer.normalize(node.path)
        if let known = items.values.first(where: {
            $0.paths.count == 1 && PathNormalizer.normalize($0.paths[0].path) == path
                && (!$0.requiresLiveAnalysisLocation || $0.fingerprint?.fileID == node.fileID)
                && isCurrentAnalyzedItem($0)
        }) {
            return known
        }
        return explorerItem(url: URL(fileURLWithPath: path), title: node.name, sizes: node.total,
                            modified: node.latestModification)
    }

    public func item(for file: FileLeaf, in node: TreeNode) -> CleanupItem {
        let url = URL(fileURLWithPath: PathNormalizer.normalize(node.path)).appendingPathComponent(file.name)
        if let diagnostic = items["\(CleanupItem.invalidPreferenceRuleID)|\(url.path)"],
           diagnostic.fingerprint?.fileID == file.fileID, isCurrentAnalyzedItem(diagnostic) {
            return diagnostic
        }
        return explorerItem(url: url, title: file.name, sizes: file.sizes, modified: file.modified)
    }

    private func explorerItem(url: URL, title: String, sizes: Sizes, modified: Date?) -> CleanupItem {
        var item = CleanupItem(id: "explorer|\(url.path)", title: title, detail: url.deletingLastPathComponent().path,
                               paths: [url], category: .explorer, owner: treeVolume?.name ?? "",
                               ruleID: "explorer.item", safety: .review, method: .trash, sizes: sizes,
                               lastActivity: modified, rebuild: .irreversible,
                               fingerprint: Fingerprint(modificationDate: nil, fileID: nil))
        if canMoveFiles && !PathGuard(home: home).allows(url) { item.protect(.systemPath) }
        if let volume = treeVolume, isTimeMachine(volume) { item.protect(.timeMachine) }
        return item
    }

    // MARK: - Doublons

    public func findDuplicates(in roots: [URL]? = nil) async {
        guard !duplicates.isRunning, roots?.allSatisfy(canAnalyzePath) != false else { return }
        // Sur un autre disque choisi dans la vue d'ensemble : ce disque seul.
        if roots == nil, let volume = analyzedVolume, !volume.isBoot {
            await findDuplicates(on: volume)
            return
        }
        guard let reader = beginDuplicateRead() else { return }
        defer {
            withExtendedLifetime(reader) {}
            if duplicates.isRunning { duplicates = .idle }
        }
        duplicates = .running
        let progress = DuplicateProgress()
        duplicateProgress = progress
        var options = DuplicateOptions.standard(home: home)
        if let roots { options.roots = roots }
        options.minimumSize = Int64(preferences.duplicateMinimumMegabytes) * 1_000_000
        options.exclusions = preferences.duplicateExclusions
        let revision = duplicateExclusionRevision
        let requestedRoots = options.roots
        guard await canSearchDuplicates(requestedRoots, reader: reader), let resolved = await resolveAnalysisRoots(requestedRoots, reader: reader),
              revision == duplicateExclusionRevision, await canSearchDuplicates(resolved.urls, reader: reader) else { return }
        options.roots = resolved.urls
        options.exclusions.analysisRoots = resolved.directories
        // Les candidats viennent des feuilles de l'arbre partagé, sans
        // reparcourir le dossier personnel.
        let tree = await disk.treeProvider()()
        guard await resolveAnalysisRoots(requestedRoots, reader: reader) == resolved,
              revision == duplicateExclusionRevision, await canSearchDuplicates(resolved.urls, reader: reader) else { return }
        let groups = await DuplicateFinder.find(options, tree: tree, progress: progress)
        guard await resolveAnalysisRoots(requestedRoots, reader: reader) == resolved, revision == duplicateExclusionRevision,
              await canSearchDuplicates(resolved.urls, reader: reader) else { return }
        showDuplicates(groups, volume: bootVolume, previewRoots: DuplicatePreviewRoots(requestedRoots, resolved))
    }

    /// Les groupes trouvés sur un disque remplacent ceux de ce disque ; ce qui a
    /// été coché sur un autre disque reste dans la corbeille.
    func showDuplicates(_ groups: [DuplicateGroup], volume: VolumeDescriptor?, previewRoots: DuplicatePreviewRoots? = nil) {
        duplicateGroups = groups
        duplicatePreviewRoots = previewRoots
        duplicatesVolumeID = volume?.id
        items = items.filter { entry in
            entry.value.category != .duplicates || !(volume.map { belongs(entry.value, to: $0) } ?? true)
        }
        cart = cart.filter { items[$0] != nil }
        for group in groups {
            for item in group.cleanupItems(asClones: duplicatesAsClones) { items[item.id] = item }
        }
        if preferences.duplicateAutoSelect { add(automaticDuplicateItems()) }
        duplicates = .done(Date())
    }

    /// Cocher d'office, dans chaque groupe, tout sauf l'exemplaire à garder
    /// (demande de Romain, 18/10/2026) ; décocher retire ce qui a été coché ainsi.
    public func setDuplicateAutoSelect(_ enabled: Bool) {
        preferences.duplicateAutoSelect = enabled
        let automatic = automaticDuplicateItems()
        if enabled { add(automatic) } else { remove(automatic.map(\.id)) }
    }

    /// L'exemplaire gardé d'un groupe : celui des règles, ou à égalité celui de
    /// la sélection automatique quand elle est active.
    public func duplicateKeep(_ group: DuplicateGroup) -> Int? {
        group.keep ?? (preferences.duplicateAutoSelect ? group.automatic?.keep : nil)
    }

    private func automaticDuplicateItems() -> [CleanupItem] {
        duplicateGroups.flatMap { group -> [CleanupItem] in
            guard let automatic = group.automatic else { return [] }
            return automatic.remove.sorted().compactMap { duplicateItem(group: group, file: $0, keeping: automatic.keep) }
        }
    }

    /// L'élément de panier d'une copie précise d'un groupe.
    public func duplicateItem(group: DuplicateGroup, file index: Int, keeping chosen: Int? = nil) -> CleanupItem? {
        guard isCurrentExactGroup(group),
              let keep = chosen ?? duplicateKeep(group) ?? group.files.indices.first(where: { $0 != index }), keep != index
        else { return nil }
        let file = group.files[index]
        let original = group.files[keep]
        return CleanupItem(
            id: "duplicate|\(file.url.path)", title: file.url.lastPathComponent,
            detail: file.url.deletingLastPathComponent().path, paths: [file.url], category: .duplicates,
            owner: original.url.lastPathComponent, ruleID: "duplicate.copy", safety: .review,
            method: duplicatesAsClones ? .cloneOf(original: original.url.path) : .trash,
            sizes: Sizes(allocated: file.allocated, freeable: file.privateSize), lastActivity: file.modified,
            rebuild: .irreversible, fingerprint: Fingerprint(modificationDate: file.modified, fileID: nil)
        )
    }

    // MARK: - Panier

    public func isInCart(_ id: String) -> Bool { cart.contains(id) }

    func recordAnalyzedItem(_ item: CleanupItem, analysisLocation: AnalyzedItemLocation? = nil,
                            preselect: Bool, policy: PreselectionPolicy) {
        if item.requiresLiveAnalysisLocation {
            guard let url = item.paths.first, let analysisLocation,
                  item.isDeviceBackup || analysisLocation.isCurrent(at: url) else { return }
            analysisLocations[item.id] = analysisLocation
            if item.isDeviceBackup { backupAnalysisTokens[item.id] = UUID() }
        }
        items[item.id] = item
        if item.requiresLiveAnalysisLocation { startReadOnlyRevalidation() }
        if !canSelectForCleanup(item) {
            cart.remove(item.id)
        } else if preselect, policy.preselects(item) {
            cart.insert(item.id)
        }
    }

    func recordAnalyzedBatch(_ batch: RuleBatch, preselect: Bool, policy: PreselectionPolicy) {
        for item in batch.items {
            recordAnalyzedItem(item, analysisLocation: batch.analysisLocation(for: item),
                               preselect: preselect, policy: policy)
        }
    }

    private func isCurrentAnalyzedItem(_ item: CleanupItem) -> Bool {
        guard item.requiresLiveAnalysisLocation else { return true }
        if item.isDeviceBackup { return backupAnalysisTokens[item.id] != nil }
        guard let url = item.paths.first else { return false }
        return analysisLocations[item.id]?.isCurrent(at: url) == true
    }

    /// Un fichier peut changer sans modifier l'état observé par la vue. Revérifie
    /// uniquement les fiches affichables, y compris après remplacement de leur
    /// dossier, sans garder de descripteur ni suivre toute la bibliothèque.
    private func startReadOnlyRevalidation() {
        guard readOnlyRevalidationTask == nil else { return }
        readOnlyRevalidationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                self.removeStaleReadOnlyFindings()
                await self.revalidateBackupFindings()
            }
        }
    }

    private func removeStaleReadOnlyFindings() {
        let obsolete = Set(analysisLocations.keys.filter { id in
            guard let item = items[id], item.requiresLiveAnalysisLocation else { return true }
            return !isCurrentAnalyzedItem(item)
        })
        guard !obsolete.isEmpty else { return }
        for id in obsolete {
            analysisLocations[id] = nil
            backupAnalysisTokens[id] = nil
        }
        items = items.filter { !$0.value.requiresLiveAnalysisLocation || !obsolete.contains($0.key) }
        cart.subtract(obsolete)
        stopReadOnlyRevalidationIfEmpty()
    }

    private struct BackupFinding: Sendable {
        let item: CleanupItem
        let url: URL
        let location: AnalyzedItemLocation
        let token: UUID
    }

    private func revalidateBackupFindings() async {
        let current = backupAnalysisTokens.compactMap { id, token -> BackupFinding? in
            guard let item = items[id], let url = item.paths.first, let location = analysisLocations[id] else { return nil }
            return BackupFinding(item: item, url: url, location: location, token: token)
        }
        guard !current.isEmpty else { return }
        let checked = await checkStorageIO {
            current.map { finding in
                finding.location.isCurrent(at: finding.url) ? finding.location.revalidateBackupBadge(finding.item) : nil
            }
        }
        guard !Task.isCancelled else { return }
        for (offset, finding) in current.enumerated() {
            let id = finding.item.id
            guard backupAnalysisTokens[id] == finding.token, items[id] == finding.item else { continue }
            if let replacement = checked?[offset] {
                if replacement != finding.item { items[id] = replacement }
            } else {
                items[id] = nil
                backupAnalysisTokens[id] = nil
                analysisLocations[id] = nil
                cart.remove(id)
            }
        }
        stopReadOnlyRevalidationIfEmpty()
    }

    private func stopReadOnlyRevalidationIfEmpty() {
        guard analysisLocations.isEmpty else { return }
        readOnlyRevalidationTask?.cancel()
        readOnlyRevalidationTask = nil
    }

    public var canMoveFiles: Bool { engine.supports(.trash) }

    public var canCloneDuplicates: Bool { engine.supports(.cloneOf(original: "")) }

    public var canCleanDuplicates: Bool { duplicatesAsClones ? canCloneDuplicates : canMoveFiles }

    public var availableDuplicateSuggestions: [CleanupItem] {
        guard canCleanDuplicates else { return [] }
        return duplicateGroups.flatMap { $0.cleanupItems(asClones: duplicatesAsClones) }.filter(canSelectForCleanup)
    }

    public var reclaimableDuplicateBytes: Int64 {
        availableDuplicateSuggestions.reduce(0) { $0 + $1.sizes.freeable }
    }

    public func canSelectForCleanup(_ item: CleanupItem) -> Bool {
        item.isSelectable && engine.supports(item.method) && isCurrentDuplicateSelection(item)
    }

    public func toggle(_ item: CleanupItem) {
        guard canSelectForCleanup(items[item.id] ?? item) else { return }
        if cart.contains(item.id) {
            cart.remove(item.id)
        } else {
            items[item.id] = items[item.id] ?? item
            cart.insert(item.id)
        }
    }

    public func add(_ newItems: [CleanupItem]) {
        for item in newItems where canSelectForCleanup(items[item.id] ?? item) {
            items[item.id] = items[item.id] ?? item
            cart.insert(item.id)
        }
    }

    public func remove(_ ids: [String]) {
        cart.subtract(ids)
    }

    public func clearCart() { cart.removeAll() }

    public var cartItems: [CleanupItem] {
        orderedForDisplay(cart.compactMap { items[$0] }.filter(canSelectForCleanup))
    }

    /// Ce que le panier rendrait, d'après les tailles libérables.
    public var cartTotal: Int64 {
        cartItems.filter { !$0.method.isSnapshot }.reduce(0) { $0 + $1.sizes.freeable } + (cartSnapshotBytes ?? 0)
    }
    public var cartFreesNow: Int64 {
        cartItems.filter { $0.method.freesImmediately && !$0.method.isSnapshot }.reduce(0) { $0 + $1.sizes.freeable }
            + (cartSnapshotBytes ?? 0)
    }
    public var cartGoesToTrash: Int64 {
        cartItems.filter { $0.method == .trash || $0.method == .trashFromCloud }.reduce(0) { $0 + $1.sizes.freeable }
    }

    /// Rien ne reviendra sur ce Mac, et on le sait : la corbeille ne contient que
    /// des fichiers du cloud restés en ligne. Un « — » y faisait erreur (essai
    /// du 18/10/2026). Un snapshot compte aussi 0 d'avance, mais rend de la
    /// place : là, le « — » veut dire « inconnu » et reste.
    public var cartFreesNothingHere: Bool {
        let items = cartItems
        return !items.isEmpty && items.allSatisfy { $0.sizes.freeable == 0 && $0.notes.contains(.cloudOnly) }
    }

    /// Une confirmation renforcée s'impose (SPEC §6.2, étape 3).
    public var cartNeedsStrongConfirmation: Bool {
        cartTotal > 5_000_000_000 || cartItems.contains { $0.safety == .review }
    }

    // MARK: - Nettoyage

    public func startCleaning() {
        guard cleaning != .running, !cart.isEmpty else { return }
        startCleaning(cartItems)
    }

    /// L'écart minimal entre deux éléments qui quittent la liste. Le transit et
    /// le parallélisme les font finir presque ensemble ; sans cet écart, la
    /// pulsation battrait une fois pour tous. Deux secondes au plus en tout.
    static func beatSpacing(for count: Int) -> Duration {
        .milliseconds(min(150, max(40, 2_000 / max(1, count))))
    }

    func startCleaning(_ requested: [CleanupItem]) {
        let queue = requested.filter(canSelectForCleanup)
        guard cleaning != .running, !queue.isEmpty else { return }
        liveQueue = queue
        liveOutcomes = []
        freedSoFar = 0
        currentItemID = nil
        currentItemIDs = []
        cleanupProgress = CleanupProgress(total: queue.count)
        cleaningStopRequested = false
        reclaimed = nil
        cleaning = .running
        let engine = engine
        let transit = transit
        let cancellation = CleanupCancellation()
        self.cancellation = cancellation
        let spacing = Self.beatSpacing(for: queue.count)
        // Les volumes, tant que les éléments existent : de quoi remesurer après le transit.
        let volumes = CleanupEngine.volumes(of: queue)
        cleaningTask = Task {
            let clock = ContinuousClock()
            var lastBeat = clock.now - .seconds(1)
            for await event in engine.run(queue, cancellation: cancellation) {
                self.cleanupProgress.receive(event)
                switch event {
                case .began:
                    break
                case .phaseChanged:
                    break
                case .itemBegan(let id):
                    self.currentItemID = id
                    self.currentItemIDs.insert(id)
                case .itemFinished(let outcome):
                    let wait = lastBeat + spacing - clock.now
                    if wait > .zero, !cancellation.isCancelled { try? await Task.sleep(for: wait) }
                    lastBeat = clock.now
                    self.currentItemIDs.remove(outcome.itemID)
                    self.liveOutcomes.append(outcome)
                    self.liveQueue.removeAll { $0.id == outcome.itemID }
                    if outcome.result.succeeded {
                        if self.items[outcome.itemID]?.method.isSnapshot == true {
                            self.snapshotRetainedBytes = nil
                            self.snapshotMeasuredIDs = []
                        }
                        self.freedSoFar += outcome.bytes
                        self.beat += 1
                        self.cart.remove(outcome.itemID)
                        self.items.removeValue(forKey: outcome.itemID)
                    }
                case .finished(var report):
                    self.currentItemID = nil
                    self.currentItemIDs = []
                    self.cancellation = nil
                    self.cleaning = .finished(report)
                    await self.loadHistory()
                    await self.refreshSnapshots()
                    self.refreshVolumes()
                    // APFS rend l'espace des snapshots du disque de démarrage ;
                    // ailleurs, il n'y a rien à suivre.
                    if volumes == [VolumeService.bootDataRoot] { self.watchReclaim() } else { self.reclaimed = nil }
                    // Ce qui est parti doit aussi quitter l'arbre partagé.
                    self.disk.refresh()
                    // Le transit vidé, le volume a rendu ce qui était compté :
                    // seulement alors on peut dire ce que retiennent les snapshots.
                    if report.purging > 0 {
                        await transit.drained()
                        report.purging = 0
                        report.availableAfter = CleanupEngine.available(on: volumes, capacity: VolumeService.capacity(of:))
                            ?? report.availableAfter
                        // Seulement si ce bilan est encore celui qu'on montre : un
                        // autre nettoyage a pu commencer pendant l'effacement.
                        if case .finished(let shown) = self.cleaning, shown.sessionID == report.sessionID {
                            self.cleaning = .finished(report)
                        }
                        self.refreshVolumes()
                    }
                }
            }
        }
    }

    /// Arrête entre deux éléments ; ceux déjà partis finissent, le bilan arrive.
    public func cancelCleaning() {
        guard cleaning == .running else { return }
        cleaningStopRequested = true
        cancellation?.cancel()
    }

    // MARK: - Snapshots après un gros nettoyage

    /// Les snapshots Time Machine qu'on peut supprimer.
    public var deletableSnapshots: [CleanupItem] {
        items(in: [.snapshots]).filter(\.isSelectable)
    }

    /// Ce qu'un nettoyage n'a pas encore rendu : attendu, moins ce que le volume
    /// a déjà rendu, reprise d'APFS comprise.
    public func stillHeldBack(_ report: CleanupReport) -> Int64 {
        guard report.purging == 0, let before = report.availableBefore else { return 0 }
        let now = max(reclaimed?.available ?? 0, report.availableAfter ?? 0)
        return max(0, report.expectedNow - (now - before))
    }

    /// Après un gros nettoyage dont les snapshots retiennent l'espace : les
    /// supprimer, avec la même invite administrateur que la section Système.
    public var shouldOfferSnapshotRelease: Bool {
        guard case .finished(let report) = cleaning, !deletableSnapshots.isEmpty else { return false }
        return stillHeldBack(report) >= 1_000_000_000
    }

    public func releaseSnapshots() {
        startCleaning(deletableSnapshots)
    }

    public func dismissReport() {
        cleaning = .idle
        liveOutcomes = []
    }

    /// Suit la reprise d'espace par APFS après le nettoyage (SPEC §6.2, étape 5).
    private func watchReclaim() {
        guard let boot = watch.boot, !startupReadUnverified else { return }
        let qualification = startupQualificationRevision
        Task {
            for await sample in VolumeService.watchReclaimSamples(of: boot.scanRoot) {
                self.publishReclaimedCapacity(sample.capacity, measuredAt: sample.measuredAt,
                                              for: boot, qualificationRevision: qualification)
            }
            await self.refreshVolumesInBackground()
        }
    }

    func publishReclaimedCapacity(_ capacity: Capacity, measuredAt: ContinuousClock.Instant = .now,
                                  for target: VolumeDescriptor? = nil, qualificationRevision: UInt64? = nil) {
        guard !startupReadUnverified, let current = watch.boot,
              qualificationRevision == nil || qualificationRevision == startupQualificationRevision,
              watch.updateBootCapacity(capacity, for: target ?? current, measuredAt: measuredAt) else { return }
        reclaimed = capacity
        if let index = volumes.firstIndex(where: \.isBoot),
           volumes[index].id == current.id, volumes[index].mountIdentity == current.mountIdentity {
            volumes[index].capacity = capacity
        }
    }

    // MARK: - Règles planifiées

    /// Ce qu'un passage planifié a fait partir quitte aussi l'analyse et la corbeille.
    func retentionFinished(_ report: CleanupReport) async {
        for outcome in report.outcomes where outcome.result.succeeded {
            cart.remove(outcome.itemID)
            items.removeValue(forKey: outcome.itemID)
        }
        await loadHistory()
        refreshVolumes()
        // Seulement si la fenêtre a déjà chargé l'arbre : sinon ce serait un
        // parcours complet du disque, pour une barre de menus.
        if started { disk.refresh() }
    }

    // MARK: - Entretien et navigateurs fermés

    /// Remplace des éléments par leur version fraîche (l'entretien, un navigateur
    /// qu'on vient de fermer), et les met dans la corbeille si on le demande.
    /// Jamais pendant un vide : la file en cours ne bouge pas.
    func refreshItems(_ fresh: [CleanupItem], addingToCart: Bool) {
        guard cleaning != .running else { return }
        for item in fresh {
            items[item.id] = item
            if addingToCart, canSelectForCleanup(item) { cart.insert(item.id) }
        }
    }

    // MARK: - Historique

    public func loadHistory() async {
        historyEntries = await history.load()
        restoredIDs = await history.restoredIDs()
    }

    /// Relit le journal chaque fois qu'il change : un agent qui nettoie par
    /// `oust` y écrit pendant que l'app est ouverte.
    private func watchHistory() async {
        for await _ in history.changes() {
            await loadHistory()
        }
    }

    // MARK: - Permissions

    public func recheckFullDiskAccess() {
        fullDiskAccess = FullDiskAccess.isGranted(home: home)
    }

    // MARK: - Snapshots

    private func snapshotItem(_ snapshot: LocalSnapshot) -> CleanupItem {
        var item = CleanupItem(
            id: "snapshot|\(snapshot.name)",
            title: snapshot.creationDate.map(Formatters.timestamp) ?? snapshot.name,
            detail: snapshot.name,
            paths: [],
            category: .snapshots,
            owner: "Time Machine",
            ruleID: "snapshot.time_machine",
            safety: .review,
            method: snapshot.date.map { .localSnapshot(date: $0) } ?? .manual,
            lastActivity: snapshot.creationDate,
            rebuild: .irreversible
        )
        item.measuredSnapshotBytes = snapshot.privateBytes
        if let bytes = snapshot.privateBytes { item.sizes = Sizes(private: bytes) }
        if !snapshot.isDeletable { item.protect(.systemPath) }
        return item
    }

    /// Les tailles APFS restent distinctes de l'espace purgeable du volume.
    public var cartOnlySnapshots: Bool { !cartItems.isEmpty && cartItems.allSatisfy { $0.method.isSnapshot } }
    public var cartSnapshotCount: Int { cartItems.filter { $0.method.isSnapshot }.count }
    public var cartSnapshotSizesKnown: Bool {
        cartItems.filter { $0.method.isSnapshot }.allSatisfy { $0.measuredSnapshotBytes != nil }
    }
    public var cartSnapshotIsAggregate: Bool {
        let selected = Set(cartItems.filter { $0.method.isSnapshot }.map(\.id))
        return !selected.isEmpty && selected == snapshotMeasuredIDs
            && selected == Set(deletableSnapshots.map(\.id)) && snapshotRetainedBytes != nil
    }
    public var cartSnapshotBytes: Int64? {
        let selected = cartItems.filter { $0.method.isSnapshot }
        guard !selected.isEmpty else { return 0 }
        guard selected.allSatisfy({ $0.measuredSnapshotBytes != nil }) else { return nil }
        if cartSnapshotIsAggregate { return snapshotRetainedBytes }
        return selected.reduce(0) { $0 + ($1.measuredSnapshotBytes ?? 0) }
    }
    public var snapshotEstimate: Int64 { snapshotRetainedBytes ?? 0 }
}
