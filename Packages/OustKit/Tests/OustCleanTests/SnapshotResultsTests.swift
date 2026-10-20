import Foundation
import Testing
import OustClean
import OustCore
import OustSafety
import OustVolume

@Suite("Bilan individuel des snapshots")
struct SnapshotResultsTests {
    @Test("Un snapshot supprimé est réussi même si son voisin échoue")
    func partial() async throws {
        let dates = ["2026-10-18-101500", "2026-10-19-101500"]
        let items = dates.map { date in
            CleanupItem(title: date, paths: [], category: .snapshots, owner: "Time Machine",
                ruleID: "snapshot.time_machine", safety: .review, method: .localSnapshot(date: date), rebuild: .irreversible)
        }
        let engine = CleanupEngine(history: nil, processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil },
            snapshotResults: { _ in .init(deleted: [dates[0]], failures: [dates[1]: "busy"]) }, runningApps: { [] })
        var report: CleanupReport?
        for await event in engine.run(items) {
            if case .finished(let final) = event { report = final }
        }
        let outcomes = try #require(report?.outcomes)
        #expect(outcomes.map(\.result) == [.delegated, .failed(message: "busy")])
        #expect(outcomes.allSatisfy { $0.bytes == 0 })
    }
}
