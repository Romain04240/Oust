import Foundation
import Synchronization
import Testing
@testable import OustClean
import OustCore
import OustVolume

/// Un disque Time Machine de théâtre : une liste qu'on relit, une suppression
/// qui note ce qu'on lui demande. Aucun test ne supprime de vraie sauvegarde.
final class FakeBackupDisk: Sendable {
    struct State {
        var listed: [String]
        var id = "72FAB8EC-02B0-4438-99CF-7457FF567141"
        var mountPoint = "/Volumes/Time Machine"
        var isDestination = true
        var readable = true
        var running = false
        var reply = BackupDeletionReply(path: .administrator)
        /// Supprime vraiment de la liste ce qu'on lui demande.
        var obeys = true
        /// Retire de la liste, juste avant d'agir, ce que Time Machine aurait éclairci.
        var thinnedBeforeActing: [String] = []
        var requests: [[String]] = []
        var listings = 0
        var available: Int64 = 10_000_000_000
    }

    let state: Mutex<State>

    init(_ listed: [String], configure: (inout State) -> Void = { _ in }) {
        var initial = State(listed: listed)
        configure(&initial)
        state = Mutex(initial)
    }

    var requests: [[String]] { state.withLock { $0.requests } }

    var system: BackupPruner.System {
        BackupPruner.System(
            listing: { _ in self.listing() },
            delete: { timestamps, _ in self.delete(timestamps) },
            capacity: { _ in
                self.state.withLock { Capacity(total: 2_000_000_000_000, available: $0.available,
                                               availableForImportantUsage: $0.available) }
            })
    }

    func listing() -> TimeMachineListing {
        state.withLock { state in
            state.listings += 1
            guard state.isDestination else { return .notADestination }
            guard state.readable else { return .unreadable(mountPoint: state.mountPoint) }
            if state.listings == 1, !state.thinnedBeforeActing.isEmpty {
                state.listed.removeAll(where: state.thinnedBeforeActing.contains)
            }
            return .listed(TimeMachineDestination(
                id: state.id, name: "Time Machine", mountPoint: state.mountPoint,
                backups: state.listed.compactMap(TimeMachineBackup.init(timestamp:)), isBackupRunning: state.running))
        }
    }

    func delete(_ timestamps: [String]) -> BackupDeletionReply {
        state.withLock { state in
            state.requests.append(timestamps)
            if state.obeys, state.reply.refusal == nil {
                state.listed.removeAll(where: timestamps.contains)
                state.available += 4_000_000_000 * Int64(timestamps.count)
            }
            return state.reply
        }
    }
}

@Suite("Garder les N dernières sauvegardes Time Machine")
struct BackupPrunerTests {

    static let timestamps = ["2025-03-03-101530", "2025-06-12-084512", "2025-09-14-221004", "2026-01-05-120000",
                             "2026-10-16-093012", "2026-10-17-093544", "2026-10-18-083015"]
    static let backups = timestamps.compactMap(TimeMachineBackup.init(timestamp:))

    static func destination(_ timestamps: [String] = timestamps, running: Bool = false) -> TimeMachineDestination {
        TimeMachineDestination(id: "72FAB8EC-02B0-4438-99CF-7457FF567141", name: "Time Machine",
                               mountPoint: "/Volumes/Time Machine",
                               backups: timestamps.compactMap(TimeMachineBackup.init(timestamp:)),
                               isBackupRunning: running)
    }

    // MARK: Le plan

    @Test("Garder 3 sur 7 : les 4 plus anciennes partent, dans l'ordre")
    func keepThree() {
        let plan = BackupPruner.plan(Self.backups, keeping: 3)
        #expect(plan.map(\.timestamp) == Array(Self.timestamps.prefix(4)))
        #expect(BackupPruner.defaultKept == 3)
    }

    @Test("La plus récente n'est jamais dans le plan, quel que soit N", arguments: 1...8)
    func neverTheLatest(keep: Int) {
        let plan = BackupPruner.plan(Self.backups.shuffled(), keeping: keep)
        #expect(!plan.contains(Self.backups[6]))
        #expect(plan.count == max(0, Self.backups.count - keep))
    }

