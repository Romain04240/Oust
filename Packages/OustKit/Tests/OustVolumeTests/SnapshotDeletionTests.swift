import Foundation
import Testing
import Synchronization
@testable import OustVolume
import OustCore
import OustHelperContract

@Suite("Suppression des snapshots : bilan vérifié et repli borné")
struct SnapshotDeletionTests {
    let first = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-18-101500.local")
    let second = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-19-101500.local")

    @Test("Un succès partiel n'efface pas l'échec de l'autre snapshot")
    func partial() async {
        var reads = 0
        let result = await VolumeService.deleteSnapshotResults([first, second], listing: {
            reads += 1
            return reads == 1 ? [first, second] : [second]
        }, helper: { _ in .answered(DeletionResponse(results: [
            .init(date: first.date!, outcome: .deleted), .init(date: second.date!, outcome: .failed, message: "busy")
        ])) }, administrator: { _ in Issue.record("Repli inattendu"); return .notRun })
        #expect(result.deleted == [first.date!])
        #expect(result.failures[second.date!] == "busy")
    }

    @Test("Le succès de tmutil ne suffit pas si la date est toujours présente")
    func stillListed() async {
        let result = await VolumeService.deleteSnapshotResults([first], listing: { [first] },
            helper: { _ in .answered(DeletionResponse(results: [.init(date: first.date!, outcome: .deleted)])) },
            administrator: { _ in Issue.record("Repli inattendu"); return .notRun })
        #expect(result.deleted.isEmpty)
        #expect(result.failures[first.date!] == "snapshot.error.unverified")
    }

    @Test("Un démon sans Accès complet au disque laisse l'invite autorisée prendre le relais")
    func permissionFallback() async {
        var reads = 0
        var adminCalls = 0
        let result = await VolumeService.deleteSnapshotResults([first], listing: {
            reads += 1; return reads <= 2 ? [first] : []
        }, helper: { _ in .answered(DeletionResponse(results: [
            .init(date: first.date!, outcome: .failed, message: "Operation not permitted")
        ])) }, administrator: { _ in
            adminCalls += 1
            return CommandResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
        })
        #expect(adminCalls == 1)
        #expect(result.deleted == [first.date!])
    }

    @Test("Le repli ne rejoue pas les dates déjà supprimées par le démon")
    func partialPermissionFallback() async {
        var reads = 0
        var retried: [LocalSnapshot] = []
        let result = await VolumeService.deleteSnapshotResults([first, second], listing: {
            reads += 1
            return reads == 1 ? [first, second] : reads == 2 ? [second] : []
        }, helper: { _ in .answered(DeletionResponse(results: [
            .init(date: first.date!, outcome: .deleted),
            .init(date: second.date!, outcome: .failed, message: "Operation not permitted")
        ])) }, administrator: { snapshots in
            retried = snapshots
            return CommandResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
        })
        #expect(retried == [second])
        #expect(result.deleted == [first.date!, second.date!])
    }

    @Test("Un délai expiré ne rejoue jamais la commande en administrateur")
    func timeout() async {
        let result = await VolumeService.deleteSnapshotResults([first], listing: { [first] }, helper: { _ in .timedOut },
            administrator: { _ in Issue.record("Une demande encore en cours ne doit pas être rejouée"); return .notRun })
        #expect(result.deleted.isEmpty)
        #expect(result.failures[first.date!] == "snapshot.error.timeout")
    }

    @Test("Une liste illisible n'autorise aucune suppression")
    func unreadable() async {
        let result = await VolumeService.deleteSnapshotResults([first], listing: { nil },
            helper: { _ in Issue.record("Ne doit pas être appelé"); return .unreachable },
            administrator: { _ in Issue.record("Ne doit pas être appelé"); return .notRun })
        #expect(result.failures[first.date!] == "snapshot.error.listing")
    }

    @Test("Plus de 64 snapshots passent en lots conformes au contrat")
    func chunks() async {
        let snapshots = (0..<65).map { LocalSnapshot(name: String(format: "com.apple.TimeMachine.2026-10-18-10%02d%02d.local", $0 / 60, $0 % 60)) }
        var remaining = snapshots
        var calls: [Int] = []
        let result = await VolumeService.deleteSnapshotResults(snapshots, listing: { remaining }, helper: { dates in
            calls.append(dates.count)
            remaining.removeAll { dates.contains($0.date ?? "") }
            return .answered(DeletionResponse(results: dates.map { .init(date: $0, outcome: .deleted) }))
        }, administrator: { _ in Issue.record("Repli inattendu"); return .notRun })
        #expect(calls == [64, 1])
        #expect(result.deleted.count == 65)
    }

    @Test("L'arrêt pendant le contrôle du composant empêche l'invite administrateur")
    func cancellationBeforeAdministrator() async {
        let cancelled = Mutex(false)
        let phases = Mutex<[CleanupPhase]>([])
        let result = await VolumeService.deleteSnapshotResults([first], listing: { [first] }, helper: { _ in
            cancelled.withLock { $0 = true }
            return .unreachable
        }, administrator: { _ in
            Issue.record("Aucune nouvelle suppression après Arrêter")
            return .notRun
        }, isCancelled: { cancelled.withLock { $0 } }, progress: { phase in phases.withLock { $0.append(phase) } })
        #expect(result.failures[first.date!] == "snapshot.error.cancelled")
        #expect(phases.withLock { $0 } == [.revalidating, .checkingSnapshotComponent, .revalidating])
    }

    @Test("L'arrêt entre deux lots garde le bilan du lot déjà terminé")
    func cancellationBetweenChunks() async {
        let snapshots = (0..<65).map { LocalSnapshot(name: String(format: "com.apple.TimeMachine.2026-10-18-10%02d%02d.local", $0 / 60, $0 % 60)) }
        let cancelled = Mutex(false)
        var remaining = snapshots
        var calls = 0
        let result = await VolumeService.deleteSnapshotResults(snapshots, listing: { remaining }, helper: { dates in
            calls += 1
            remaining.removeAll { dates.contains($0.date ?? "") }
            cancelled.withLock { $0 = true }
            return .answered(DeletionResponse(results: dates.map { .init(date: $0, outcome: .deleted) }))
        }, administrator: { _ in Issue.record("Repli inattendu"); return .notRun },
        isCancelled: { cancelled.withLock { $0 } })
        #expect(calls == 1)
        #expect(result.deleted.count == 64)
        #expect(result.failures[snapshots.last!.date!] == "snapshot.error.cancelled")
    }

    @Test("L'autorisation et la suppression macOS sont annoncées ensemble puis vérifiées")
    func fallbackPhases() async {
        let phases = Mutex<[CleanupPhase]>([])
        var reads = 0
        _ = await VolumeService.deleteSnapshotResults([first], listing: {
            reads += 1
            return reads < 3 ? [first] : []
        }, helper: { _ in .unreachable }, administrator: { _ in
            CommandResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
        }, progress: { phase in phases.withLock { $0.append(phase) } })
        #expect(phases.withLock { $0 } == [.revalidating, .checkingSnapshotComponent, .revalidating,
                                         .authorizingSnapshots(count: 1), .verifyingSnapshots])
    }

}
