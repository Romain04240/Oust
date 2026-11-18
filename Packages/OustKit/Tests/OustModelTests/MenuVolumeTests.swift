import Foundation
import OustCore
@testable import OustModel
import OustScan
import OustVolume
import Testing

struct MenuVolumeTests {
    @Test("L’inventaire écarte une ligne dont le point de montage a changé")
    func staleMount() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let expected = VolumeMountIdentity(device: 1, inode: 2, createdSeconds: 3, createdNanoseconds: 4)
        let replacement = VolumeMountIdentity(device: 2, inode: 2, createdSeconds: 3, createdNanoseconds: 4)
        var live = expected
        let row = VolumeService.stableMount(at: fixture, identityAt: { _ in live }) { initial -> String? in
            #expect(initial == expected)
            live = replacement
            return "Nom du premier volume"
        }
        #expect(row == nil)
    }

    @Test("L’absence d’identité empêche la mesure ou la publication d’un volume")
    func unknownMount() {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let unknown = VolumeService.stableMount(at: fixture, identityAt: { _ in nil }) { _ -> String? in
            Issue.record("Une identité inconnue ne doit pas lancer la mesure")
            return "Volume non confirmé"
        }
        #expect(unknown == nil)

        let expected = VolumeMountIdentity(device: 1, inode: 2, createdSeconds: 3, createdNanoseconds: 4)
        var live: VolumeMountIdentity? = expected
        let disappeared = VolumeService.stableMount(at: fixture, identityAt: { _ in live }) { _ in
            live = nil
            return "Volume disparu"
        }
        #expect(disappeared == nil)
    }

    @Test("Un nouveau relevé du disque de démarrage remplace le précédent dans les deux vues")
    @MainActor func refreshesStartupCapacity() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: root)
        let before = Capacity(total: 1000, available: 100, availableForImportantUsage: 100)
        let after = Capacity(total: 1000, available: 300, availableForImportantUsage: 300)
        let boot = VolumeDescriptor(name: "Disque fictif", mountURL: root, scanRoot: root, isBoot: true,
                                    isInternal: true, isRemovable: false, capacity: before)
        model.volumes = [boot]
        model.watch.updateBoot(boot)
        await model.refreshStartupVolume {
            var fresh = boot
            fresh.capacity = after
            return fresh
        }
        #expect(model.volumes.first?.capacity == after)
        #expect(model.watch.boot?.capacity == after)
    }

    @Test("Deux mesures concurrentes publient le relevé le plus récent dans les deux ordres")
    @MainActor func overlappingStartupReads() async {
        for newestFirst in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let model = AppModel(home: root)
            let old = volume(at: root, boot: true, free: 100)
            let newest = volume(at: root, boot: true, free: 700)
            let oldRead = PausedRead<VolumeDescriptor>()
            let newRead = PausedRead<VolumeDescriptor>()
            let first = Task { await model.refreshStartupVolume { await oldRead.read() } }
            await oldRead.waitUntilStarted()
            let second = Task { await model.refreshStartupVolume { await newRead.read() } }
            await newRead.waitUntilStarted()

            if newestFirst {
                newRead.finish(with: newest)
                await second.value
                oldRead.finish(with: old)
                await first.value
            } else {
                oldRead.finish(with: old)
                await first.value
                newRead.finish(with: newest)
                await second.value
            }
            #expect(model.watch.boot?.capacity.available == 700)
            #expect(model.volumes.first?.capacity.available == 700)
        }
    }

    @Test("Une publication après nettoyage invalide les mesures déjà lancées")
    @MainActor func reclaimedCapacityWinsOverPendingRead() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: root)
        let old = volume(at: root, boot: true, free: 100)
        model.watch.updateBoot(old)
        let pending = PausedRead<VolumeDescriptor>()
        let refresh = Task { await model.refreshStartupVolume { await pending.read() } }
        await pending.waitUntilStarted()

        let newest = volume(at: root, boot: true, free: 700)
        model.publishReclaimedCapacity(newest.capacity)
        pending.finish(with: old)
        await refresh.value
        #expect(model.watch.boot?.capacity == newest.capacity)
        #expect(model.volumes.first?.capacity == newest.capacity)
    }

    @Test("Une lecture périmée ne déprotège ni ne propose une destination remplacée au même chemin")
    @MainActor func protectsReplacementTimeMachineMount() async {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mount = sandbox.appendingPathComponent("Volume")
        let model = AppModel(home: sandbox)
        let ordinary = volume(at: mount, boot: false, free: 100, name: "Premier disque")
        model.volumes = [ordinary]
        model.registerVolumeEvent(.mounted(mount))
        let original = model.mountGeneration
        let pending = PausedRead<[String: AppModel.TimeMachineStatus]>()
        let first = Task {
            await model.classifyVolumeForOffer(at: mount, generation: original) { _ in await pending.read() ?? [:] }
        }
        await pending.waitUntilStarted()

        model.offeredVolume = ordinary
        model.registerVolumeEvent(.unmounted(mount))
        #expect(model.offeredVolume == nil)
        model.registerVolumeEvent(.mounted(mount))
        let replacement = volume(at: mount, boot: false, free: 300, name: "Sauvegarde")
        model.volumes = [replacement]
        let marks = PausedRead<[String: AppModel.TimeMachineStatus]>()
        let classification = Task {
            await model.classifyVolumeForOffer(at: mount, generation: model.mountGeneration) { _ in
                await marks.read() ?? [:]
            }
        }
        await marks.waitUntilStarted()
        model.selectAnalysisVolume(replacement)
        #expect(model.analysisVolumeID == nil)
        #expect(!model.canAnalyzePath(mount.appendingPathComponent("Sous-dossier")))
        await model.analyze(replacement)
        #expect(!model.analysisPhase(for: replacement).hasRun)
        #expect(!model.analysis.isRunning)
        marks.finish(with: [mount.path: .backup])
        await classification.value
        #expect(model.isTimeMachine(replacement))
        #expect(model.offeredVolume == nil)

        pending.finish(with: [:])
        await first.value
        #expect(model.isTimeMachine(replacement))
        #expect(model.offeredVolume == nil)
    }

    @Test("Une classification en échec conserve une sauvegarde connue et bloque un disque indéterminé")
    @MainActor func incompleteTimeMachineReadKeepsVeto() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: root)
        let backup = volume(at: root.appendingPathComponent("Sauvegarde"), boot: false, free: 100)
        let unknown = volume(at: root.appendingPathComponent("Autre"), boot: false, free: 300)
        model.registerVolumeEvent(.mounted(backup.mountURL))
        model.registerVolumeEvent(.mounted(unknown.mountURL))
        model.volumes = [backup, unknown]
        await model.refreshTimeMachineMounts { _ in [backup.mountURL.path: .backup] }
        await model.classifyVolumeForOffer(at: unknown.mountURL, generation: model.mountGeneration) { _ in [:] }
        #expect(model.isTimeMachine(backup))
        #expect(!model.canAnalyzeVolume(unknown))
        #expect(model.offeredVolume == nil)
    }

    @Test("La classification ordinaire ne suit pas un changement d’identité au même chemin")
    @MainActor func ordinaryClassificationRequiresCurrentMountIdentity() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: root)
        var first = volume(at: root, boot: false, free: 100)
        first.mountIdentity = VolumeMountIdentity(device: 1, inode: 2, createdSeconds: 3, createdNanoseconds: 4)
        model.volumes = [first]
        await model.refreshTimeMachineMounts { _ in [root.path: .ordinary] }
        #expect(model.canAnalyzeVolume(first))

        var replacement = first
        replacement.mountIdentity = VolumeMountIdentity(device: 2, inode: 2, createdSeconds: 3, createdNanoseconds: 4)
        model.volumes = [replacement]
        #expect(!model.canAnalyzeVolume(first))
        #expect(!model.canAnalyzeVolume(replacement))
        #expect(!model.canAnalyzePath(root.appendingPathComponent("Dossier")))
    }

    @Test("Un événement périmé ne relance ni n’invalide l’inventaire courant")
    @MainActor func staleEventCannotInvalidateCurrentInventory() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: root)
        let oldMount = root.appendingPathComponent("Ancien")
        let newMount = root.appendingPathComponent("Nouveau")
        model.registerVolumeEvent(.mounted(oldMount))
        let oldGeneration = model.mountGeneration
        let startup = PausedRead<VolumeDescriptor>()
        let outdated = Task {
            await model.refreshVolumeInventory(waitForOtherVolumes: true, generation: oldGeneration,
                                               readStartup: { await startup.read() }) {
                Issue.record("Une génération périmée ne doit pas mesurer les volumes")
                return []
            }
        }
        await startup.waitUntilStarted()

        model.registerVolumeEvent(.mounted(newMount))
        let newGeneration = model.mountGeneration
        let latest = volume(at: newMount, boot: false, free: 700)
        let external = PausedRead<[VolumeDescriptor]>()
        let current = Task {
            await model.refreshVolumeInventory(waitForOtherVolumes: true, generation: newGeneration,
                                               readStartup: { nil }, readVolumes: { await external.read() ?? [] })
        }
        await external.waitUntilStarted()
        startup.finish(with: volume(at: root, boot: true, free: 300))
        #expect(await outdated.value == false)
        external.finish(with: [latest])
        #expect(await current.value)
        #expect(model.volumes.contains(latest))
    }

    @Test("Une mesure APFS livrée en retard ne remplace pas une lecture plus récente")
    @MainActor func delayedReclaimedCapacityCannotWin() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: root)
        let old = volume(at: root, boot: true, free: 100)
        let latest = volume(at: root, boot: true, free: 700)
        let buffered = VolumeService.ReclaimedSample(capacity: old.capacity, measuredAt: .now - .seconds(2))
        await model.refreshStartupVolume { latest }
        model.publishReclaimedCapacity(buffered.capacity, measuredAt: buffered.measuredAt)
        #expect(model.watch.boot?.capacity == latest.capacity)
        #expect(model.volumes.first?.capacity == latest.capacity)
        #expect(model.reclaimed == nil)
    }

    @Test("Les analyses refusent un dossier non vérifié, y compris par un parent symbolique")
    @MainActor func directAndRedirectedAnalysisRootsAreBlocked() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mounted = fixture.appendingPathComponent("Montage")
        let child = mounted.appendingPathComponent("Dossier")
        let link = fixture.appendingPathComponent("Alias")
        let fm = FileManager.default
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        try fm.createSymbolicLink(at: link, withDestinationURL: mounted)
        let redirected = link.appendingPathComponent("Dossier")
        let model = AppModel(home: fixture)
        #expect(await model.resolveAnalysisRoots([redirected]) != nil)
        model.registerVolumeEvent(.mounted(mounted))
        let candidate = volume(at: mounted, boot: false, free: 100)
        model.volumes = [candidate]
        #expect(await model.resolveAnalysisRoots([redirected]) == nil)
        #expect(await model.resolveAnalysisRoots([fixture]) == nil)
        #expect(await model.resolveAnalysisRoots([URL(fileURLWithPath: "/")]) == nil)

        model.explore(folder: redirected)
        await model.scanTask?.value
        #expect(model.tree == nil)
        #expect(!model.explorer.isRunning)
        await model.findDuplicates(in: [redirected])
        #expect(!model.duplicates.hasRun)
        model.similarImages.addFolder(child)
        await model.similarImages.search()
        #expect(!model.similarImages.phase.hasRun)
    }

    @Test("La validation finale distingue deux dossiers au même chemin")
    @MainActor func analysisRootsRetainDirectoryIdentity() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let requested = fixture.appendingPathComponent("Dossier")
        let original = fixture.appendingPathComponent("Original")
        let fm = FileManager.default
        try fm.createDirectory(at: requested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let model = AppModel(home: fixture)
        let before = try #require(await model.resolveAnalysisRoots([requested]))
        try fm.moveItem(at: requested, to: original)
        try fm.createDirectory(at: requested, withIntermediateDirectories: false)
        let after = try #require(await model.resolveAnalysisRoots([requested]))
        #expect(before.urls == after.urls)
        #expect(before != after)
    }

    @Test("Le parcours de l’Explorateur reste sur le dossier ouvert après redirection")
    @MainActor func boundExplorerScanDoesNotFollowReplacement() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let requested = fixture.appendingPathComponent("Dossier")
        let original = fixture.appendingPathComponent("Original")
        let other = fixture.appendingPathComponent("Autre")
        let fm = FileManager.default
        try fm.createDirectory(at: requested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        try fm.createDirectory(at: other, withIntermediateDirectories: false)
        try Data([1]).write(to: requested.appendingPathComponent("Original.txt"))
        try Data([2]).write(to: other.appendingPathComponent("Redirection.txt"))
        let model = AppModel(home: fixture)
        let admitted = try #require(await model.resolveAnalysisRoots([requested]))
        let root = try #require(admitted.directories.first)
        try fm.moveItem(at: requested, to: original)
        try fm.createSymbolicLink(at: requested, withDestinationURL: other)
        let (index, _) = await ScanIndex.refreshBound(nil, root: root,
                                                       options: ScanOptions(leafThreshold: 0), progress: ScanProgress())
        #expect(index.root.files.map(\.name) == ["Original.txt"])
        #expect(await model.resolveAnalysisRoots([requested]) != admitted)
    }

    @Test("Un volume qui ne répond pas laisse le résultat des autres disponible")
    @MainActor func timeMachineClassificationSurvivesSlowPeer() async {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: fixture)
        var local = volume(at: fixture.appendingPathComponent("Local"), boot: false, free: 100)
        local.mountIdentity = VolumeMountIdentity(device: 1, inode: 2, createdSeconds: 3, createdNanoseconds: 4)
        let ready = local
        let remote = volume(at: fixture.appendingPathComponent("Lent"), boot: false, free: 100)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.volumes = [remote, ready]
        await model.refreshTimeMachineMounts { volumes in
            await AppModel.classifyTimeMachineMounts(volumes) { volume in
                if volume.id == remote.id {
                    _ = release.wait(timeout: .now() + 10)
                    return .ordinary
                }
                return .ordinary
            }
        }
        #expect(model.canAnalyzeVolume(ready))
        #expect(!model.canAnalyzeVolume(remote))
        #expect(model.pendingTimeMachineMounts.contains(remote.mountURL.path))
    }

    @Test("Un nouveau montage SMB lent reste indéterminé sans écarter le disque local")
    @MainActor func inventoryKeepsSlowMountUnverified() async {
        let root = URL(fileURLWithPath: "/Volumes/OustQA-\(UUID().uuidString)", isDirectory: true)
        let local = volume(at: root.appendingPathComponent("Local"), boot: false, free: 100)
        let remote = volume(at: root.appendingPathComponent("SMB"), boot: false, free: 200)
        let localEntry = MountedFileSystems.Entry(path: local.mountURL.path, type: "apfs", source: "local",
                                                    identity: [1, 2], isLocal: true, isHidden: false)
        let remoteEntry = MountedFileSystems.Entry(path: remote.mountURL.path, type: "smbfs", source: "fictif",
                                                     identity: [3, 4], isLocal: false, isHidden: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let result = await VolumeService.collectInventory([remoteEntry, localEntry]) { entry in
            if entry == remoteEntry {
                _ = release.wait(timeout: .now() + 10)
                return remote
            }
            return local
        }
        #expect(result.volumes == [local])
        #expect(result.unverified == [remote.mountURL.path])
        let model = AppModel(home: root)
        model.volumes = result.volumes
        model.unresolvedMounts = result.unverified
        #expect(!model.canAnalyzePath(remote.mountURL.appendingPathComponent("Sous-dossier")))
        #expect(!model.canAnalyzeVolume(remote))
    }

    @Test("Analyser ne lance aucun chercheur si un montage descendant n'est pas admis")
    @MainActor func externalAnalysisDoesNotFallBackAfterDeniedAdmission() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = sandbox.appendingPathComponent("Non-verifie")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let model = AppModel(home: sandbox)
        let external = volume(at: sandbox, boot: false, free: 100)
        model.volumes = [external]
        model.registerVolumeEvent(.mounted(nested))
        await model.analyzeOtherVolume(external)
        #expect(model.finishedFinders.isEmpty)
        #expect(!model.analysisPhase(for: external).hasRun)
    }

    @Test("Un remplacement d'inventaire purge les résultats associés à l'ancien disque")
    @MainActor func inventoryReplacementClearsOldResults() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: home)
        var first = volume(at: home.appendingPathComponent("Montage"), boot: false, free: 100)
        first.mountIdentity = VolumeMountIdentity(device: 1, inode: 2, createdSeconds: 3, createdNanoseconds: 4)
        var next = first
        next.mountIdentity = VolumeMountIdentity(device: 3, inode: 2, createdSeconds: 3, createdNanoseconds: 4)
        model.volumes = [first]
        model.volumeAnalysisDates[first.id] = Date()
        model.confirmedOrdinaryMounts[first.mountURL.standardizedFileURL.path] = first.mountIdentity
        model.treeVolume = first

        model.publishVolumeInventory([next])
        #expect(model.volumes == [next])
        #expect(!model.analysisPhase(for: next).hasRun)
        #expect(!model.canAnalyzeVolume(next))
        #expect(model.treeVolume == nil)
    }

    @Test("Une vérification temporairement indisponible est retentée et mutualisée sur le même montage")
    @MainActor func retriesUnverifiedMountOnSameIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: root)
        var candidate = volume(at: root, boot: false, free: 100)
        candidate.mountIdentity = VolumeMountIdentity(device: 1, inode: 2, createdSeconds: 3, createdNanoseconds: 4)
        model.volumes = [candidate]
        await model.refreshTimeMachineMounts { _ in [:] }
        #expect(!model.canAnalyzeVolume(candidate))
        let marks = PausedRead<[String: AppModel.TimeMachineStatus]>()
        let first = try #require(model.scheduleTimeMachineRetry { _ in await marks.read() ?? [:] })
        await marks.waitUntilStarted()
        let same = try #require(model.scheduleTimeMachineRetry { _ in
            Issue.record("Une deuxième demande ne doit pas relire le même montage")
            return [:]
        })
        marks.finish(with: [root.path: .ordinary])
        await first.value
        await same.value
        #expect(model.canAnalyzeVolume(candidate))
        #expect(model.scheduleTimeMachineRetry() == nil)
    }

    @Test("L’aperçu d’alerte ne prend pas la priorité sur une mesure reçue en cours de lecture")
    @MainActor func alertPreviewDoesNotSupersedeNewerSample() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: root)
        let old = volume(at: root, boot: true, free: 100)
        let newest = volume(at: root, boot: true, free: 700)
        model.watch.updateBoot(old)
        model.watch.showAlertPreview {
            model.publishReclaimedCapacity(newest.capacity, measuredAt: .now)
            return old
        }
        #expect(model.watch.boot?.capacity == newest.capacity)
        #expect(model.reclaimed == newest.capacity)
    }

    private func volume(at root: URL, boot: Bool, free: Int64, name: String = "Disque fictif") -> VolumeDescriptor {
        VolumeDescriptor(name: name, mountURL: root, scanRoot: root, isBoot: boot, isInternal: boot,
                         isRemovable: false, capacity: Capacity(total: 1000, available: free,
                                                                availableForImportantUsage: free))
    }

    @Test("Le relevé après nettoyage est publié au modèle de la barre des menus")
    @MainActor func publishesReclaimedCapacity() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(home: root)
        let before = Capacity(total: 1000, available: 100, availableForImportantUsage: 100)
        let after = Capacity(total: 1000, available: 300, availableForImportantUsage: 300)
        let boot = VolumeDescriptor(name: "Disque fictif", mountURL: root, scanRoot: root, isBoot: true,
                                    isInternal: true, isRemovable: false, capacity: before)
        model.volumes = [boot]
        model.watch.updateBoot(boot)
        model.publishReclaimedCapacity(after)
        #expect(model.watch.boot?.capacity == after)
        #expect(model.bootVolume?.capacity == after)
        #expect(model.volumes.first?.capacity == after)
    }
}


private struct PausedRead<Value: Sendable>: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let result = AsyncStream<Value>.makeStream()

    func read() async -> Value? {
        entered.continuation.yield(())
        entered.continuation.finish()
        var values = result.stream.makeAsyncIterator()
        return await values.next()
    }

    func waitUntilStarted() async {
        var signals = entered.stream.makeAsyncIterator()
        _ = await signals.next()
    }

    func finish(with value: Value) {
        result.continuation.yield(value)
        result.continuation.finish()
    }
}
