import Foundation
import Observation
import OustCore
import OustRules
import OustScan
import OustVolume

/// L'arborescence du disque de démarrage, faite une fois et partagée :
/// l'Explorateur l'affiche, les règles y lisent leurs tailles, les doublons y
/// trouvent leurs candidats.
///
/// Gardée sur disque (`TreeStore`), elle s'affiche dès l'ouverture ; FSEvents dit
/// ensuite quels dossiers relire. Un parcours complet de ce Mac prend 22 s, la
/// réanalyse qui suit une seconde ou deux (mesuré le 18/10/2026).
@MainActor
@Observable
public final class DiskIndexModel {
    weak var app: AppModel?
    @ObservationIgnored let store: TreeStore
    // La jauge s'abonne via currentTree/currentScanDate : ignorer l'index
    // la laissait sur un premier résultat vide après le chargement du cache.
    private var index: ScanIndex?
    /// L'arbre partagé tel qu'il est, sans attendre de rafraîchissement (panneau des disques).
    var currentTree: TreeNode? { index?.root }
    var currentScanDate: Date? { index?.scannedAt }
    @ObservationIgnored private var refreshTask: Task<ScanIndex?, Never>?
    @ObservationIgnored private var spotlightTask: Task<Void, Never>?
    @ObservationIgnored private var runningProgress: ScanProgress?

    /// Comment s'est fait le dernier rafraîchissement, et en combien de temps.
    public private(set) var lastRefresh: IndexRefresh?
    public private(set) var lastDuration: TimeInterval?
    /// Un rafraîchissement tourne ; l'arbre affiché est le précédent.
    public private(set) var isRefreshing = false
    /// Les gros fichiers d'après Spotlight, le temps qu'un premier parcours
    /// complet se fasse. Vide dès que l'arbre existe.
    public private(set) var spotlightFiles: [SpotlightFile] = []

    /// Les réglages de l'arbre partagé : les fichiers de 100 Ko et plus un à un
    /// (onglets Types et Âge de l'Explorateur), et les marqueurs de projets
    /// retenus même petits (chercheur d'artefacts).
    static var options: ScanOptions {
        ScanOptions(leafThreshold: 100_000, notableNames: RuleEngine.notableNames)
    }

    /// Les gros fichiers montrés en attendant l'arbre : le seuil le plus bas de
    /// « Gros et vieux fichiers ».
    static let spotlightMinimum: Int64 = 10_000_000

    init(store: TreeStore = .standard()) {
        self.store = store
    }

    // MARK: Ouverture

    /// L'arbre de la dernière fois, tout de suite, puis seulement ce qui a changé.
    func start() async {
        guard let app, let boot = app.bootVolume else { return }
        let store = store
        let root = boot.scanRoot.standardizedFileURL.path
        let loaded = await Task.detached(priority: .userInitiated) { store.load(rootPath: root) }.value
        guard let loaded, index == nil, refreshTask == nil else { return }
        index = loaded
        attachExplorer()
        refresh()
    }

    // MARK: Rafraîchir

    /// L'Explorateur ouvre le disque de démarrage : l'arbre connu s'il y en a
    /// un, rafraîchi derrière ; sinon le parcours en cours, avec sa progression.
    func explore() {
        refresh()
        attachExplorer()
    }

    /// Lance un rafraîchissement, ou rejoint celui qui tourne. La tâche rend
    /// l'index à jour (ou `nil` si on l'a arrêté).
    @discardableResult
    func refresh() -> Task<ScanIndex?, Never> {
        if let refreshTask { return refreshTask }
        guard let app, let boot = app.bootVolume else { return Task { nil } }
        let previous = index
        let progress = ScanProgress()
        runningProgress = progress
        if previous == nil { findLargeFilesWithSpotlight(boot) }
        isRefreshing = true
        let store = store
        let started = Date()
        let task = Task<ScanIndex?, Never> {
            let (fresh, how) = await ScanIndex.refresh(previous, root: boot.scanRoot, options: Self.options,
                                                       progress: progress)
            self.refreshTask = nil
            self.runningProgress = nil
            self.isRefreshing = false
            guard !progress.isCancelled else { return nil }
            self.index = fresh
            self.lastRefresh = how
            self.lastDuration = Date().timeIntervalSince(started)
            self.app?.refreshVolumes()
            self.spotlightTask?.cancel()
            self.spotlightFiles = []
            self.attachExplorer()
            // Écrit en arrière-plan : la prochaine ouverture repartira d'ici.
            Task.detached(priority: .utility) { try? store.save(fresh) }
            return fresh
        }
        refreshTask = task
        attachExplorer()
        return task
    }

    /// Montre dans l'Explorateur l'arbre connu, ou la progression du premier
    /// parcours, s'il montre le disque de démarrage (ou rien encore).
    private func attachExplorer() {
        guard let app, let boot = app.bootVolume, app.treeVolume == nil || app.treeVolume?.isBoot == true else { return }
        if let index {
            app.showSharedTree(index.root, volume: boot, date: index.scannedAt)
        } else if let runningProgress {
            app.showSharedScan(volume: boot, progress: runningProgress)
        }
    }

    /// De quoi attendre l'arbre à jour depuis une autre tâche (règles, doublons).
    func treeProvider() -> @Sendable () async -> TreeNode? {
        guard app?.bootVolume != nil else { return { nil } }
        let task = refresh()
        return { await task.value?.root }
    }

    // MARK: Spotlight

    private func findLargeFilesWithSpotlight(_ boot: VolumeDescriptor) {
        spotlightTask?.cancel()
        spotlightTask = Task {
            let files = await Spotlight.largeFiles(minimumBytes: Self.spotlightMinimum, under: boot.scanRoot)
            guard !Task.isCancelled, self.index == nil else { return }
            self.spotlightFiles = files
        }
    }
}

extension AppModel {
    /// Montre l'arbre partagé dans l'Explorateur.
    func showSharedTree(_ root: TreeNode, volume: VolumeDescriptor, date: Date) {
        treeVolume = volume
        tree = root
        explorer = .done(date)
    }

    /// Le premier parcours du disque de démarrage, suivi par l'Explorateur.
    func showSharedScan(volume: VolumeDescriptor, progress: ScanProgress) {
        treeVolume = volume
        scanProgress = progress
        tree = nil
        explorer = .running
    }
}
