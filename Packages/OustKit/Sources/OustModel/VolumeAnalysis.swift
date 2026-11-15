import Foundation
import OustCore
import OustDuplicates
import OustLocalization
import OustRules
import OustSafety
import OustScan
import OustVolume
import OustWatch

/// Analyser un autre disque comme on analyse le disque de démarrage (demande
/// de Romain, 18/10/2026 : « le second peut avoir des applications, des
/// fichiers, des doublons, des photos… »).
///
/// Le disque se choisit en haut de la vue d'ensemble. Les éléments de chaque
/// disque vivent côte à côte dans `items` ; les sections qui portent sur un
/// disque (Développement, Système, Doublons, Gros fichiers, Explorateur) ne
/// montrent que ceux du disque choisi. La corbeille d'Oust!, elle, garde tout
/// ce qu'on y a jeté, d'où que ce soit.
extension AppModel {

    /// Les sections dont les éléments sont ceux du disque choisi.
    static let volumeScopedSections: Set<AppSection> = [.developer, .system, .duplicates, .explorer, .largeFiles]

    /// Les règles d'un disque dont l'élément n'a pas de nom propre : son titre
    /// est celui de la règle, traduit.
    static let titledByRule: Set<String> = ["volume.appledouble", "volume.appledouble_orphan", "volume.ds_store"]

    /// Les catégories que l'analyse d'un autre disque remplit, et qu'elle vide
    /// avant de recommencer.
    static let volumeCategories: Set<ItemCategory> = [
        .projectArtifacts, .creative, .games, .systemDownloads, .trash, .diskTraces, .virtualMachines, .protectedOnDisk,
    ]

    // MARK: Le disque choisi

    /// Le disque que la vue d'ensemble analyse : celui qu'on a choisi s'il est
    /// encore branché, sinon le disque de démarrage.
    public var analyzedVolume: VolumeDescriptor? {
        if let analysisVolumeID, let chosen = volumes.first(where: { $0.id == analysisVolumeID }) { return chosen }
        return bootVolume
    }

    /// Choisit le disque à analyser. Les résultats d'un disque déjà analysé
    /// reviennent tels quels ; rien n'est relu tant qu'on n'a pas demandé
    /// « Analyser ».
    public func selectAnalysisVolume(_ volume: VolumeDescriptor) {
        guard !isTimeMachine(volume) else { return }
        analysisVolumeID = volume.isBoot ? nil : volume.id
        // Les gros fichiers suivent l'arbre de l'Explorateur : celui du disque
        // de démarrage est toujours là, celui d'un autre disque après son analyse.
        if volume.isBoot, treeVolume?.isBoot == false, !explorer.isRunning { explore(volume) }
        if !volume.isBoot, let index = volumeIndexes[volume.id], treeVolume?.id != volume.id, !explorer.isRunning {
            treeVolume = volume
            tree = index.root
            explorer = .done(index.scannedAt)
        }
    }

    /// Choisit ce disque et l'analyse (un disque qu'on vient de brancher).
    public func analyze(_ volume: VolumeDescriptor) async {
        guard !isTimeMachine(volume) else { return }
        selectAnalysisVolume(volume)
        await analyze()
    }

    /// Où en est l'analyse d'un disque.
    public func analysisPhase(for volume: VolumeDescriptor) -> Phase {
        if analysis.isRunning, analyzingVolumeID == volume.id { return .running }
        if let date = volumeAnalysisDates[volume.id] { return .done(date) }
        return .idle
    }

    /// Où en est l'analyse du disque choisi.
    public var currentAnalysis: Phase {
        analyzedVolume.map(analysisPhase(for:)) ?? analysis
    }

    /// Une destination Time Machine : jamais analysée, rien n'y est proposé.
    public func isTimeMachine(_ volume: VolumeDescriptor) -> Bool {
        !volume.isBoot && timeMachineMounts.contains(PathNormalizer.normalize(volume.mountURL.standardizedFileURL.path))
    }

    /// Un disque en lecture seule (NTFS, image verrouillée) : on le montre, rien n'en part.
    public func isReadOnly(_ volume: VolumeDescriptor) -> Bool {
        !volume.isBoot && VolumeService.facts(of: volume.mountURL)?.isReadOnly == true
    }

    /// Ce que la corbeille d'Oust! rendrait sur ce disque.
    public func cartTotal(on volume: VolumeDescriptor) -> Int64 {
        let regular = cartItems.filter { !$0.method.isSnapshot && belongs($0, to: volume) }
            .reduce(0) { $0 + $1.sizes.freeable }
        return regular + (volume.isBoot ? (cartSnapshotBytes ?? 0) : 0)
    }

