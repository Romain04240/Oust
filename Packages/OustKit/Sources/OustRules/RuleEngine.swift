import Foundation
import Synchronization
import OustCore
import OustScan
import OustSafety

/// Un lot d'éléments trouvés et mesurés, pour remplir l'interface au fil de l'eau.
public struct RuleBatch: Sendable {
    public let finder: FinderKind
    fileprivate let measuredItems: [CleanupItem]
    fileprivate let proofs: [String: @Sendable () -> Bool]
    fileprivate let analysisLocations: [String: AnalyzedItemLocation]
    fileprivate let isBound: Bool

    /// Bound batches are values. Native proof reads stay inside the operation
    /// that owns their storage worker.
    public var items: [CleanupItem] {
        isBound ? measuredItems : revalidatedItems()
    }

    package func revalidatedItems() -> [CleanupItem] {
        guard !Task.isCancelled else { return [] }
        return measuredItems.filter { item in
            guard !Task.isCancelled else { return false }
            guard proofs[item.id]?() != false else { return false }
            StorageOperationContext.reportProgress()
            guard item.requiresLiveAnalysisLocation else { return true }
            guard let url = item.paths.first else { return false }
            return analysisLocation(for: item)?.isCurrent(at: url) == true
        }
    }

    fileprivate func validatedSnapshot() -> RuleBatch {
        RuleBatch(finder: finder, measuredItems: revalidatedItems(), proofs: proofs,
                  analysisLocations: analysisLocations, isBound: isBound)
    }

    package func analysisLocation(for item: CleanupItem) -> AnalyzedItemLocation? {
        analysisLocations[item.id]
    }
}

/// The owner waits for completion even when the stream consumer has stopped.
package struct RuleOperation: Sendable {
    package let batches: AsyncStream<RuleBatch>
    package let completion: Task<Void, Never>
}

/// Les chercheurs, dans l'ordre où ils rendent leurs résultats.
public enum FinderKind: String, Sendable, CaseIterable {
    case packageCaches, xcode, simulators, agents, models, userContent, projectArtifacts
    case toolVersions, toolCleanups, appCaches, personalFiles, cloud, compression
    case creative, games, appData, pro
    case userLogs, preferenceDiagnostics, accountArchives
    /// Sur un autre disque seulement (`RuleContext.volume`) : rien ailleurs.
    case volumeInstallers, volumeTrash, volumeTraces, volumeKept
}

/// Comment mesurer ce que les chercheurs trouvent.
public struct Measurer: Sendable {
    let measure: @Sendable ([URL]) async -> [URL: OustScan.Measurement]
    var measureGroups: (@Sendable ([[URL]]) async -> [URL: OustScan.Measurement])?

    public init(_ measure: @escaping @Sendable ([URL]) async -> [URL: OustScan.Measurement]) {
        self.measure = measure
    }

    /// En parcourant chaque élément sur le disque.
    public static let disk = Measurer { await Scanner.measure($0) }

    /// D'après l'arborescence de l'analyse, attendue au besoin, sans relire le
    /// disque ; seul ce qu'elle ignore (petit fichier, autre volume, dossier
    /// exclu) est mesuré à part.
    ///
    /// Les chercheurs, eux, démarrent tout de suite : pendant que le parcours
    /// tourne, ils interrogent git et simctl, et n'attendent l'arbre que pour
    /// les tailles.
    public static func tree(_ provider: @escaping @Sendable () async -> TreeNode?) -> Measurer {
        Measurer { urls in
            guard let tree = await provider() else { return await Scanner.measure(urls) }
            var measures: [URL: OustScan.Measurement] = [:]
            var unknown: [URL] = []
            for url in urls {
                if !SafariDownloadPath.containsPackage(url.path), let known = tree.measurement(of: url) {
                    measures[url] = known
                } else {
                    unknown.append(url)
                }
            }
            if !unknown.isEmpty {
                measures.merge(await Scanner.measure(unknown)) { first, _ in first }
            }
            return measures
        }
    }
}

/// Lance tous les chercheurs, mesure ce qu'ils trouvent, et rend les éléments
/// lot par lot (SPEC §9.3 : les catégories se remplissent au fil de l'eau).
public enum RuleEngine {

