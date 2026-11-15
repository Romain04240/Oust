import Darwin
import Foundation
import Synchronization
import Testing
@testable import OustClean
import OustCore
import OustSafety

/// Une corbeille du Mac qui prend son temps et compte combien d'appels
/// tournent à la fois.
final class SlowTrasher: Trasher {
    let folder: URL
    let delay: Duration
    let current = Atomic<Int>(0)
    let peak = Atomic<Int>(0)

    init(folder: URL, delay: Duration = .milliseconds(60)) {
        self.folder = folder
        self.delay = delay
    }

    func trash(_ urls: [URL]) async -> [Result<URL, TrashError>] {
        let now = current.add(1, ordering: .relaxed).newValue
        var seen = peak.load(ordering: .relaxed)
        while now > seen {
            let (exchanged, original) = peak.compareExchange(expected: seen, desired: now, ordering: .relaxed)
            if exchanged { break }
            seen = original
        }
        try? await Task.sleep(for: delay)
        current.subtract(1, ordering: .relaxed)
        return await FolderTrasher(folder: folder).trash(urls)
    }
}

@Suite("La suppression instantanée, par le dossier de transit")
struct TransitTests {

    func engine(_ bench: Bench, transit: Transit?, trasher: (any Trasher)? = nil) -> CleanupEngine {
        CleanupEngine(
            trasher: trasher ?? FolderTrasher(folder: bench.trash),
            history: HistoryStore(directory: bench.historyFolder),
            pathGuard: PathGuard(home: bench.root.appendingPathComponent("maison")),
            processes: { ProcessSnapshot(processes: []) },
            capacity: { _ in nil },
            deleteSnapshots: { _ in false },
            transit: transit,
            allowsPathBasedRemoval: true
        )
    }

    func run(_ engine: CleanupEngine, _ items: [CleanupItem],
             cancellation: CleanupCancellation? = nil) async -> (events: [CleanupEvent], report: CleanupReport?) {
        var events: [CleanupEvent] = []
        var report: CleanupReport?
        for await event in engine.run(items, cancellation: cancellation) {
            events.append(event)
            if case .finished(let final) = event { report = final }
        }
        return (events, report)
    }