    // MARK: À quel disque appartient un élément

    /// Les points de montage des autres disques que celui de démarrage.
    private var otherVolumeRoots: [String] {
        volumes.filter { !$0.isBoot }.map { PathNormalizer.normalize($0.mountURL.standardizedFileURL.path) }
    }

    private static func isUnder(_ item: CleanupItem, _ roots: [String]) -> Bool {
        guard let first = item.paths.first else { return false }
        let path = PathNormalizer.normalize(first.standardizedFileURL.path)
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Sur le disque de démarrage : hors de tout autre disque. Un élément sans
    /// chemin (snapshot) y est aussi.
    public func isOnBootVolume(_ item: CleanupItem) -> Bool {
        !Self.isUnder(item, otherVolumeRoots)
    }

    func belongs(_ item: CleanupItem, to volume: VolumeDescriptor) -> Bool {
        if volume.isBoot { return isOnBootVolume(item) }
        return Self.isUnder(item, [PathNormalizer.normalize(volume.mountURL.standardizedFileURL.path)])
    }

    /// Le filtre des sections qui portent sur un disque, calculé une fois par liste.
    func itemScope() -> (CleanupItem) -> Bool {
        let others = otherVolumeRoots
        guard let volume = analyzedVolume, !others.isEmpty else { return { _ in true } }
        let scoped = Self.volumeScopedSections
        if volume.isBoot {
            return { !scoped.contains($0.category.section) || !Self.isUnder($0, others) }
        }
        let root = [PathNormalizer.normalize(volume.mountURL.standardizedFileURL.path)]
        return { !scoped.contains($0.category.section) || Self.isUnder($0, root) }
    }

    // MARK: Analyse d'un autre disque

    /// Les chercheurs qui ont un sens sur un disque (`FinderKind.volumeFinders`),
    /// sur l'arbre de l'Explorateur : fait pour l'occasion, ou mis à jour par
    /// FSEvents s'il date du branchement du disque.
    func analyzeOtherVolume(_ volume: VolumeDescriptor) async {
        guard !isTimeMachine(volume) else { return }
        analysis = .running
        analyzingVolumeID = volume.id
        finishedFinders = []
        let firstTime = !cart.contains { items[$0].map { belongs($0, to: volume) } ?? false }
        items = items.filter { !Self.volumeCategories.contains($0.value.category) || !belongs($0.value, to: volume) }

        let facts = VolumeService.facts(of: volume.scanRoot)
        let scope = VolumeScope(root: volume.scanRoot, name: volume.name, fileSystem: facts?.fileSystem ?? "",
                                isReadOnly: facts?.isReadOnly ?? false)
        let root = await volumeIndexForAnalysis(volume)?.root
        let context = RuleContext(home: home, historyRetentionDays: preferences.historyRetentionDays,
                                  compressionAgeDays: preferences.compressionAgeMonths * 30,
                                  tree: { root }, volume: scope)
        let policy = PreselectionPolicy(recencyDays: preferences.recencyDays)
        for await batch in RuleEngine.run(context, finders: FinderKind.volumeFinders, measurer: .tree { root }) {
            for var item in batch.items {
                if Self.titledByRule.contains(item.ruleID) { item.title = L10n.string("rule.\(item.ruleID).title") }
                recordAnalyzedItem(item, preselect: firstTime, policy: policy)
            }
            finishedFinders.insert(batch.finder)
        }
        cart = cart.filter { items[$0].map(canSelectForCleanup) == true }
        refreshVolumes()
        volumeAnalysisDates[volume.id] = Date()
        analyzingVolumeID = nil
        analysis = .done(Date())
    }

    /// L'arbre du disque à jour, montré dans l'Explorateur pendant qu'il se fait.
    /// `nil` si on l'a arrêté (l'Explorateur est passé à un autre disque) : les
    /// chercheurs relisent alors le disque eux-mêmes.
    func volumeIndexForAnalysis(_ volume: VolumeDescriptor) async -> ScanIndex? {
        let options = Self.volumeScanOptions(for: volume)
        let started = Date()
        var previous = liveVolumeScans.contains(volume.id) ? volumeIndexes[volume.id] : nil
        if let known = previous, !Self.describeSameTree(known.options, options) { previous = nil }
        explore(volume, rescan: true, previous: previous)
        await scanTask?.value
        guard let index = volumeIndexes[volume.id], index.scannedAt >= started else { return nil }
        return index
    }

    /// Les réglages du parcours d'un autre disque : ceux de l'arbre partagé, ses
    /// sauvegardes Time Machine jamais ouvertes (des liens physiques de
    /// dossiers, comptés une fois par sauvegarde), et sur un système de
    /// fichiers qui n'est pas celui de macOS, ses traces retenues par leur nom.
    nonisolated static func volumeScanOptions(for volume: VolumeDescriptor) -> ScanOptions {
        let fileSystem = VolumeService.facts(of: volume.scanRoot)?.fileSystem ?? "apfs"
        let backups = volume.scanRoot.appendingPathComponent(VolumeProtection.timeMachineFolder).standardizedFileURL.path
        let excluded: Set<String> = FileManager.default.fileExists(atPath: backups) ? [backups] : []
        return ScanOptions(leafThreshold: 100_000, excludedPaths: excluded,
                           notableNames: RuleEngine.notableNames(fileSystem: fileSystem))
    }

    nonisolated static func describeSameTree(_ lhs: ScanOptions, _ rhs: ScanOptions) -> Bool {
        lhs.leafThreshold == rhs.leafThreshold && lhs.measurePrivateSizes == rhs.measurePrivateSizes
            && lhs.excludedPaths == rhs.excludedPaths && lhs.notableNames == rhs.notableNames
    }

    // MARK: Doublons d'un autre disque

    /// Les doublons montrés sont ceux du disque choisi.
    public var duplicatesMatchAnalyzedVolume: Bool {
        duplicatesVolumeID == nil || duplicatesVolumeID == analyzedVolume?.id
    }

    /// Les doublons de ce disque seul, sur son arbre : jamais d'un disque à
    /// l'autre, et jamais sans l'arbre, qui garantit qu'on ne quitte pas le
    /// volume (RULES.md, règle 10).
    func findDuplicates(on volume: VolumeDescriptor) async {
        let session = duplicateReadSession
        guard session.acquire() else { return }
        defer { session.release() }
        duplicates = .running
        let progress = DuplicateProgress()
        duplicateProgress = progress
        // À jour : par FSEvents si l'arbre date du branchement, en entier sinon.
        let revision = duplicateExclusionRevision
        guard canSearchDuplicates([volume.scanRoot]) else { return }
        let tree = await volumeIndexForAnalysis(volume)?.root
        guard revision == duplicateExclusionRevision else { return }
        guard let tree else {
            duplicates = .idle
            return
        }
        var options = DuplicateOptions(roots: [volume.scanRoot])
        options.minimumSize = Int64(preferences.duplicateMinimumMegabytes) * 1_000_000
        options.exclusions = preferences.duplicateExclusions
        let groups = await DuplicateFinder.find(options, tree: tree, progress: progress)
        guard revision == duplicateExclusionRevision, canSearchDuplicates(options.roots) else { return }
        showDuplicates(groups, volume: volume)
    }

    // MARK: Branchements

    /// Un disque débranché : ses éléments quittent l'analyse et la corbeille
    /// d'Oust! (rien ne pourrait plus en partir), son arbre en mémoire aussi (un
    /// autre disque peut se monter au même endroit).
    func forgetVolume(at url: URL) {
        let root = PathNormalizer.normalize(url.standardizedFileURL.path)
        let gone = items.values.filter { item in
            item.paths.first.map { PathNormalizer.isWithin($0.path, root) } ?? false
        }.map(\.id)
        for id in gone { items.removeValue(forKey: id) }
        cart.subtract(gone)
        let id = url.standardizedFileURL.path
        if analysisVolumeID.map(PathNormalizer.normalize) == root { analysisVolumeID = nil }
        volumeAnalysisDates.removeValue(forKey: id)
        volumeIndexes.removeValue(forKey: id)
        liveVolumeScans.remove(id)
        timeMachineMounts.remove(root)
        if duplicatesVolumeID == id {
            duplicateGroups = []
            duplicatesVolumeID = nil
            duplicates = .idle
        }
    }

    /// Les destinations Time Machine branchées : celles que `tmutil` connaît, et
    /// les disques qui en portent les marques (une sauvegarde APFS d'un autre Mac).
    func refreshTimeMachineMounts() async {
        let result = await Command.run("/usr/bin/tmutil", ["destinationinfo", "-X"], timeout: 10)
        var mounts = result.succeeded ? WatchedVolumes.timeMachineMountPoints(in: result.stdout) : []
        let roots = volumes.filter { !$0.isBoot }.map(\.mountURL)
        let marked = await Task.detached(priority: .utility) {
            roots.filter(VolumeProtection.looksLikeTimeMachineVolume).map(\.path)
        }.value
        mounts.formUnion(marked)
        timeMachineMounts = Set(mounts.map(PathNormalizer.normalize))
        if let volume = analyzedVolume, isTimeMachine(volume) { analysisVolumeID = nil }
    }
}
