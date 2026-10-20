import Foundation
import Testing
import Synchronization
@testable import OustClean
import OustCore
import OustSafety
import OustVolume

@Suite("Phases et arrêt au dernier moment")
struct CleanupPhaseTests {
    @Test("Préparation, revalidation, suppression, journal puis mesure suivent le travail")
    func phases() async throws {
        let bench = try Bench()
        let file = try bench.file("cache/test.bin")
        let (events, report) = await bench.run([bench.item(file)])
        let phases = events.compactMap { event -> CleanupPhase? in
            if case .phaseChanged(let phase, _) = event { return phase }
            return nil
        }
        #expect(phases == [.preparing, .revalidating, .deleting, .journaling, .measuring])
        #expect(report?.succeeded.count == 1)
    }

    @Test("Arrêter pendant une revalidation empêche encore la mise à la corbeille")
    func cancelledAfterValidation() async throws {
        let bench = try Bench()
        let file = try bench.file("maison/Library/CloudStorage/Provider/note.txt")
        let cancellation = CleanupCancellation()
        let engine = CleanupEngine(trasher: FolderTrasher(folder: bench.trash), history: nil,
            pathGuard: PathGuard(home: bench.root.appendingPathComponent("maison")),
            processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil },
            deleteSnapshots: { _ in false }, runningApps: { [] },
            cloudConnection: { _, _, _ in
                cancellation.cancel()
                return .connected
            })
        var report: CleanupReport?
        for await event in engine.run([bench.item(file, method: .trashFromCloud, safety: .review)], cancellation: cancellation) {
            if case .finished(let final) = event { report = final }
        }
        #expect(report?.outcomes.first?.result == .skipped(.cancelled))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Tous les snapshots du lot sont annoncés avant de recevoir son résultat")
    func snapshotBatchIsHonest() async {
        let dates = ["2026-10-18-101500", "2026-10-19-101500"]
        let items = dates.map { date in
            CleanupItem(title: date, paths: [], category: .snapshots, owner: "test", ruleID: "snapshot.time_machine",
                safety: .review, method: .localSnapshot(date: date), rebuild: .irreversible)
        }
        let engine = CleanupEngine(history: nil, processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil },
            snapshotResults: { _ in .init(deleted: Set(dates)) }, runningApps: { [] })
        var begun: Set<String> = []
        var receivedBatch = false
        for await event in engine.run(items) {
            switch event {
            case .itemBegan(let id): begun.insert(id)
            case .phaseChanged(.deletingSnapshots(let count), let ids):
                #expect(count == 2)
                #expect(Set(ids) == Set(items.map(\.id)))
                #expect(begun == Set(ids))
                receivedBatch = true
            case .itemFinished: #expect(receivedBatch)
            default: break
            }
        }
        #expect(receivedBatch)
    }

    @Test("Une activité apparue pendant le contrôle SHA conserve l'archive originale", arguments: [0, 1, 2])
    func archiveProcessRefresh(mode: Int) async throws {
        let bench = try Bench()
        let original = bench.root.appendingPathComponent("projet")
        let copy = bench.root.appendingPathComponent("copie")
        try bench.file("projet/main.swift", byte: 3)
        try bench.file("copie/main.swift", byte: 3)
        let reads = Mutex(0)
        let late = switch mode {
        case 0: ProcessSnapshot(processes: [ActiveProcess(pid: 42, name: "agent", workingDirectory: original.path)])
        case 1: ProcessSnapshot(processes: [ActiveProcess(pid: 42, name: "outil", workingDirectory: "/", executablePath: original.appendingPathComponent("bin/tool").path)])
        default: ProcessSnapshot(processes: [], isComplete: false)
        }
        let engine = CleanupEngine(trasher: FolderTrasher(folder: bench.trash), history: nil,
            pathGuard: PathGuard(home: bench.root.appendingPathComponent("maison")),
            processes: {
                let read = reads.withLock { value in value += 1; return value }
                return read == 1 ? ProcessSnapshot(processes: []) : late
            }, capacity: { _ in nil }, deleteSnapshots: { _ in false }, runningApps: { [] })
        let item = bench.item(original, method: .archive(copy: copy.path), safety: .review)
        var report: CleanupReport?
        for await event in engine.run([item]) {
            if case .finished(let final) = event { report = final }
        }
        let expected: SkipReason = switch mode {
        case 0: .nowProtected(.activeProcess(name: "agent"))
        case 1: .nowProtected(.appRunning(name: "outil"))
        default: .nowProtected(.unknownState)
        }
        #expect(report?.outcomes.first?.result == .skipped(expected))
        #expect(reads.withLock { $0 } == 2)
        #expect(FileManager.default.fileExists(atPath: original.appendingPathComponent("main.swift").path))
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("main.swift").path))
        #expect(!FileManager.default.fileExists(atPath: bench.trash.path))
    }

}
