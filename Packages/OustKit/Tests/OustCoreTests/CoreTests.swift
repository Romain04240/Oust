import Foundation
import Testing
@testable import OustCore

@Suite("Le domaine")
struct CoreTests {
    func item(_ safety: SafetyClass, lastActivity: Date? = nil, protections: [ProtectionReason] = [],
              method: CleanupMethod = .removeNow) -> CleanupItem {
        CleanupItem(title: "x", paths: [URL(fileURLWithPath: "/tmp/x")], category: .projectArtifacts, owner: "p",
                    ruleID: "artifact.node_modules", safety: safety, protections: protections, method: method,
                    sizes: Sizes(private: 100), lastActivity: lastActivity, rebuild: .automatic)
    }

    @Test("Seul le sûr, et le régénérable ancien, sont présélectionnés")
    func preselection() {
        let policy = PreselectionPolicy(recencyDays: 7)
        let now = Date()
        #expect(policy.preselects(item(.safe), now: now))
        #expect(policy.preselects(item(.rebuilds, lastActivity: now.addingTimeInterval(-10 * 86_400)), now: now))
        #expect(!policy.preselects(item(.rebuilds, lastActivity: now.addingTimeInterval(-2 * 86_400)), now: now))
        #expect(!policy.preselects(item(.rebuilds), now: now), "sans date connue, on ne coche pas")
        #expect(!policy.preselects(item(.review), now: now))
    }

    @Test("Une protection rend l'élément non sélectionnable, quelle que soit sa classe")
    func protectionWins() {
        let protected = item(.safe, protections: [.inUse])
        #expect(protected.safety == .protected)
        #expect(!protected.isSelectable)
        var later = item(.safe)
        later.protect(.booted)
        #expect(!later.isSelectable)
        #expect(!item(.review, method: .manual).isSelectable)
    }

    @Test("La part libérable ne dépasse jamais la part allouée")
    func sizes() {
        let sizes = Sizes(allocated: 100, freeable: 250)
        #expect(sizes.freeable == 100)
        #expect((Sizes(allocated: 100, freeable: 40) + Sizes(private: 10)).retained == 60)
    }

    @Test("Le bilan distingue l'immédiat, la corbeille et ce qui est retenu")
    func report() {
        let session = UUID()
        let removed = CleanupOutcome(sessionID: session, date: Date(), item: item(.safe), result: .removed, bytes: 1_000)
        let trashed = CleanupOutcome(sessionID: session, date: Date(), item: item(.review, method: .trash),
                                     result: .trashed, bytes: 400)
        let report = CleanupReport(sessionID: session, startedAt: Date(), finishedAt: Date(),
                                   outcomes: [removed, trashed], availableBefore: 10_000, availableAfter: 10_300)
        #expect(report.expectedNow == 1_000)
        #expect(report.pendingInTrash == 400)
        #expect(report.measuredNow == 300)
        #expect(report.heldBack == 700)
    }

    @Test("Seules les dates bien formées passent", arguments: [
        ("2026-10-17-014534", true), ("2026-10-17-01453", false), ("2026-10-17-0145345", false),
        ("2026/10/17-014534", false), ("2026-1O-17-014534", false),
    ])
    func snapshotDates(value: String, valid: Bool) {
        #expect(LocalSnapshot.isValidDate(value) == valid)
    }
}
