import Darwin
import Foundation
import OustCore
import OustDuplicates
import OustLocalization
import OustRules
import OustSafety
import OustScan
import OustVolume
import OustWatch
import Synchronization

private let timeMachineProbes = Mutex(Set<URL>())

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
    @discardableResult
    public func selectAnalysisVolume(_ volume: VolumeDescriptor) -> Task<Void, Never>? {
        guard canAnalyzeVolume(volume) else { return nil }
        analysisVolumeGainCheck?.cancel()
        analysisVolumeGainCheck = nil
        analysisVolumeID = volume.isBoot ? nil : volume.id
        // Les gros fichiers suivent l'arbre de l'Explorateur : celui du disque
        // de démarrage est toujours là, celui d'un autre disque après son analyse.
        guard !explorer.isRunning else { return nil }
        let check: Task<Void, Never>
        if volume.isBoot {
            if treeVolume?.isBoot == false {
                explore(volume)
                return nil
            } else {
                check = Task { await revalidateExplorerGains() }
            }
        } else if let index = volumeIndexes[volume.id] {
            let initial = tree
            let home = home
            check = Task {
                guard let admitted = await resolveAnalysisRoots([volume.scanRoot]),
                      let root = admitted.directories.first else { return }
                let savedBinding = index.options.boundRootIdentity
                guard savedBinding == nil || savedBinding == root.identity else { return }
                let checked = await checkStorageIO {
                    var options = Self.volumeScanOptions(for: volume, home: home)
                    options.boundRootIdentity = savedBinding
                    return index.checkedForDisplay(for: options)
                }
                guard !Task.isCancelled else { return }
                let displayed: ScanIndex
                if let checked { displayed = checked }
                else { displayed = await storageIO { index.withholdingGains() } }
                guard await resolveAnalysisRoots([volume.scanRoot]) == admitted,
                      !Task.isCancelled, canAnalyzeVolume(volume), analysisVolumeID == volume.id,
                      tree === initial, volumeIndexes[volume.id]?.root === index.root else { return }
                showExplorerIndex(displayed, volume: volume)
            }
        } else {
            return nil
        }
        analysisVolumeGainCheck = check
        return check
    }

    /// Choisit ce disque et l'analyse (un disque qu'on vient de brancher).
    public func analyze(_ volume: VolumeDescriptor) async {
        guard canAnalyzeVolume(volume) else { return }
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

    public func canAnalyzeVolume(_ volume: VolumeDescriptor) -> Bool {
        if volume.isBoot { return true }
        if isTimeMachine(volume) { return false }
        let path = PathNormalizer.normalize(volume.mountURL.standardizedFileURL.path)
        guard !unresolvedMounts.contains(path) else { return false }
        if let current = volumes.first(where: { PathNormalizer.normalize($0.mountURL.standardizedFileURL.path) == path }),
           let identity = current.mountIdentity {
            return volume.mountIdentity == identity && confirmedOrdinaryMounts[path] == identity
        }
        return volume.mountIdentity == nil && canAnalyzePath(volume.mountURL)
    }

    func canAnalyzePath(_ url: URL) -> Bool {
        let path = PathNormalizer.normalize(url.standardizedFileURL.path)
        guard !unresolvedMounts.contains(where: { PathNormalizer.isWithin(path, $0) }),
              !pendingTimeMachineMounts.contains(where: { PathNormalizer.isWithin(path, $0) }),
              !timeMachineMounts.contains(where: { PathNormalizer.isWithin(path, $0) }) else { return false }
        return volumes.allSatisfy { volume in
            guard !volume.isBoot, volume.mountIdentity != nil,
                  PathNormalizer.isWithin(path, PathNormalizer.normalize(volume.mountURL.standardizedFileURL.path))
            else { return true }
            return canAnalyzeVolume(volume)
        }
    }

    struct AnalysisRoots: Equatable {
        struct Stamp: Equatable {
            let urls: [URL]
            let identities: [AnalysisRoot.Identity]
            let mountGeneration: Int
        }

        let directories: [AnalysisRoot]
        let mountGeneration: Int
        var urls: [URL] { directories.map(\.url) }
        var stamp: Stamp { Stamp(urls: urls, identities: directories.map(\.identity), mountGeneration: mountGeneration) }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.stamp == rhs.stamp
        }
    }

    func resolveAnalysisRoots(_ roots: [URL], reader: DuplicateReadSession.Reader? = nil) async -> AnalysisRoots? {
        guard !Task.isCancelled, !roots.isEmpty, roots.allSatisfy(canAnalyzePath) else { return nil }
        let generation = mountGeneration
        let mounted = volumes.filter { !$0.isBoot && $0.mountIdentity != nil }
        var approved: [String: [Int32]] = [:]
        for volume in mounted where canAnalyzeVolume(volume) {
            approved[PathNormalizer.normalize(volume.mountURL.path)] = volume.mountIdentity?.filesystemID
        }
        let initialBlocked = blockedAnalysisMounts()
        let allowedMounts = approved
        let checked = await checkStorageIO { () -> [AnalysisRoot]? in
            defer { withExtendedLifetime(reader) {} }
            guard let table = MountedFileSystems.read() else { return nil }
            let unknown = Set(table.filter(\.isExternalCandidate).compactMap { entry in
                let path = PathNormalizer.normalize(entry.path)
                return allowedMounts[path] == entry.identity ? nil : path
            })
            let blocked = initialBlocked.union(unknown)
            var directories: [AnalysisRoot] = []
            for root in roots {
                guard let path = realpath(root.path, nil) else { return nil }
                defer { free(path) }
                guard let value = String(validatingCString: path) else { return nil }
                let url = URL(fileURLWithPath: value, isDirectory: true)
                guard !Self.overlapsBlockedAnalysisMount(value, mounts: blocked) else { return nil }
                guard let directory = AnalysisRoot(url), table.contains(where: {
                    $0.identity == directory.identity.filesystem && (!$0.isExternalCandidate
                        || allowedMounts[PathNormalizer.normalize($0.path)] == $0.identity)
                }) else { return nil }
                directories.append(directory)
            }
            for volume in mounted {
                let mountPath = PathNormalizer.normalize(volume.mountURL.standardizedFileURL.path)
                guard directories.contains(where: {
                    let path = PathNormalizer.normalize($0.url.path)
                    return PathNormalizer.isWithin(path, mountPath) || PathNormalizer.isWithin(mountPath, path)
                }) else { continue }
                guard VolumeService.mountIdentity(of: volume.mountURL) == volume.mountIdentity else { return nil }
            }
            return directories
        }
        guard !Task.isCancelled, generation == mountGeneration, let directories = checked ?? nil else { return nil }
        let resolved = directories.map(\.url)
        guard (roots + resolved).allSatisfy(canAnalyzePath) else { return nil }
        // Une racine englobante, par exemple /Volumes, ne doit pas contourner
        // le veto d’un des volumes sous-jacents.
        let blocked = blockedAnalysisMounts()
        guard !resolved.contains(where: { root in
            Self.overlapsBlockedAnalysisMount(root.path, mounts: blocked)
        }) else { return nil }
        return AnalysisRoots(directories: directories, mountGeneration: generation)
    }

    private func blockedAnalysisMounts() -> Set<String> {
        timeMachineMounts.union(pendingTimeMachineMounts).union(unresolvedMounts).union(volumes.compactMap {
            canAnalyzeVolume($0) ? nil : PathNormalizer.normalize($0.mountURL.standardizedFileURL.path)
        })
    }

    private nonisolated static func overlapsBlockedAnalysisMount(_ path: String, mounts: Set<String>) -> Bool {
        mounts.contains { PathNormalizer.isWithin(path, $0) || PathNormalizer.isWithin($0, path) }
    }

    /// Un disque en lecture seule (NTFS, image verrouillée) : on le montre, rien n'en part.
    public func isReadOnly(_ volume: VolumeDescriptor) -> Bool {
        !volume.isBoot && volume.mountedReadOnly != false
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
    func analyzeOtherVolume(_ volume: VolumeDescriptor, storageGate: StorageTaskGate = .sharedVolumeAnalysis,
                            timeout: Duration = .seconds(15)) async {
        guard !analysis.isRunning, volumeAnalysisAttempt == nil, canAnalyzeVolume(volume) else { return }
        let attempt = UUID()
        volumeAnalysisAttempt = attempt
        analysis = .running
        analyzingVolumeID = volume.id
        defer {
            if volumeAnalysisAttempt == attempt {
                volumeAnalysisAttempt = nil
                analyzingVolumeID = nil
                if analysis.isRunning { analysis = .idle }
            }
        }
        _ = await storageGate.run(timeout: timeout) { [self] in
            await analyzeOtherVolumeWithinStorageOperation(volume, attempt: attempt)
        }
    }

    private func analyzeOtherVolumeWithinStorageOperation(_ volume: VolumeDescriptor, attempt: UUID) async {
        guard ownsVolumeAnalysis(volume, attempt: attempt), canAnalyzeVolume(volume) else { return }
        if let identity = volume.mountIdentity {
            let root = volume.mountURL
            let matches = await checkStorageIO { VolumeService.mountIdentity(of: root) == identity }
            guard matches == true, ownsVolumeAnalysis(volume, attempt: attempt), canAnalyzeVolume(volume) else { return }
        }
        let requested = [volume.scanRoot]
        guard ownsVolumeAnalysis(volume, attempt: attempt), let admitted = await resolveAnalysisRoots(requested),
              let anchor = admitted.directories.first, ownsVolumeAnalysis(volume, attempt: attempt),
              canAnalyzeVolume(volume) else { return }
        var completed = false
        defer {
            if volumeAnalysisAttempt == attempt {
                volumeAnalysisAttempt = nil
                analyzingVolumeID = nil
                analysis = completed ? .done(Date()) : .idle
            }
        }
        guard let index = await volumeIndexForAnalysis(volume), index.options.boundRootIdentity == anchor.identity,
              await resolveAnalysisRoots(requested) == admitted, analyzingVolumeID == volume.id,
              canAnalyzeVolume(volume),
              let reviewLocation = await checkStorageIO({ AnalysisReview.Location(anchor.url) }) ?? nil,
              ownsVolumeAnalysis(volume, attempt: attempt) else { return }
        var stagedBatches: [RuleBatch] = []
        var stagedFinders: Set<FinderKind> = []

        let scope = VolumeScope(root: anchor.url, name: volume.name, fileSystem: volume.mountedFileSystem ?? "",
                                isReadOnly: isReadOnly(volume))
        let root = index.root
        var context = RuleContext(home: home, historyRetentionDays: preferences.historyRetentionDays,
                                  compressionAgeDays: preferences.compressionAgeMonths * 30, tree: { root }, volume: scope)
        context.volume?.root = anchor.url
        context.volumeAnchor = anchor
        context.volumeScanOptions = index.options
        context.projectRoots = [anchor.url]
        let operation = RuleEngine.runWithinStorageOperation(context, finders: FinderKind.volumeFinders)
        let accepted = await withTaskCancellationHandler { @MainActor in
            for await batch in operation.batches {
                guard await resolveAnalysisRoots(requested) == admitted,
                      ownsVolumeAnalysis(volume, attempt: attempt), canAnalyzeVolume(volume) else { return false }
                stagedBatches.append(batch)
                stagedFinders.insert(batch.finder)
                StorageOperationContext.reportProgress()
            }
            return !Task.isCancelled
        } onCancel: {
            operation.completion.cancel()
        }
        operation.completion.cancel()
        await operation.completion.value
        guard accepted, ownsVolumeAnalysis(volume, attempt: attempt),
              Set(FinderKind.volumeFinders).isSubset(of: stagedFinders),
              await resolveAnalysisRoots(requested) == admitted,
              ownsVolumeAnalysis(volume, attempt: attempt) else { return }
        let batches = stagedBatches
        let generation = mountGeneration
        guard let freshItems = await checkStorageIO({
            let fresh = batches.flatMap { $0.revalidatedItems() }
            guard let current = AnalysisRoot(anchor.url), current.identity == anchor.identity,
                  reviewLocation.matches(anchor.url) else { return nil as [CleanupItem]? }
            return fresh
        }) ?? nil,
              generation == mountGeneration, ownsVolumeAnalysis(volume, attempt: attempt),
              canAnalyzeVolume(volume) else { return }
        let firstTime = !cart.contains { items[$0].map { belongs($0, to: volume) } ?? false }
        let policy = PreselectionPolicy(recencyDays: preferences.recencyDays)
        var reviewIDs = Set<String>()
        items = items.filter { !Self.volumeCategories.contains($0.value.category) || !belongs($0.value, to: volume) }
        for var item in freshItems {
            if Self.titledByRule.contains(item.ruleID) { item.title = L10n.string("rule.\(item.ruleID).title") }
            recordAnalyzedItem(item, preselect: firstTime, policy: policy)
            reviewIDs.insert(item.id)
        }
        finishedFinders = stagedFinders
        cart = cart.filter { items[$0].map(canSelectForCleanup) == true }
        saveAnalysisReview(for: volume, location: reviewLocation, ids: reviewIDs, locationWasVerified: true)
        volumeAnalysisDates[volume.id] = Date()
        StorageOperationContext.withUnboundContext { refreshVolumes() }
        completed = true
    }

    private func ownsVolumeAnalysis(_ volume: VolumeDescriptor, attempt: UUID) -> Bool {
        !Task.isCancelled && volumeAnalysisAttempt == attempt && analyzingVolumeID == volume.id && analysis.isRunning
    }

    /// L'arbre du disque à jour, montré dans l'Explorateur pendant qu'il se fait.
    /// `nil` si on l'a arrêté (l'Explorateur est passé à un autre disque).
    func volumeIndexForAnalysis(_ volume: VolumeDescriptor) async -> ScanIndex? {
        guard canAnalyzeVolume(volume) else { return nil }
        let started = Date()
        let previous = liveVolumeScans.contains(volume.id) ? volumeIndexes[volume.id] : nil
        explore(volume, rescan: true, previous: previous)
        guard let task = scanTask else { return nil }
        let progress = scanProgress
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            progress.cancel()
            task.cancel()
        }
        guard !Task.isCancelled, !progress.isCancelled, let index = volumeIndexes[volume.id], index.scannedAt >= started else { return nil }
        return index
    }

    /// Les réglages du parcours d'un autre disque : ceux de l'arbre partagé, ses
    /// sauvegardes Time Machine jamais ouvertes (des liens physiques de
    /// dossiers, comptés une fois par sauvegarde), et sur un système de
    /// fichiers qui n'est pas celui de macOS, ses traces retenues par leur nom.
    nonisolated static func volumeScanOptions(for volume: VolumeDescriptor, home: URL) -> ScanOptions {
        let fileSystem = VolumeService.facts(of: volume.scanRoot)?.fileSystem ?? "apfs"
        let backups = volume.scanRoot.appendingPathComponent(VolumeProtection.timeMachineFolder).standardizedFileURL.path
        let excluded: Set<String> = FileManager.default.fileExists(atPath: backups) ? [backups] : []
        return ScanOptions(leafThreshold: 100_000, excludedPaths: excluded,
                           notableNames: RuleEngine.notableNames(fileSystem: fileSystem),
                           readOnlyPreferencesDirectory: DiskIndexModel.preferencesDirectory(for: home),
                           accountArchivesDirectory: AccountArchivePath.root.path,
                           deviceBackupsDirectory: DeviceBackupPath.root(in: home).path)
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
        guard canAnalyzeVolume(volume) else { return }
        let roots = [volume.scanRoot]
        guard let reader = beginDuplicateRead() else { return }
        defer {
            withExtendedLifetime(reader) {}
            if duplicates.isRunning { duplicates = .idle }
        }
        duplicates = .running
        let progress = DuplicateProgress()
        duplicateProgress = progress
        // À jour : par FSEvents si l'arbre date du branchement, en entier sinon.
        let revision = duplicateExclusionRevision
        guard await canSearchDuplicates(roots, reader: reader), let resolved = await resolveAnalysisRoots(roots, reader: reader),
              revision == duplicateExclusionRevision, canAnalyzeVolume(volume) else { return }
        let tree = await volumeIndexForAnalysis(volume)?.root
        guard revision == duplicateExclusionRevision, canAnalyzeVolume(volume),
              await resolveAnalysisRoots(roots, reader: reader) == resolved else { return }
        guard let tree else {
            duplicates = .idle
            return
        }
        var options = DuplicateOptions(roots: resolved.urls)
        options.minimumSize = Int64(preferences.duplicateMinimumMegabytes) * 1_000_000
        options.exclusions = preferences.duplicateExclusions
        options.exclusions.analysisRoots = resolved.directories
        let groups = await DuplicateFinder.find(options, tree: tree, progress: progress)
        guard await resolveAnalysisRoots(roots, reader: reader) == resolved,
              revision == duplicateExclusionRevision, canAnalyzeVolume(volume),
              await canSearchDuplicates(options.roots, reader: reader) else { return }
        showDuplicates(groups, volume: volume, previewRoots: DuplicatePreviewRoots(roots, resolved))
    }

    // MARK: Branchements

    func publishVolumeInventory(_ fresh: [VolumeDescriptor]) {
        let startup = bootVolume.map { [$0] } ?? []
        let prior = volumes.filter { !$0.isBoot }
        var waiting: [VolumeDescriptor] = []
        for volume in prior {
            if let current = fresh.first(where: { $0.id == volume.id }) {
                if current.mountIdentity != volume.mountIdentity { forgetVolume(at: volume.mountURL) }
            } else if unresolvedMounts.contains(PathNormalizer.normalize(volume.mountURL.path)) {
                // Garder l'identité tant que le montage est indéterminé.
                waiting.append(volume)
            } else {
                forgetVolume(at: volume.mountURL)
            }
        }
        let refreshed = startup + fresh + waiting
        if refreshed != volumes { volumes = refreshed }
    }

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
        if let treeVolume, PathNormalizer.normalize(treeVolume.mountURL.path) == root {
            cancelExploration()
            displayedExplorerIndex = nil
            self.treeVolume = nil
            tree = nil
            explorer = .idle
        }
        if offeredVolume.map({ PathNormalizer.normalize($0.mountURL.path) }) == root { offeredVolume = nil }
        if analysisVolumeID.map(PathNormalizer.normalize) == root { analysisVolumeID = nil }
        if analyzingVolumeID == id { analyzingVolumeID = nil }
        volumeAnalysisDates.removeValue(forKey: id)
        analysisReviews.removeValue(forKey: id)
        volumeIndexes.removeValue(forKey: id)
        liveVolumeScans.remove(id)
        timeMachineMounts.remove(root)
        confirmedOrdinaryMounts.removeValue(forKey: root)
        pendingTimeMachineMounts.remove(root)
        if duplicatesVolumeID == id {
            duplicateGroups = []
            duplicatePreviewRoots = nil
            duplicatesVolumeID = nil
            duplicates = .idle
        }
    }

    enum TimeMachineStatus: Sendable { case ordinary, backup }

    @discardableResult
    func scheduleTimeMachineRetry(
        force: Bool = false,
        read: @escaping @Sendable ([VolumeDescriptor]) async -> [String: TimeMachineStatus] = AppModel.readTimeMachineMounts
    ) -> Task<Void, Never>? {
        if let timeMachineRetry { return timeMachineRetry }
        guard force || volumes.contains(where: { volume in
            guard !volume.isBoot else { return false }
            let path = PathNormalizer.normalize(volume.mountURL.standardizedFileURL.path)
            return pendingTimeMachineMounts.contains(path) || (!isTimeMachine(volume) && !canAnalyzeVolume(volume))
        }) else { return nil }
        let retry = Task {
            defer { timeMachineRetry = nil }
            await refreshTimeMachineMounts(read: read)
        }
        timeMachineRetry = retry
        return retry
    }

    /// Un volume absent du résultat reste indéterminé.
    @discardableResult
    func refreshTimeMachineMounts(
        read: @escaping @Sendable ([VolumeDescriptor]) async -> [String: TimeMachineStatus] = AppModel.readTimeMachineMounts
    ) async -> Bool {
        let generation = mountGeneration
        timeMachineReadSequence += 1
        let sequence = timeMachineReadSequence
        let roots = volumes.filter { !$0.isBoot }
        let statuses = await read(roots)
        guard !Task.isCancelled, generation == mountGeneration, sequence == timeMachineReadSequence else { return false }
        for volume in roots {
            let path = PathNormalizer.normalize(volume.mountURL.standardizedFileURL.path)
            guard volumes.contains(where: {
                PathNormalizer.normalize($0.mountURL.standardizedFileURL.path) == path
                    && $0.mountIdentity == volume.mountIdentity
            }) else { continue }
            confirmedOrdinaryMounts.removeValue(forKey: path)
            switch statuses[path] {
            case .backup:
                timeMachineMounts.insert(path)
                pendingTimeMachineMounts.remove(path)
            case .ordinary:
                timeMachineMounts.remove(path)
                confirmedOrdinaryMounts[path] = volume.mountIdentity
                pendingTimeMachineMounts.remove(path)
            case nil:
                pendingTimeMachineMounts.insert(path)
            }
        }
        if let volume = analyzedVolume, !canAnalyzeVolume(volume) { analysisVolumeID = nil }
        if let running = volumes.first(where: { $0.id == analyzingVolumeID }), !canAnalyzeVolume(running) {
            analyzingVolumeID = nil
        }
        if let treeVolume, !canAnalyzeVolume(treeVolume) {
            cancelExploration()
            displayedExplorerIndex = nil
            self.treeVolume = nil
            tree = nil
            explorer = .idle
        }
        if let offeredVolume, !canAnalyzeVolume(offeredVolume) { self.offeredVolume = nil }
        return true
    }

    func classifyVolumeForOffer(
        at url: URL, generation: Int,
        read: @escaping @Sendable ([VolumeDescriptor]) async -> [String: TimeMachineStatus] = AppModel.readTimeMachineMounts
    ) async {
        guard generation == mountGeneration, await refreshTimeMachineMounts(read: read),
              generation == mountGeneration,
              let volume = volumes.first(where: { $0.mountURL.standardizedFileURL.path == url.standardizedFileURL.path }),
              canAnalyzeVolume(volume) else { return }
        offeredVolume = volume
    }

    private nonisolated static func readTimeMachineMounts(
        _ volumes: [VolumeDescriptor]
    ) async -> [String: TimeMachineStatus] {
        let result = await Command.run("/usr/bin/tmutil", ["destinationinfo", "-X"], timeout: 10)
        let destinations = result.succeeded ? WatchedVolumes.readTimeMachineMountPoints(in: result.stdout) : nil
        let known = destinations.map { Set($0.map(PathNormalizer.normalize)) }
        return await classifyTimeMachineMounts(volumes) { volume in
            guard timeMachineProbes.withLock({ $0.insert(volume.mountURL).inserted }) else { return nil }
            defer { timeMachineProbes.withLock { _ = $0.remove(volume.mountURL) } }
            let path = PathNormalizer.normalize(volume.mountURL.standardizedFileURL.path)
            return VolumeService.stableMount(at: volume.mountURL) { identity in
                guard volume.mountIdentity == identity else { return nil }
                if known?.contains(path) == true { return .backup }
                guard let opened = AnalysisRoot(volume.mountURL), opened.identity.directory == identity else { return nil }
                let marked = VolumeProtection.timeMachineVolumeMarker(in: opened)
                if marked == true { return .backup }
                if marked == false, known != nil { return .ordinary }
                return nil
            }
        }
    }

    nonisolated static func classifyTimeMachineMounts(
        _ volumes: [VolumeDescriptor],
        inspect: @escaping @Sendable (VolumeDescriptor) -> TimeMachineStatus?
    ) async -> [String: TimeMachineStatus] {
        await withTaskGroup(of: (String, TimeMachineStatus?).self) { tasks in
            for volume in volumes {
                tasks.addTask {
                    let path = PathNormalizer.normalize(volume.mountURL.standardizedFileURL.path)
                    let status = await checkStorageIO { inspect(volume) }
                    return (path, status ?? nil)
                }
            }
            var statuses: [String: TimeMachineStatus] = [:]
            for await (path, status) in tasks {
                statuses[path] = status
            }
            return statuses
        }
    }
}