    func contents(_ folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    @Test("Le régénérable quitte sa place d'un renommage, puis est effacé en arrière-plan")
    func movesThenPurges() async throws {
        let bench = try Bench()
        let folder = bench.root.appendingPathComponent("app/node_modules")
        for index in 0..<200 { try bench.file("app/node_modules/paquet\(index % 10)/f\(index).js") }
        try bench.file("app/src/main.js")
        let transit = Transit(directory: bench.root.appendingPathComponent("support/.transit"))

        let (_, report) = await run(engine(bench, transit: transit), [bench.item(folder)])

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: bench.root.appendingPathComponent("app/src/main.js").path))
        #expect(report?.outcomes.first?.result == .removed)
        #expect(report?.expectedNow == 10_000)
        await transit.drained()
        #expect(contents(transit.directory).isEmpty)
        #expect(transit.pendingBytes == 0)
    }

    @Test("Au lancement suivant, ce qui était resté en transit est effacé")
    func resumesLeftovers() async throws {
        let bench = try Bench()
        let transitFolder = bench.root.appendingPathComponent("support/.transit")
        // Un lancement interrompu : deux éléments renommés, jamais effacés.
        try bench.file("support/.transit/A1B2/paquet/index.js")
        try bench.file("support/.transit/C3D4", bytes: 2_000)
        // Et un lien qui pointe hors du transit : on efface le lien, jamais sa cible.
        let outside = try bench.file("ailleurs/precieux.txt")
        try FileManager.default.createSymbolicLink(at: transitFolder.appendingPathComponent("E5F6"),
                                                   withDestinationURL: outside.deletingLastPathComponent())
        chmod(transitFolder.path, 0o700)

        let transit = Transit(directory: transitFolder)
        transit.resume()
        await transit.drained()

        #expect(contents(transitFolder).isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("Un dossier de transit remplacé par un lien n'est jamais suivi : on efface sur place")
    func refusesSymlinkedTransit() async throws {
        let bench = try Bench()
        let elsewhere = bench.root.appendingPathComponent("ailleurs", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bench.root.appendingPathComponent("support"),
                                                withIntermediateDirectories: true)
        let transitFolder = bench.root.appendingPathComponent("support/.transit")
        try FileManager.default.createSymbolicLink(at: transitFolder, withDestinationURL: elsewhere)
        let folder = bench.root.appendingPathComponent("app/.build")
        try bench.file("app/.build/objet.o")

        let transit = Transit(directory: transitFolder)
        let (_, report) = await run(engine(bench, transit: transit), [bench.item(folder)])
        transit.resume()
        await transit.drained()

        #expect(report?.outcomes.first?.result == .removed)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(contents(elsewhere).isEmpty, "rien n'a été déposé au bout du lien")
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test("La revalidation reste avant le renommage : un élément qui a changé reste en place")
    func revalidatesBeforeMoving() async throws {
        let bench = try Bench()
        let folder = bench.root.appendingPathComponent("app/node_modules")
        try bench.file("app/node_modules/index.js")
        var item = bench.item(folder)
        item.fingerprint = Fingerprint(modificationDate: nil, fileID: 1)
        let transit = Transit(directory: bench.root.appendingPathComponent("support/.transit"))

        let (_, report) = await run(engine(bench, transit: transit), [item])

        #expect(report?.outcomes.first?.result == .skipped(.changedSinceScan))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.js").path))
        #expect(contents(transit.directory).isEmpty)
    }

    @Test("Quatre éléments au plus à la fois, chacun annoncé puis rapporté")
    func boundedPool() async throws {
        let bench = try Bench()
        var items: [CleanupItem] = []
        for index in 0..<12 {
            let url = try bench.file("docs/note\(index).txt")
            items.append(bench.item(url, method: .trash, safety: .review))
        }
        let trasher = SlowTrasher(folder: bench.trash)

        let (events, report) = await run(engine(bench, transit: nil, trasher: trasher), items)

        #expect(trasher.peak.load(ordering: .relaxed) <= CleanupEngine.parallelism)
        #expect(trasher.peak.load(ordering: .relaxed) > 1)
        #expect(report?.succeeded.count == 12)
        // Chaque élément est annoncé avant d'être rapporté, et rapporté une fois.
        var begun = Set<String>()
        var finished: [String] = []
        for event in events {
            switch event {
            case .itemBegan(let id): begun.insert(id)
            case .itemFinished(let outcome):
                #expect(begun.contains(outcome.itemID))
                finished.append(outcome.itemID)
            default: break
            }
        }
        #expect(finished.count == 12 && Set(finished).count == 12)
    }

    @Test("Ce qu'un même outil traite passe à la file, un à la fois")
    func toolQueues() {
        #expect(CleanupEngine.queue(for: .removeNow) == nil)
        #expect(CleanupEngine.queue(for: .trash) == nil)
        #expect(CleanupEngine.queue(for: .gitWorktreeRemove(repository: "/a"))
                == CleanupEngine.queue(for: .gitWorktreeRemove(repository: "/a")))
        #expect(CleanupEngine.queue(for: .gitWorktreeRemove(repository: "/a"))
                != CleanupEngine.queue(for: .gitWorktreeRemove(repository: "/b")))
        #expect(CleanupEngine.queue(for: .simulatorDevice(udid: "1"))
                == CleanupEngine.queue(for: .simulatorRuntime(identifier: "x")))
    }

    @Test("Arrêter laisse le reste en place, et le bilan arrive quand même")
    func cancellationKeepsReport() async throws {
        let bench = try Bench()
        var items: [CleanupItem] = []
        for index in 0..<10 {
            let url = try bench.file("docs/note\(index).txt")
            items.append(bench.item(url, method: .trash, safety: .review))
        }
        let cancellation = CleanupCancellation()
        var report: CleanupReport?
        let slow = SlowTrasher(folder: bench.trash, delay: .milliseconds(400))
        for await event in engine(bench, transit: nil, trasher: slow).run(items, cancellation: cancellation) {
            // Arrêté dès le premier élément annoncé : seuls ceux déjà partis finissent.
            if case .itemBegan = event { cancellation.cancel() }
            if case .finished(let final) = event { report = final }
        }

        let final = try #require(report)
        #expect(final.outcomes.count == 10)
        let cancelled = final.outcomes.filter { $0.result == .skipped(.cancelled) }
        #expect(cancelled.count >= 10 - CleanupEngine.parallelism)
        for outcome in cancelled {
            #expect(FileManager.default.fileExists(atPath: outcome.paths[0]))
        }
    }

    @Test("Ce qui est encore en transit n'est pas mis sur le compte des snapshots")
    func purgingIsNotHeldBack() {
        let item = CleanupItem(title: "x", paths: [], category: .projectArtifacts, owner: "", ruleID: "r",
                               safety: .safe, method: .removeNow, sizes: Sizes(private: 5_000_000_000),
                               rebuild: .automatic)
        let outcome = CleanupOutcome(sessionID: UUID(), date: Date(), item: item, result: .removed, bytes: 5_000_000_000)
        var report = CleanupReport(sessionID: UUID(), startedAt: Date(), finishedAt: Date(), outcomes: [outcome],
                                   availableBefore: 10_000_000_000, availableAfter: 11_000_000_000)
        #expect(report.heldBack == 4_000_000_000)
        report.purging = 4_000_000_000
        #expect(report.heldBack == 0)
    }
}
