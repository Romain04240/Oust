import Foundation
import Synchronization
import Testing
import OustHelperContract
@testable import OustHelperDaemon

/// Un `tmutil` de théâtre : il tient une liste de snapshots et note ce qu'on
/// lui demande. Aucun test ne supprime de vrai snapshot.
final class FakeSnapshotTool: SnapshotTool {
    private struct State {
        var listed: [String]
        var listingWorks = true
        var failing: Set<String> = []
        /// Un `tmutil` qui dit « fait » sans rien faire.
        var lies = false
        var deletions: [String] = []
        var listings = 0
    }

    private let state: Mutex<State>

    init(listed: [String], listingWorks: Bool = true, failing: Set<String> = [], lies: Bool = false) {
        state = Mutex(State(listed: listed, listingWorks: listingWorks, failing: failing, lies: lies))
    }

    var deletions: [String] { state.withLock { $0.deletions } }
    var listings: Int { state.withLock { $0.listings } }

    func listLocalSnapshots() -> String? {
        state.withLock { state in
            state.listings += 1
            guard state.listingWorks else { return nil }
            return "Snapshots for disk /System/Volumes/Data:\n" + state.listed.joined(separator: "\n")
        }
    }

    func deleteLocalSnapshot(date: String) -> String? {
        state.withLock { state in
            state.deletions.append(date)
            if state.failing.contains(date) { return "Failed to delete local snapshot" }
            if !state.lies { state.listed.removeAll { $0 == SnapshotDates.snapshotName(for: date) } }
            return nil
        }
    }
}

@Suite("Démon : ce qu'il fait d'une demande")
struct HelperServiceTests {

    static let listing = [
        "com.apple.TimeMachine.2026-10-17-014534.local",
        "com.apple.TimeMachine.2026-10-17-024519.local",
        "com.apple.os.update-5D8A1C0E.1",
    ]

    @Test("Les dates présentes et bien formées sont supprimées, une à une")
    func deletesListedDates() {
        let tool = FakeSnapshotTool(listed: Self.listing)
        let response = HelperService.handle(["2026-10-17-014534", "2026-10-17-024519"],
                                            contractVersion: HelperContract.version, tool: tool)
        #expect(response.refusal == nil)
        #expect(response.results.map(\.outcome) == [.deleted, .deleted])
        #expect(tool.deletions == ["2026-10-17-014534", "2026-10-17-024519"])
        #expect(response.deletedAll(["2026-10-17-014534", "2026-10-17-024519"]))
    }

    @Test("Une date mal formée n'atteint jamais tmutil, même mêlée à de bonnes")
    func malformedNeverReachesTheTool() {
        let tool = FakeSnapshotTool(listed: Self.listing)
        let response = HelperService.handle(["/", "2026-10-17-014534; rm -rf /", "2026-10-17-014534"],
                                            contractVersion: HelperContract.version, tool: tool)
        #expect(response.results.map(\.outcome) == [.malformed, .malformed, .deleted])
        #expect(tool.deletions == ["2026-10-17-014534"])
        #expect(!response.deletedAll(["/", "2026-10-17-014534"]))
    }

    @Test("Une date sans snapshot Time Machine correspondant n'est pas transmise")
    func unlistedNeverReachesTheTool() {
        let tool = FakeSnapshotTool(listed: Self.listing)
        let response = HelperService.handle(["2026-10-18-004536"], contractVersion: HelperContract.version, tool: tool)
        #expect(response.results.map(\.outcome) == [.notListed])
        #expect(tool.deletions.isEmpty)
    }

    @Test("Un snapshot de mise à jour du système n'est jamais visé, même sous une date")
    func neverTouchesSystemSnapshots() {
        let tool = FakeSnapshotTool(listed: ["com.apple.os.update-2026-10-17-014534.local"])
        let response = HelperService.handle(["2026-10-17-014534"], contractVersion: HelperContract.version, tool: tool)
        #expect(response.results.map(\.outcome) == [.notListed])
        #expect(tool.deletions.isEmpty)
    }

