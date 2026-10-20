import Foundation
import Testing
import OustCore

@Suite("Progression du nettoyage sans estimation inventée")
struct CleanupProgressTests {
    @Test("Les horloges totale et de phase sont indépendantes et monotones")
    func elapsedTimes() {
        let start = ContinuousClock.now
        var progress = CleanupProgress(total: 3, now: start)
        progress.receive(.phaseChanged(.checkingSnapshotComponent, itemIDs: ["a", "b"]), now: start + .seconds(2))
        #expect(progress.elapsed(at: start + .seconds(9)) == .seconds(9))
        #expect(progress.phaseElapsed(at: start + .seconds(9)) == .seconds(7))
        progress.receive(.phaseChanged(.deletingSnapshots(count: 2), itemIDs: ["a", "b"]), now: start + .seconds(12))
        #expect(progress.elapsed(at: start + .seconds(15)) == .seconds(15))
        #expect(progress.phaseElapsed(at: start + .seconds(15)) == .seconds(3))
        #expect(progress.completed == 0)
        #expect(progress.total == 3)
    }

    @Test("Un lot opaque reste en cours sans avancer le compteur")
    func batchAndParallelPhases() {
        let start = ContinuousClock.now
        var progress = CleanupProgress(total: 3, now: start)
        progress.receive(.phaseChanged(.deletingSnapshots(count: 2), itemIDs: ["a", "b"]), now: start)
        progress.receive(.phaseChanged(.journaling, itemIDs: ["c"]), now: start + .seconds(20))
        #expect(progress.phase == .deletingSnapshots(count: 2))
        #expect(progress.phaseElapsed(at: start + .seconds(25)) == .seconds(25))
        #expect(progress.completed == 0)
    }

    @Test("Un élément traité compte une fois, même s'il est laissé en place")
    func completedCount() {
        let item = CleanupItem(id: "a", title: "a", paths: [], category: .snapshots,
            owner: "test", ruleID: "snapshot.time_machine", safety: .review,
            method: .localSnapshot(date: "2026-10-18-101500"), rebuild: .irreversible)
        let outcome = CleanupOutcome(sessionID: UUID(), date: .now, item: item, result: .skipped(.cancelled), bytes: 0)
        var progress = CleanupProgress(total: 2)
        progress.receive(.itemBegan(id: item.id))
        progress.receive(.itemFinished(outcome))
        progress.receive(.itemFinished(outcome))
        #expect(progress.completed == 1)
        #expect(progress.total == 2)
    }
}
