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
    public var preferences: Preferences {
        didSet { preferences.save() }
    }
    // Partagés avec les sections de la phase 2 : un seul journal, un seul
    // moteur, pour que deux écritures ne se croisent jamais dans le fichier.
    let history: HistoryStore
    let engine: CleanupEngine

    // MARK: Navigation

    public var section: AppSection = .overview
    /// L'onglet de la fenêtre Réglages : le dernier ouvert, ou celui où mène un lien.
    public var settingsTab: SettingsTab = .general

    // MARK: Recherche et filtres

    /// La recherche globale : nom, chemin, propriétaire, sur tout ce qui a été trouvé.
    public var searchText = ""
    /// Les filtres de chaque section, oubliés à la fermeture : un filtre resté
    /// posé d'une fois sur l'autre cacherait des éléments sans qu'on s'en souvienne.
    public var filters: [AppSection: ItemFilter] = [:]

    // MARK: Volumes

    public private(set) var volumes: [VolumeDescriptor] = [] {
        didSet { watch.updateBoot(bootVolume) }
    }
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
    public var bootVolume: VolumeDescriptor? { volumes.first(where: \.isBoot) }

    // MARK: Analyse par règles

    public internal(set) var analysis: Phase = .idle
    public internal(set) var items: [String: CleanupItem] = [:]
    public internal(set) var finishedFinders: Set<FinderKind> = []

    // MARK: Explorateur

    public internal(set) var explorer: Phase = .idle
    public internal(set) var tree: TreeNode?
    public internal(set) var treeVolume: VolumeDescriptor?
    public internal(set) var scanProgress = ScanProgress()
    var scanTask: Task<Void, Never>?
    /// L'analyse gardée de chaque autre disque, par son point de montage : relue
    /// du disque à la première demande, et non refaite à chaque ouverture
    /// (Romain, 18/10/2026).
    public internal(set) var volumeIndexes: [String: ScanIndex] = [:]

    // MARK: Disque analysé

    /// Le disque que la vue d'ensemble analyse, choisi en haut de celle-ci
    /// (demande de Romain, 18/10/2026) ; `nil` : le disque de démarrage.
    public internal(set) var analysisVolumeID: String?
    /// Quand chaque disque a été analysé par les règles, par son point de montage.
    public internal(set) var volumeAnalysisDates: [String: Date] = [:]
    /// Le disque dont l'analyse par règles tourne en ce moment.
    public internal(set) var analyzingVolumeID: String?
    /// Les destinations Time Machine branchées : jamais proposées à l'analyse.
    public internal(set) var timeMachineMounts: Set<String> = []
    /// Les disques dont l'arbre a été fait depuis leur branchement : FSEvents
    /// dit ce qui y a bougé depuis, sans qu'un autre ordinateur ait pu y écrire.
    var liveVolumeScans: Set<String> = []

    // MARK: Doublons

    public internal(set) var duplicates: Phase = .idle
    public internal(set) var duplicateGroups: [DuplicateGroup] = []
    public internal(set) var duplicateProgress = DuplicateProgress()
    /// Le disque des doublons montrés.
    public internal(set) var duplicatesVolumeID: String?
    public var duplicatesAsClones = false
    /// Les images qui se ressemblent, hors photothèque : l'onglet « Similaires ».
    public let similarImages: SimilarImagesModel

    // MARK: Navigateurs

    public private(set) var browserProfiles: [BrowserProfile] = []

    // MARK: Panier

    public internal(set) var cart: Set<String> = []

    // MARK: Nettoyage en direct

    public private(set) var cleaning: Cleaning = .idle
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

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.preferences = Preferences.load(home: home)
        let history = HistoryStore.standard()
        self.history = history
        let transit = Transit.standard()
        self.transit = transit
        self.engine = CleanupEngine(history: history, transit: transit)
        self.disk = DiskIndexModel()
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
        guard !started else { return }
        started = true
        refreshVolumes()
        // Un composant changé est signalé à l'utilisateur ; aucune opération
        // administrateur en cours dans une autre copie n'est interrompue.
        Task { await PrivilegedHelper.synchronizeApprovedInstallation() }
        // Ce qu'un lancement précédent n'a pas fini d'effacer.
        transit.resume(volumes: volumes.filter { !$0.isBoot }.map(\.mountURL))
        Task { await disk.start() }
        fullDiskAccess = FullDiskAccess.isGranted(home: home)
        await refreshSnapshots()
        await loadHistory()
        Task { await watchVolumes() }
        Task { await refreshTimeMachineMounts() }
        Task { await watchHistory() }
        Task { await keepVolumesFresh() }
    }

    public func refreshVolumes() {
        let fresh = VolumeService.mountedVolumes()
        // Relu souvent : on ne réveille l'interface que si un chiffre a bougé.
        if fresh != volumes { volumes = fresh }
    }

    /// L'espace libre bouge sans qu'Oust! le sache : des fichiers effacés dans
    /// le Finder sur un disque externe laissaient « 368 Go libres » affichés
    /// quand il y en avait 1,6 To (Romain, 18/10/2026). Relu toutes les
    /// 20 secondes hors du fil principal (un disque réseau perdu peut faire
    /// attendre `statfs`), et dès qu'Oust! revient au premier plan.
    private func keepVolumesFresh() async {
        Task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await self.refreshVolumesInBackground()
            }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            await refreshVolumesInBackground()
        }
    }

    public func refreshVolumesInBackground() async {
        let fresh = await Task.detached(priority: .utility) { VolumeService.mountedVolumes() }.value
        if fresh != volumes { volumes = fresh }
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

    private func watchVolumes() async {
        for await event in VolumeMonitor.events() {
            refreshVolumes()
            if case .unmounted(let url) = event { forgetVolume(at: url) }
            if case .mounted(let url) = event { transit.resume(volumes: [url]) }
            if case .mounted(let url) = event,
               let volume = volumes.first(where: { $0.mountURL.standardizedFileURL == url.standardizedFileURL }) {
                // Un disque de sauvegarde ne se propose pas : seul Time Machine y touche.
                await refreshTimeMachineMounts()
                if !isTimeMachine(volume) { offeredVolume = volume }
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
        analysis = .running
        analyzingVolumeID = bootVolume?.id
        finishedFinders = []
        // On ne coche d'office que la première fois pour ce disque : ce qui est
        // coché sur un disque externe ne compte pas.
        let firstTime = !cart.contains { items[$0].map { isOnBootVolume($0) } ?? false }
        // Les photos, les fichiers des nuages et les images similaires (section
        // Doublons) ne viennent pas des règles : ceux de la corbeille y restent.
        // Les éléments des autres disques restent aussi : leur analyse est à part.
        items = items.filter { $0.value.category == .snapshots || $0.value.category.section == .duplicates
            || $0.value.category.section == .photos || $0.value.category.section == .clouds
            || !isOnBootVolume($0.value) }
        // Les sections qui suivent l'arbre de l'Explorateur (gros fichiers)
        // reviennent au disque de démarrage.
        if let boot = bootVolume, treeVolume?.isBoot == false, !explorer.isRunning { explore(boot) }
        var context = RuleContext(home: home, projectRoots: preferences.projectRoots,
                                  historyRetentionDays: preferences.historyRetentionDays,
                                  compressionAgeDays: preferences.compressionAgeMonths * 30)
        // Une seule passe : les chercheurs démarrent tout de suite, et lisent les
        // tailles dans l'arbre partagé (rafraîchi par FSEvents) au lieu de
        // remesurer chaque élément sur le disque.
        let tree = disk.treeProvider()
        context.tree = tree
        let policy = PreselectionPolicy(recencyDays: preferences.recencyDays)

        refreshBrowsers()
        for await batch in RuleEngine.run(context, measurer: .tree(tree)) {
            for item in batch.items {
                items[item.id] = item
                // On ne coche d'office que la première fois, et que le sûr.
                if firstTime, policy.preselects(item) { cart.insert(item.id) }
            }
            finishedFinders.insert(batch.finder)
        }
        cart = cart.filter { items[$0]?.isSelectable == true }
        await refreshSnapshots()
        refreshVolumes()
        if let boot = bootVolume { volumeAnalysisDates[boot.id] = Date() }
        analyzingVolumeID = nil
        analysis = .done(Date())
    }

    public func refreshBrowsers() {
        browserProfiles = BrowserFinder.profiles(home: home)
        for profile in browserProfiles {
            let running = BrowserFinder.isRunning(profile.browser)
            for item in BrowserFinder.items(for: profile, isRunning: running) {
                items[item.id] = items[item.id].map { old in var fresh = item; fresh.sizes = old.sizes; return fresh } ?? item
            }
        }
        // Les tailles des caches de navigateurs, mesurées à part.
        let browserItems = items.values.filter { $0.category == .browsers }
        Task {
            let paths = browserItems.flatMap(\.paths)
            let measures = await Scanner.measure(paths)
            for item in browserItems {
                let size = item.paths.compactMap { measures[$0]?.sizes }.total()
                self.items[item.id]?.sizes = size
            }
        }
    }

    /// Les éléments d'une section, triés du plus libérable au moins. Ceux des
    /// sections qui portent sur un disque (Développement, Système, Doublons)
    /// sont ceux du disque choisi dans la vue d'ensemble.
    public func items(in categories: Set<ItemCategory>) -> [CleanupItem] {
        let scope = itemScope()
        return orderedForDisplay(items.values.filter { categories.contains($0.category) && scope($0) })
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
        return orderedForDisplay(items.values.filter(filter.matchesQuery))
    }

    public var isSearching: Bool { ItemFilter(query: searchText).isActive }

    public func total(of categories: Set<ItemCategory>, headlineOnly: Bool = true) -> Int64 {
        let scope = itemScope()
        return items.values.filter { categories.contains($0.category) && (!headlineOnly || $0.countsInHeadline)
            && $0.isSelectable && scope($0) }
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
        // Le disque de démarrage : l'arbre partagé, gardé d'une fois sur l'autre.
        if volume.isBoot {
            if treeVolume?.isBoot != true {
                scanTask?.cancel()
                scanProgress.cancel()
                treeVolume = nil
                tree = nil
            }
            disk.explore()
            return
        }
        // Le parcours partagé continue sans l'Explorateur : les règles
        // l'attendent peut-être.
        if treeVolume?.isBoot != true {
            scanTask?.cancel()
            scanProgress.cancel()
        }
        let progress = ScanProgress()
        scanProgress = progress
        treeVolume = volume
        tree = nil
        explorer = .running
        // Gardé seulement pour un disque monté, pas pour un dossier choisi ; sur
        // le disque seulement s'il a un UUID.
        let isMounted = volumes.contains { $0.id == volume.id }
        let store = isMounted ? Self.volumeStore(for: volume) : nil
        scanTask = Task {
            if !rescan, let known = await self.storedAnalysis(for: volume) {
                guard !progress.isCancelled, self.treeVolume?.id == volume.id else { return }
                self.tree = known.root
                self.explorer = .done(known.scannedAt)
                return
            }
            // Les fichiers de 100 Ko et plus sont gardés un à un : assez pour que
            // les onglets Types et Âge de l'Explorateur portent sur l'essentiel
            // des octets, sans un nœud par fichier sur un disque de 5 millions.
            // Un parcours complet, sauf si l'arbre a été fait depuis que le
            // disque est branché : avant, il a pu changer sur un autre
            // ordinateur, sans que les événements de ce Mac le sachent.
            // Les mêmes réglages que l'arbre partagé, et de quoi trouver les
            // traces de macOS : les règles du disque y lisent leurs marqueurs.
            let options = Self.volumeScanOptions(for: volume)
            let (fresh, _) = await ScanIndex.refresh(previous, root: volume.scanRoot, options: options, progress: progress)
            guard !progress.isCancelled else { return }
            await self.refreshVolumesInBackground()
            if isMounted {
                self.volumeIndexes[volume.id] = fresh
                self.liveVolumeScans.insert(volume.id)
            }
            self.tree = fresh.root
            self.explorer = .done(fresh.scannedAt)
            if let store { Task.detached(priority: .utility) { try? store.save(fresh) } }
        }
    }

    public func explore(folder: URL) {
        let name = folder.lastPathComponent
        let capacity = VolumeService.capacity(of: folder) ?? Capacity(total: 0, available: 0, availableForImportantUsage: 0)
        explore(VolumeDescriptor(name: name, mountURL: folder, scanRoot: folder, isBoot: false, isInternal: true,
                                 isRemovable: false, capacity: capacity))
    }

    public func cancelExploration() {
        scanProgress.cancel()
        scanTask?.cancel()
        explorer = tree == nil ? .idle : .done(Date())
    }

    /// Un nœud de l'arborescence comme élément du panier. Si une règle connaît ce
    /// chemin, c'est son élément (et sa méthode) qui sert.
    public func item(for node: TreeNode) -> CleanupItem {
        let path = PathNormalizer.normalize(node.path)
        if let known = items.values.first(where: { $0.paths.count == 1 && PathNormalizer.normalize($0.paths[0].path) == path }) {
            return known
        }
        return explorerItem(url: URL(fileURLWithPath: path), title: node.name, sizes: node.total,
                            modified: node.latestModification)
    }

    public func item(for file: FileLeaf, in node: TreeNode) -> CleanupItem {
        let url = URL(fileURLWithPath: PathNormalizer.normalize(node.path)).appendingPathComponent(file.name)
        return explorerItem(url: url, title: file.name, sizes: file.sizes, modified: file.modified)
    }

    private func explorerItem(url: URL, title: String, sizes: Sizes, modified: Date?) -> CleanupItem {
        var item = CleanupItem(id: "explorer|\(url.path)", title: title, detail: url.deletingLastPathComponent().path,
                               paths: [url], category: .explorer, owner: treeVolume?.name ?? "",
                               ruleID: "explorer.item", safety: .review, method: .trash, sizes: sizes,
                               lastActivity: modified, rebuild: .irreversible,
                               fingerprint: Fingerprint(modificationDate: nil, fileID: nil))
        if !PathGuard(home: home).allows(url) { item.protect(.systemPath) }
        if let volume = treeVolume, isTimeMachine(volume) { item.protect(.timeMachine) }
        return item
    }

    // MARK: - Doublons

    public func findDuplicates(in roots: [URL]? = nil) async {
        guard !duplicates.isRunning else { return }
        // Sur un autre disque choisi dans la vue d'ensemble : ce disque seul.
        if roots == nil, let volume = analyzedVolume, !volume.isBoot {
            await findDuplicates(on: volume)
            return
        }
        duplicates = .running
        let progress = DuplicateProgress()
        duplicateProgress = progress
        var options = DuplicateOptions.standard(home: home)
        if let roots { options.roots = roots }
        options.minimumSize = Int64(preferences.duplicateMinimumMegabytes) * 1_000_000
        // Les candidats viennent des feuilles de l'arbre partagé, sans
        // reparcourir le dossier personnel.
        let tree = await disk.treeProvider()()
        let groups = await DuplicateFinder.find(options, tree: tree, progress: progress)
        showDuplicates(groups, volume: bootVolume)
    }

    /// Les groupes trouvés sur un disque remplacent ceux de ce disque ; ce qui a
    /// été coché sur un autre disque reste dans la corbeille.
    func showDuplicates(_ groups: [DuplicateGroup], volume: VolumeDescriptor?) {
        duplicateGroups = groups
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
        guard let keep = chosen ?? duplicateKeep(group) ?? group.files.indices.first(where: { $0 != index }), keep != index
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

    public func toggle(_ item: CleanupItem) {
        guard item.isSelectable else { return }
        if cart.contains(item.id) {
            cart.remove(item.id)
        } else {
            items[item.id] = items[item.id] ?? item
            cart.insert(item.id)
        }
    }

    public func add(_ newItems: [CleanupItem]) {
        for item in newItems where item.isSelectable {
            items[item.id] = items[item.id] ?? item
            cart.insert(item.id)
        }
    }

    public func remove(_ ids: [String]) {
        cart.subtract(ids)
    }

    public func clearCart() { cart.removeAll() }

    public var cartItems: [CleanupItem] {
        orderedForDisplay(cart.compactMap { items[$0] })
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

    func startCleaning(_ queue: [CleanupItem]) {
        guard cleaning != .running, !queue.isEmpty else { return }
        liveQueue = queue
        liveOutcomes = []
        freedSoFar = 0
        currentItemID = nil
        currentItemIDs = []
        cleanupProgress = CleanupProgress(total: queue.filter(\.isSelectable).count)
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
        guard let boot = bootVolume else { return }
        Task {
            for await capacity in VolumeService.watchReclaim(of: boot.scanRoot) {
                self.reclaimed = capacity
                if let index = self.volumes.firstIndex(where: \.isBoot) { self.volumes[index].capacity = capacity }
            }
            self.refreshVolumes()
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
            if addingToCart, item.isSelectable { cart.insert(item.id) }
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

    public func restore(_ outcome: CleanupOutcome) async -> Bool {
        do {
            try await history.restore(outcome)
            await loadHistory()
            return true
        } catch {
            return false
        }
    }

    public func canRestore(_ outcome: CleanupOutcome) -> Bool {
        outcome.result == .trashed && !restoredIDs.contains(outcome.id)
            && outcome.trashedTo.allSatisfy { FileManager.default.fileExists(atPath: $0) }
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