    @Test("Les demandes refusées en bloc ne font rien, pas même lister", arguments: [
        (dates: [String](), version: HelperContract.version, refusal: RequestRefusal.empty),
        (dates: ["2026-10-17-014534"], version: HelperContract.version + 1, refusal: .contractMismatch),
        (dates: Array(repeating: "2026-10-17-014534", count: HelperContract.maximumSnapshotsPerRequest + 1),
         version: HelperContract.version, refusal: .tooMany),
    ])
    func refusesWholeRequests(dates: [String], version: Int, refusal: RequestRefusal) {
        let tool = FakeSnapshotTool(listed: Self.listing)
        let response = HelperService.handle(dates, contractVersion: version, tool: tool)
        #expect(response.refusal == refusal)
        #expect(response.results.isEmpty)
        #expect(tool.listings == 0)
        #expect(tool.deletions.isEmpty)
    }

    @Test("Une liste illisible arrête tout : rien n'est comparable, rien n'est supprimé")
    func unreadableListingRefusesAll() {
        let tool = FakeSnapshotTool(listed: Self.listing, listingWorks: false)
        let response = HelperService.handle(["2026-10-17-014534"], contractVersion: HelperContract.version, tool: tool)
        #expect(response.refusal == .listingFailed)
        #expect(tool.deletions.isEmpty)
    }

    @Test("Un échec de tmutil est rapporté pour sa date seulement")
    func reportsFailures() {
        let tool = FakeSnapshotTool(listed: Self.listing, failing: ["2026-10-17-014534"])
        let response = HelperService.handle(["2026-10-17-014534", "2026-10-17-024519"],
                                            contractVersion: HelperContract.version, tool: tool)
        #expect(response.results.map(\.outcome) == [.failed, .deleted])
        #expect(response.results.first?.message == "Failed to delete local snapshot")
        #expect(!response.deletedAll(["2026-10-17-014534", "2026-10-17-024519"]))
    }

    @Test("Un snapshot encore listé après coup n'est pas annoncé supprimé")
    func distrustsAToolThatLies() {
        let tool = FakeSnapshotTool(listed: Self.listing, lies: true)
        let response = HelperService.handle(["2026-10-17-014534"], contractVersion: HelperContract.version, tool: tool)
        #expect(response.results.map(\.outcome) == [.failed])
    }

    @Test("Une date demandée deux fois n'est traitée qu'une fois")
    func deduplicates() {
        let tool = FakeSnapshotTool(listed: Self.listing)
        let response = HelperService.handle(["2026-10-17-014534", "2026-10-17-014534"],
                                            contractVersion: HelperContract.version, tool: tool)
        #expect(response.results.count == 1)
        #expect(tool.deletions == ["2026-10-17-014534"])
    }

    @Test("La réponse traverse la frontière sans rien perdre")
    func responseRoundTrip() throws {
        let response = DeletionResponse(results: [
            .init(date: "2026-10-17-014534", outcome: .deleted),
            .init(date: "2026-10-17-024519", outcome: .failed, message: "busy"),
        ])
        #expect(DeletionResponse(dictionary: response.dictionary) == response)
        #expect(DeletionResponse(dictionary: DeletionResponse.refused(.tooMany).dictionary)?.refusal == .tooMany)
    }

    @Test("Une réponse d'un autre contrat ou mal formée n'est jamais lue comme un succès")
    func distrustsMalformedResponses() {
        let otherVersion: NSDictionary = [HelperContract.Key.contractVersion: HelperContract.version + 1,
                                          HelperContract.Key.results: [[String: Any]]()]
        let unknownOutcome: NSDictionary = [
            HelperContract.Key.contractVersion: HelperContract.version,
            HelperContract.Key.results: [[HelperContract.Key.date: "2026-10-17-014534",
                                          HelperContract.Key.outcome: "probably"]],
        ]
        let unknownRefusal: NSDictionary = [HelperContract.Key.contractVersion: HelperContract.version,
                                            HelperContract.Key.refusal: "maybe",
                                            HelperContract.Key.results: [[String: Any]]()]
        #expect(DeletionResponse(dictionary: otherVersion) == nil)
        #expect(DeletionResponse(dictionary: unknownOutcome) == nil)
        #expect(DeletionResponse(dictionary: unknownRefusal) == nil)
        #expect(DeletionResponse(dictionary: [:]) == nil)
    }

    @Test("Le démon s'en va quand personne ne s'en sert, jamais au milieu d'une demande")
    func idleMonitor() {
        let monitor = IdleMonitor(idle: 3600) {}
        monitor.begin()
        #expect(!monitor.isIdle(at: Date().addingTimeInterval(7200)))
        monitor.end()
        #expect(!monitor.isIdle(at: Date()))
        #expect(monitor.isIdle(at: Date().addingTimeInterval(7200)))
    }
}