    @Test("N sous le minimum : rien ne part", arguments: [0, -1, Int.min])
    func belowMinimum(keep: Int) {
        #expect(BackupPruner.plan(Self.backups, keeping: keep).isEmpty)
        #expect(BackupPruner.refusal(deleting: [Self.backups[0]], keeping: keep, in: Self.destination())
                == .keepAtLeastOne)
    }

    @Test("Une seule sauvegarde, ou aucune : rien à proposer")
    func tooFew() {
        #expect(BackupPruner.plan([Self.backups[0]], keeping: 1).isEmpty)
        #expect(BackupPruner.plan([], keeping: 1).isEmpty)
        #expect(BackupPruner.plan(Self.backups + Self.backups, keeping: 7).isEmpty)
    }

    // MARK: Les gardes

    @Test("Les gardes : la plus récente, rien à faire, sauvegarde en cours, liste changée")
    func refusals() {
        let shown = Self.destination()
        let plan = BackupPruner.plan(Self.backups, keeping: 3)
        #expect(BackupPruner.refusal(deleting: plan, keeping: 3, in: shown) == nil)
        #expect(BackupPruner.refusal(deleting: [Self.backups[6]], keeping: 1, in: shown) == .latest)
        #expect(BackupPruner.refusal(deleting: [], keeping: 3, in: shown) == .nothingToDelete)
        #expect(BackupPruner.refusal(deleting: plan, keeping: 3, in: Self.destination(running: true)) == .backupRunning)
        // Plus que deux sauvegardes au-delà de celles qu'on supprime : on en garderait moins de 3.
        #expect(BackupPruner.refusal(deleting: Array(Self.backups.prefix(5)), keeping: 3, in: shown) == .changed)
        let elsewhere = TimeMachineBackup(timestamp: "2024-01-01-000000")!
        #expect(BackupPruner.refusal(deleting: [elsewhere], keeping: 3, in: shown) == .nothingToDelete)
    }

    // MARK: La suppression

    @Test("Revalidé, supprimé, confirmé par la liste relue, journalisé une à une")
    func prunes() async throws {
        let bench = try Bench()
        let disk = FakeBackupDisk(Self.timestamps)
        let plan = BackupPruner.plan(Self.backups, keeping: 3)
        let report = await BackupPruner.prune(plan, keeping: 3, shown: Self.destination(), system: disk.system,
                                              history: HistoryStore(directory: bench.historyFolder))
        #expect(report.refusal == nil)
        #expect(report.deleted == plan)
        #expect(report.failed.isEmpty)
        #expect(disk.requests == [plan.map(\.timestamp)])
        #expect(report.availableBefore == 10_000_000_000)
        #expect(report.availableAfter == 26_000_000_000)

        let lines = await HistoryStore(directory: bench.historyFolder).load()
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.result == .delegated && $0.bytes == 0 && $0.category == .snapshots })
        #expect(lines.allSatisfy { $0.owner == "Time Machine" && $0.paths == ["/Volumes/Time Machine"] })
        #expect(Set(lines.map(\.method)) == Set(plan.map {
            CleanupMethod.timeMachineBackup(destination: "/Volumes/Time Machine", timestamp: $0.timestamp)
        }))
        #expect(lines.allSatisfy { $0.origin == .app })
    }

    @Test("La plus récente glissée dans la demande : rien ne part")
    func latestRefused() async throws {
        let bench = try Bench()
        let disk = FakeBackupDisk(Self.timestamps)
        let report = await BackupPruner.prune([Self.backups[0], Self.backups[6]], keeping: 1, shown: Self.destination(),
                                              system: disk.system, history: HistoryStore(directory: bench.historyFolder))
        #expect(report.refusal == .latest)
        #expect(disk.requests.isEmpty)
        #expect(await HistoryStore(directory: bench.historyFolder).load().isEmpty)
    }

    @Test("Juste avant d'agir : disque débranché, autre disque, liste illisible, sauvegarde lancée")
    func revalidates() async throws {
        let plan = BackupPruner.plan(Self.backups, keeping: 3)
        let cases: [((inout FakeBackupDisk.State) -> Void, BackupPruneRefusal)] = [
            ({ $0.isDestination = false }, .unknownDestination),
            ({ $0.id = "AUTRE-DISQUE" }, .unknownDestination),
            ({ $0.mountPoint = "/Volumes/Time Machine 1" }, .unknownDestination),
            ({ $0.readable = false }, .unreadable),
            ({ $0.running = true }, .backupRunning),
        ]
        for (configure, expected) in cases {
            let bench = try Bench()
            let disk = FakeBackupDisk(Self.timestamps, configure: configure)
            let report = await BackupPruner.prune(plan, keeping: 3, shown: Self.destination(), system: disk.system,
                                                  history: HistoryStore(directory: bench.historyFolder))
            #expect(report.refusal == expected)
            #expect(disk.requests.isEmpty)
            #expect(report.deleted.isEmpty)
            #expect(await HistoryStore(directory: bench.historyFolder).load().isEmpty)
        }
    }

    @Test("Une sauvegarde éclaircie par Time Machine entre-temps : laissée, notée « n'existe plus »")
    func vanished() async throws {
        let bench = try Bench()
        let disk = FakeBackupDisk(Self.timestamps) { $0.thinnedBeforeActing = ["2025-06-12-084512"] }
        let plan = BackupPruner.plan(Self.backups, keeping: 3)
        let report = await BackupPruner.prune(plan, keeping: 3, shown: Self.destination(), system: disk.system,
                                              history: HistoryStore(directory: bench.historyFolder))
        #expect(report.refusal == nil)
        #expect(report.vanished.map(\.timestamp) == ["2025-06-12-084512"])
        #expect(disk.requests == [["2025-03-03-101530", "2025-09-14-221004", "2026-01-05-120000"]])
        let lines = await HistoryStore(directory: bench.historyFolder).load()
        #expect(lines.filter { $0.result == .skipped(.vanished) }.count == 1)
        #expect(lines.filter { $0.result == .delegated }.count == 3)
    }

    @Test("Un outil qui dit « fait » sans rien faire : rien n'est annoncé parti")
    func lyingTool() async throws {
        let bench = try Bench()
        let disk = FakeBackupDisk(Self.timestamps) { $0.obeys = false }
        let plan = BackupPruner.plan(Self.backups, keeping: 3)
        let report = await BackupPruner.prune(plan, keeping: 3, shown: Self.destination(), system: disk.system,
                                              history: HistoryStore(directory: bench.historyFolder))
        #expect(report.deleted.isEmpty)
        #expect(report.failed == plan)
        let lines = await HistoryStore(directory: bench.historyFolder).load()
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { if case .failed = $0.result { true } else { false } })
    }

    @Test("Invite fermée sans mot de passe : rien au journal")
    func cancelled() async throws {
        let bench = try Bench()
        let disk = FakeBackupDisk(Self.timestamps) { $0.reply = BackupDeletionReply(path: .administrator, refusal: .cancelled) }
        let plan = BackupPruner.plan(Self.backups, keeping: 3)
        let report = await BackupPruner.prune(plan, keeping: 3, shown: Self.destination(), system: disk.system,
                                              history: HistoryStore(directory: bench.historyFolder))
        #expect(report.refusal == .cancelled)
        #expect(report.deleted.isEmpty)
        #expect(await HistoryStore(directory: bench.historyFolder).load().isEmpty)
    }

    @Test("Une sauvegarde lancée en route : ce qui est parti est noté, le reste laissé pour Time Machine")
    func runningMidway() async throws {
        let bench = try Bench()
        let disk = FakeBackupDisk(Self.timestamps) {
            $0.reply = BackupDeletionReply(path: .helper, refusal: .backupRunning,
                                           messages: ["2025-09-14-221004": "backup_running",
                                                      "2026-01-05-120000": "backup_running"])
            $0.obeys = false
        }
        let plan = BackupPruner.plan(Self.backups, keeping: 3)
        let report = await BackupPruner.prune(plan, keeping: 3, shown: Self.destination(), system: BackupPruner.System(
            listing: { _ in disk.listing() },
            // Le démon supprime les deux premières, puis Time Machine démarre.
            delete: { timestamps, _ in
                disk.state.withLock { $0.listed.removeAll { ["2025-03-03-101530", "2025-06-12-084512"].contains($0) } }
                return disk.delete(timestamps)
            },
            capacity: { _ in nil }), history: HistoryStore(directory: bench.historyFolder))
        #expect(report.refusal == .backupRunning)
        #expect(report.deleted.map(\.timestamp) == ["2025-03-03-101530", "2025-06-12-084512"])
        #expect(report.failed.map(\.timestamp) == ["2025-09-14-221004", "2026-01-05-120000"])
        let lines = await HistoryStore(directory: bench.historyFolder).load()
        #expect(lines.filter { $0.result == .delegated }.count == 2)
        #expect(lines.filter { $0.result == .skipped(.nowProtected(.daemonRunning(name: "Time Machine"))) }.count == 2)
    }

    @Test("Le démon ne répond pas à temps : seul ce qui a disparu de la liste est noté")
    func timedOut() async throws {
        let bench = try Bench()
        let disk = FakeBackupDisk(Self.timestamps) {
            $0.reply = BackupDeletionReply(path: nil, refusal: .timedOut)
        }
        let plan = BackupPruner.plan(Self.backups, keeping: 3)
        let report = await BackupPruner.prune(plan, keeping: 3, shown: Self.destination(), system: BackupPruner.System(
            listing: { _ in disk.listing() },
            delete: { timestamps, _ in
                disk.state.withLock { $0.listed.removeAll { $0 == "2025-03-03-101530" } }
                return disk.delete(timestamps)
            },
            capacity: { _ in nil }), history: HistoryStore(directory: bench.historyFolder))
        #expect(report.refusal == .timedOut)
        #expect(report.deleted.map(\.timestamp) == ["2025-03-03-101530"])
        let lines = await HistoryStore(directory: bench.historyFolder).load()
        #expect(lines.map(\.result) == [.delegated])
    }

    @Test("Les sauvegardes n'entrent jamais par la corbeille : le moteur les refuse")
    func engineRefuses() async throws {
        let bench = try Bench()
        let item = BackupPruner.item(for: Self.backups[0], on: Self.destination(), title: "3 mars 2025")
        let outcome = await bench.engine().perform(item, session: UUID())
        #expect(outcome.result == .skipped(.refusedByGuard))
    }
}