    public static func run(_ context: RuleContext, finders: [FinderKind] = FinderKind.allCases,
                           measurer: Measurer = .disk) -> AsyncStream<RuleBatch> {
        guard context.volumeAnchor != nil else { return runUnbounded(context, finders: finders, measurer: measurer) }
        return BoundRuleRun.shared.run { release in
            runUnbounded(context, finders: finders, measurer: measurer, onFinish: release)
        }
    }

    /// The model's outer operation owns the deadline and waits for all native
    /// work to exit. Opening a second gate here would deadlock that operation.
    package static func runWithinStorageOperation(
        _ context: RuleContext, finders: [FinderKind] = FinderKind.allCases
    ) -> RuleOperation {
        guard StorageOperationContext.isBound else {
            return RuleOperation(batches: AsyncStream { $0.finish() }, completion: Task {})
        }
        return makeOperation(context, finders: finders, measurer: .disk)
    }

    private static func runUnbounded(_ context: RuleContext, finders: [FinderKind],
                                     measurer: Measurer, onFinish: @escaping @Sendable () -> Void = {}) -> AsyncStream<RuleBatch> {
        makeOperation(context, finders: finders, measurer: measurer, onFinish: onFinish).batches
    }

    private static func makeOperation(_ context: RuleContext, finders: [FinderKind],
                                      measurer: Measurer, onFinish: @escaping @Sendable () -> Void = {}) -> RuleOperation {
        let eligible = context.volumeAnchor == nil ? finders : finders.filter(FinderKind.volumeFinders.contains)
        let measurements: Measurer
        if let anchor = context.volumeAnchor {
            let grouped: @Sendable ([[URL]]) async -> [URL: OustScan.Measurement] = { groups in
                let urls = Array(Set(groups.flatMap { $0 }))
                let tree = await context.tree?()
                let admitted = urls.filter { url in
                    guard let node = tree?.descendant(atPath: url.path) else { return true }
                    return VolumeDirectory.entry(url, in: anchor).facts?.inode == node.fileID
                }
                guard !Task.isCancelled else { return [:] }
                var options = context.volumeScanOptions ?? ScanOptions(
                    leafThreshold: .max,
                    readOnlyPreferencesDirectory: context.home.appendingPathComponent("Library/Preferences", isDirectory: true).path,
                    accountArchivesDirectory: context.accountArchivesRoot.path,
                    deviceBackupsDirectory: DeviceBackupPath.root(in: context.home).path
                )
                options.hardlinkGainGroups = groups.map { $0.map(\.path) }
                return await Scanner.measureBound(admitted, root: anchor, options: options)
            }
            var bound = Measurer { await grouped([$0]) }
            bound.measureGroups = grouped
            measurements = bound
        } else {
            measurements = measurer
        }
        let (batches, continuation) = AsyncStream<RuleBatch>.makeStream()
        let task = Task {
            defer { onFinish() }
            let pathGuard = PathGuard(home: context.home)
            await withTaskGroup(of: RuleBatch.self) { group in
                for kind in eligible {
                    group.addTask {
                        let candidates = await find(kind, context: context)
                        guard !Task.isCancelled else {
                            return RuleBatch(finder: kind, measuredItems: [], proofs: [:], analysisLocations: [:],
                                             isBound: context.volumeAnchor != nil)
                        }
                        StorageOperationContext.reportProgress()
                        let identities = Mutex<[String: BoundItemIdentity]>([:])
                        let items = await measure(candidates, using: measurements, pathGuard: pathGuard,
                                                  volumeAnchor: context.volumeAnchor, recordIdentity: { id, identity in
                            identities.withLock { $0[id] = identity }
                        })
                        var locations: [String: AnalyzedItemLocation] = [:]
                        for candidate in candidates where candidate.item.requiresLiveAnalysisLocation {
                            locations[candidate.item.id] = candidate.location
                        }
                        let retained = identities.withLock { $0 }
                        var proofs: [String: @Sendable () -> Bool] = [:]
                        for candidate in candidates {
                            let dependency = candidate.boundProof
                            if context.volumeAnchor != nil {
                                let identity = retained[candidate.item.id]
                                proofs[candidate.item.id] = {
                                    identity?.isCurrent() == true && dependency?() != false
                                }
                            } else if let dependency {
                                proofs[candidate.item.id] = dependency
                            }
                        }
                        let batch = RuleBatch(finder: kind, measuredItems: items, proofs: proofs,
                                              analysisLocations: locations, isBound: context.volumeAnchor != nil)
                        return context.volumeAnchor == nil ? batch : batch.validatedSnapshot()
                    }
                }
                for await batch in group {
                    guard !Task.isCancelled else { group.cancelAll(); break }
                    continuation.yield(batch)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return RuleOperation(batches: batches, completion: task)
    }

    /// Tout, d'un bloc (tests, CLI).
    public static func collect(_ context: RuleContext, finders: [FinderKind] = FinderKind.allCases,
                               measurer: Measurer = .disk) async -> [CleanupItem] {
        var batches: [RuleBatch] = []
        for await batch in run(context, finders: finders, measurer: measurer) { batches.append(batch) }
        return batches.flatMap(\.items)
    }

    static func find(_ kind: FinderKind, context: RuleContext) async -> [Candidate] {
        guard !Task.isCancelled else { return [] }
        let candidates = await findOnly(kind, context: context)
        // Un disque en lecture seule : on montre, rien ne peut en partir.
        guard context.volume?.isReadOnly == true else { return candidates }
        return candidates.map { candidate in
            var candidate = candidate
            candidate.item.protect(.readOnlyVolume)
            return candidate
        }
    }

    private static func findOnly(_ kind: FinderKind, context: RuleContext) async -> [Candidate] {
        switch kind {
        case .packageCaches: await PackageCachesFinder(context: context).find()
        case .xcode: await XcodeFinder(context: context).find()
        case .simulators: await SimulatorFinder(context: context).find()
        case .agents: await AgentFinder(context: context).find()
        case .models: await ModelFinder(context: context).find()
        case .userContent: await UserContentFinder(context: context).find()
        case .projectArtifacts: await ProjectArtifactsFinder(context: context).find()
        case .toolVersions: await ToolVersionsFinder(context: context).find()
        case .toolCleanups: await ToolCleanupsFinder(context: context).find()
        case .appCaches: await AppCachesFinder(context: context).find()
        case .userLogs: await UserLogsFinder(context: context).find()
        case .preferenceDiagnostics: PreferenceDiagnosticsFinder(context: context).find()
        case .accountArchives: AccountArchivesFinder(context: context).find()
        case .personalFiles: await PersonalFilesFinder(context: context).find()
        case .cloud: await CloudCopiesFinder(context: context).find()
        case .compression: await CompressionFinder(context: context).find()
        case .creative: await CreativeAppsFinder(context: context).find()
        case .games: await GamesFinder(context: context).find()
        case .appData: await AppDataCachesFinder(context: context).find()
        case .pro: await ProAppsFinder(context: context).find()
        case .volumeInstallers: await VolumeInstallersFinder(context: context).find()
        case .volumeTrash: await VolumeTrashFinder(context: context).find()
        case .volumeTraces: await VolumeTracesFinder(context: context).find()
        case .volumeKept: await VolumeKeptFinder(context: context).find()
        }
    }

    /// Mesure les candidats d'un seul passage du moteur d'analyse, et note leur
    /// empreinte pour la revalidation (RULES.md, règle 2).
    static func measure(_ candidates: [Candidate], using measurer: Measurer, pathGuard: PathGuard,
                        volumeAnchor: AnalysisRoot? = nil,
                        recordIdentity: @Sendable (String, BoundItemIdentity) -> Void = { _, _ in }) async -> [CleanupItem] {
        guard !Task.isCancelled else { return [] }
        func isCurrent(_ candidate: Candidate) -> Bool {
            guard !Task.isCancelled else { return false }
            guard candidate.boundProof?() != false else { return false }
            guard let location = candidate.location else { return true }
            guard let path = candidate.item.paths.first else { return false }
            return location.isCurrent(at: path)
        }
        let candidates = candidates.filter(isCurrent).map { candidate in
            var candidate = candidate
            // Trace bytes were collected by the finder and need a fresh identity-bound
            // measurement. Explicit no-read rows, including Time Machine, keep theirs.
            if volumeAnchor != nil, candidate.item.category == .diskTraces { candidate.needsMeasure = true }
            return candidate
        }
        let boundEntries: [URL: FileFacts]
        if let volumeAnchor {
            boundEntries = Set(candidates.flatMap(\.item.paths)).reduce(into: [:]) { entries, url in
                entries[url] = VolumeDirectory.entry(url, in: volumeAnchor).facts
            }
        } else {
            boundEntries = [:]
        }
        guard !Task.isCancelled else { return [] }
        let groups = candidates.filter(\.needsMeasure).map(\.item.paths)
        let paths = groups.flatMap { $0 }
        let measures: [URL: OustScan.Measurement]
        if paths.isEmpty {
            measures = [:]
        } else if volumeAnchor != nil, let grouped = measurer.measureGroups {
            measures = await grouped(groups)
        } else {
            measures = await measurer.measure(Array(Set(paths)))
        }
        guard !Task.isCancelled else { return [] }
        let worktrees = candidates.flatMap { candidate -> [URL] in
            if case .gitWorktreeRemove = candidate.item.method { return candidate.item.paths }
            return []
        }
        let allowedWorktrees = await pathGuard.allowedWorktreesForAnalysis(Set(worktrees))
        return candidates.compactMap { candidate in
            guard isCurrent(candidate) else { return nil }
            var item = candidate.item
            if candidate.needsMeasure {
                var sizes = Sizes.zero
                var latest = item.lastActivity
                var inaccessible = false
                var missingMeasure = false
                for path in item.paths {
                    guard let measure = measures[path] else {
                        missingMeasure = true
                        continue
                    }
                    sizes += measure.sizes
                    if let date = measure.latestModification, date > (latest ?? .distantPast) { latest = date }
                    inaccessible = inaccessible || measure.inaccessible
                }
                if item.isIncompleteSafariDownload {
                    guard let location = candidate.location, let path = item.paths.first else { return nil }
                    if let measure = measures[path], !inaccessible,
                       measure.directoryDevice == location.entry.device, measure.directoryFileID == location.entry.inode {
                        item.sizes = Sizes(allocated: sizes.allocated, freeable: 0)
                    }
                } else if item.isDeviceBackup || item.category == .userLogs {
                    item.sizes = Sizes(allocated: sizes.allocated, freeable: 0)
                } else {
                    item.sizes = sizes
                }
                if item.lastActivity == nil, !item.isDeviceBackup { item.lastActivity = latest }
                if inaccessible && sizes.allocated == 0 { item.protect(.needsFullDiskAccess) }
                if volumeAnchor != nil && (missingMeasure || inaccessible) { item.protect(.unknownState) }
            }
            if let volumeAnchor {
                guard let first = item.paths.first, let facts = boundEntries[first],
                      item.paths.allSatisfy({ path in
                          guard let before = boundEntries[path],
                                let after = VolumeDirectory.entry(path, in: volumeAnchor).facts else { return false }
                          return after.device == before.device && after.mode == before.mode
                              && after.isUnchanged(comparedTo: before)
                      }) else { return nil }
                item.fingerprint = Fingerprint(modificationDate: facts.modificationDate, fileID: facts.inode)
                if !item.protections.isEmpty { item.sizes.freeable = 0 }
            } else if item.fingerprint == nil, let first = item.paths.first {
                let values = try? first.resourceValues(forKeys: [.contentModificationDateKey, .fileResourceIdentifierKey])
                item.fingerprint = Fingerprint(modificationDate: values?.contentModificationDate,
                                               fileID: Self.inode(of: first))
            }
            // Téléchargements a pu être redirigé pendant l'attente de la mesure.
            if case .gitWorktreeRemove = item.method {
                if !item.paths.allSatisfy(allowedWorktrees.contains) { item.protect(.systemPath) }
                item.sizes.freeable = 0
            } else if (volumeAnchor == nil || item.protections.isEmpty), item.category != .userLogs, !item.isIncompleteSafariDownload, !item.isAccountArchive, !item.isDeviceBackup, item.category != .cloudFiles, item.sizes.allocated > 0, item.sizes.freeable < item.sizes.allocated * 9 / 10 {
                item.notes.append(.partlyShared)
            }
            // Un élément vide n'apprend rien à personne.
            if candidate.needsMeasure && item.sizes.allocated == 0 && item.protections.isEmpty && !item.isDeviceBackup { return nil }
            // Le seuil vaut aussi pour le protégé : cinquante caches ouverts de
            // quelques kilo-octets n'apprennent rien non plus.
            if item.sizes.allocated < candidate.minimumAllocated { return nil }
            if let volumeAnchor {
                let entries = item.paths.compactMap { path in boundEntries[path].map { (path, $0) } }
                recordIdentity(item.id, BoundItemIdentity(anchor: volumeAnchor, entries: entries))
            }
            return candidate.location?.revalidateBackupBadge(item) ?? item
        }
    }

    static func inode(of url: URL) -> UInt64? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }
}

extension RuleEngine {
    /// Les petits fichiers que le parcours doit retenir par leur nom, pour que
    /// les chercheurs n'aient pas à relister les dossiers de projets.
    public static var notableNames: Set<String> { ArtifactTable.markerNames }
}

/// Tous les identifiants de règles, pour vérifier que chacun a son explication.
public enum RuleCatalog {
    public static let ruleIDs: [String] = [
        "artifact.node_modules", "artifact.framework_build", "artifact.build_cache", "artifact.coverage",
        "artifact.output", "artifact.swiftpm", "artifact.pods", "artifact.xcode_local", "artifact.flutter",
        "artifact.gradle", "artifact.rust", "artifact.python_env", "artifact.vendor", "artifact.pycache",
        "cache.npm", "cache.yarn", "cache.pnpm", "cache.bun", "cache.pip", "cache.gradle", "cache.maven",
        "cache.cocoapods", "cache.cargo", "cache.go", "cache.homebrew", "cache.pub", "cache.browsers_test",
        "xcode.module_cache", "xcode.derived_data", "xcode.derived_data_orphan", "xcode.device_support",
        "xcode.archive", "xcode.logs", "xcode.previews",
        "simulator.device", "simulator.unavailable", "simulator.runtime",
        "agent.worktree", "agent.codex_worktree", "agent.claude_history", "agent.claude_history_orphan",
        "agent.codex_sessions", "agent.codex_workspace", "agent.codex_images", "agent.cache",
        "model.huggingface", "model.lmstudio", "model.ollama", "model.app_models",
        "downloads.installer", "downloads.large", CleanupItem.incompleteSafariDownloadRuleID,
        CleanupItem.invalidPreferenceRuleID, CleanupItem.accountArchiveRuleID, "trash.contents",
        "ios.backup", "vm.image", "vm.docker",
        "snapshot.time_machine", "browser.cache", "browser.history", "browser.cookies",
        "duplicate.copy", "explorer.item",
        "cloud.icloud", "cloud.file_provider", "compress.project",
        "version.xcode", "version.macos_installer", "version.nvm", "version.pyenv", "version.jdk_gradle",
        "version.jdk_system", "version.ndk", "version.rustup", "tool.brew_cleanup",
        "container.build_cache", "container.images", "container.stopped",
        "cache.app", "logs.user", "attachments.mail", "attachments.messages", "ios.update", "screenshots.desktop",
        "creative.library.render", "creative.library.transcoded", "creative.resolve.cache",
        "creative.resolve.proxy", "creative.resolve.gallery", "creative.insta360.cache", "creative.insta360.proxy",
        "creative.blender.cache", "creative.blender.temp", "creative.sound_library",
        "game.steam.appcache", "game.steam.shadercache", "game.steam.depotcache", "game.steam.leftover",
        "game.epic.vault", "game.epic.leftover", "game.gog.webcache", "game.steam.download", "game.epic.download",
        "cache.electron", "cache.telegram", "creative.adobe.media_cache", "creative.capcut.cache",
        "creative.filmora.temp", "creative.plex.updates",
        "creative.ableton.cache", "creative.protools.wavecache", "creative.avid.cache", "creative.redshift.cache",
        "creative.maxon.assetcache", "creative.unity.cache", "creative.unity.asset_store", "creative.unreal.ddc",
        "creative.godot.cache", "creative.autocad.graphics_cache", "creative.archicad.cache",
        "creative.indesign.cache", "creative.lightroom.previews", "creative.captureone.cache",
        "game.battlenet.cache", "game.prism.cache", "game.heroic.cache", "game.roblox.logs",
        "trash.volume", "volume.installer", "volume.appledouble", "volume.appledouble_orphan", "volume.ds_store",
        "volume.time_machine", "volume.photo_library",
    ]
}
