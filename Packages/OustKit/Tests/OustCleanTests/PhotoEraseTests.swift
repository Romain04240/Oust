import Foundation
import Testing
@testable import OustClean
import OustCore
import OustSafety

/// Photos, sans Photos : ce que chaque élément est devenu, et ce qu'on a demandé.
final class FakeEraser: PhotoEraser, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [String: PhotoFacts]?
    private var requests: [[String]] = []
    let answer: PhotoErasure
    /// Ceux que Photos garde malgré une suppression acceptée.
    let survivors: Set<String>

    init(_ facts: [String: PhotoFacts]?, answer: PhotoErasure = .deleted, survivors: Set<String> = []) {
        self.current = facts
        self.answer = answer
        self.survivors = survivors
    }

    var deletions: [[String]] { lock.withLock { requests } }

    func facts(of ids: [String]) async -> [String: PhotoFacts]? {
        lock.withLock { current?.filter { ids.contains($0.key) } }
    }

    func delete(_ ids: [String]) async -> PhotoErasure {
        lock.withLock {
            requests.append(ids)
            if answer == .deleted { for id in ids where !survivors.contains(id) { current?[id] = nil } }
        }
        return answer
    }
}

@Suite("Les photos partent par Photos, en une seule demande, revalidées")
struct PhotoEraseTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-photos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func engine(_ eraser: FakeEraser) -> CleanupEngine {
        CleanupEngine(trasher: FolderTrasher(folder: folder.appendingPathComponent("_corbeille")),
                      history: HistoryStore(directory: folder.appendingPathComponent("_historique")),
                      pathGuard: PathGuard(home: folder.appendingPathComponent("maison")),
                      processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil },
                      deleteSnapshots: { _ in false }, runningApps: { [] }, photos: eraser,
                      allowsPathBasedRemoval: true)
    }

    func photo(_ id: String, bytes: Int64 = 1_000_000, editedAt: Date? = nil) -> CleanupItem {
        CleanupItem(id: "photo|\(id)", title: "\(id).HEIC", paths: [], category: .photoDuplicates, owner: "Photos",
                    ruleID: "photos.duplicate", safety: .review, method: .photoAsset(localIdentifier: id),
                    sizes: Sizes(private: bytes), rebuild: .photosRecentlyDeleted,
                    fingerprint: Fingerprint(modificationDate: editedAt, fileID: nil))
    }

    func run(_ items: [CleanupItem], with eraser: FakeEraser) async -> CleanupReport? {
        var report: CleanupReport?
        for await event in engine(eraser).run(items) {
            if case .finished(let final) = event { report = final }
        }
        try? FileManager.default.removeItem(at: folder)
        return report
    }

    @Test("Toutes les photos en une seule demande : une seule invite de macOS")
    func oneRequest() async throws {
        let eraser = FakeEraser(["a": PhotoFacts(), "b": PhotoFacts(), "c": PhotoFacts()])
        let report = try #require(await run([photo("a"), photo("b"), photo("c")], with: eraser))

        #expect(eraser.deletions.count == 1)
        #expect(Set(eraser.deletions[0]) == ["a", "b", "c"])
        #expect(report.outcomes.allSatisfy { $0.result == .recentlyDeleted })
        // Dans « Supprimés récemment » : ni rendu maintenant, ni dans la corbeille du Mac.
        #expect(report.pendingInPhotos == 3_000_000)
        #expect(report.expectedNow == 0)
        #expect(report.pendingInTrash == 0)
    }

    @Test("Revalidée juste avant : disparue, devenue favorite, partagée ou retouchée")
    func revalidation() async throws {
        let scanned = Date(timeIntervalSince1970: 1_700_000_000)
        let eraser = FakeEraser([
            "favorite": PhotoFacts(isFavorite: true),
            "partagee": PhotoFacts(isShared: true),
            "retouchee": PhotoFacts(editedAt: scanned.addingTimeInterval(3_600)),
            "intacte": PhotoFacts(editedAt: scanned),
        ])
        let items = [photo("disparue"), photo("favorite"), photo("partagee"), photo("retouchee", editedAt: scanned),
                     photo("intacte", editedAt: scanned)]
        let report = try #require(await run(items, with: eraser))
        let results = Dictionary(uniqueKeysWithValues: report.outcomes.map { ($0.itemID, $0.result) })

        #expect(results["photo|disparue"] == .skipped(.vanished))
        #expect(results["photo|favorite"] == .skipped(.nowProtected(.photoFavorite)))
        #expect(results["photo|partagee"] == .skipped(.nowProtected(.photoShared)))
        #expect(results["photo|retouchee"] == .skipped(.changedSinceScan))
        #expect(results["photo|intacte"] == .recentlyDeleted)
        #expect(eraser.deletions == [["intacte"]])
    }

    @Test("Refusée dans l'invite de macOS : rien n'est parti, rien n'est compté")
    func declined() async throws {
        let eraser = FakeEraser(["a": PhotoFacts()], answer: .declined)
        let report = try #require(await run([photo("a")], with: eraser))

        #expect(report.outcomes.map(\.result) == [.skipped(.cancelled)])
        #expect(report.pendingInPhotos == 0)
    }

    @Test("Encore là après une suppression acceptée : noté en échec")
    func survivor() async throws {
        let eraser = FakeEraser(["a": PhotoFacts(), "b": PhotoFacts()], survivors: ["b"])
        let report = try #require(await run([photo("a"), photo("b")], with: eraser))
        let results = Dictionary(uniqueKeysWithValues: report.outcomes.map { ($0.itemID, $0.result) })

        #expect(results["photo|a"] == .recentlyDeleted)
        #expect(results["photo|b"] == .failed(message: "Photos"))
        #expect(report.pendingInPhotos == 1_000_000)
    }

    @Test("Accès retiré depuis l'analyse : on ne demande rien à Photos")
    func noAccess() async throws {
        let eraser = FakeEraser(nil)
        let report = try #require(await run([photo("a")], with: eraser))

        #expect(report.outcomes.map(\.result) == [.skipped(.nowProtected(.unknownState))])
        #expect(eraser.deletions.isEmpty)
    }

    @Test("Les photos partent avec le reste de la corbeille, sans le retenir")
    func mixedBin() async throws {
        let file = folder.appendingPathComponent("cache/blob")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: file)
        let cache = CleanupItem(title: "blob", paths: [file], category: .packageCaches, owner: "test",
                                ruleID: "cache.npm", safety: .safe, method: .removeNow, sizes: Sizes(private: 10),
                                rebuild: .automatic)
        let eraser = FakeEraser(["a": PhotoFacts()])
        let report = try #require(await run([cache, photo("a")], with: eraser))

        #expect(report.outcomes.map(\.result) == [.removed, .recentlyDeleted])
        #expect(report.expectedNow == 10)
        #expect(report.pendingInPhotos == 1_000_000)
    }
}
