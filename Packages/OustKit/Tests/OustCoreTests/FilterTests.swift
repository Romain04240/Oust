import Foundation
import Testing
import OustCore

@Suite("Recherche et filtres")
struct FilterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ title: String, owner: String = "outil", path: String = "/tmp/x", safety: SafetyClass = .safe,
              method: CleanupMethod = .removeNow, bytes: Int64 = 1_000, daysOld: Double? = 10) -> CleanupItem {
        CleanupItem(title: title, detail: nil, paths: [URL(fileURLWithPath: path)], category: .appCaches, owner: owner,
                    ruleID: "cache.app", safety: safety, method: method, sizes: Sizes(private: bytes),
                    lastActivity: daysOld.map { now.addingTimeInterval(-$0 * 86_400) }, rebuild: .automatic)
    }

    @Test("Nom, chemin, propriétaire ; sans casse ni accents ; tous les mots")
    func query() {
        let downloads = item("film.mkv", owner: "Téléchargements", path: "/Volumes/Data/Téléchargements/film.mkv")
        #expect(ItemFilter(query: "FILM").matches(downloads, now: now))
        #expect(ItemFilter(query: "telechargements").matches(downloads, now: now))
        #expect(ItemFilter(query: "volumes film").matches(downloads, now: now))
        #expect(!ItemFilter(query: "film musique").matches(downloads, now: now))
        #expect(ItemFilter(query: "capture d'écran").matches(item("Capture d’écran 2026"), now: now))
        #expect(ItemFilter(query: "   ").matches(downloads, now: now))
        #expect(!ItemFilter(query: "   ").isActive)
    }

    @Test("Classe, méthode, taille, âge")
    func criteria() {
        let big = item("gros", safety: .review, method: .trash, bytes: 2_000_000_000, daysOld: 400)
        let small = item("petit", bytes: 5_000, daysOld: 2)
        let undated = item("sans date", daysOld: nil)

        #expect(ItemFilter(safety: [.review]).matches(big, now: now))
        #expect(!ItemFilter(safety: [.review]).matches(small, now: now))
        #expect(ItemFilter(families: [.macTrash]).matches(big, now: now))
        #expect(!ItemFilter(families: [.keepsFiles]).matches(big, now: now))
        #expect(ItemFilter(size: .gigabyte1).matches(big, now: now))
        #expect(!ItemFilter(size: .megabytes10).matches(small, now: now))
        #expect(ItemFilter(age: .year).matches(big, now: now))
        #expect(!ItemFilter(age: .week).matches(small, now: now))
        // Un âge inconnu ne passe pas pour ancien.
        #expect(!ItemFilter(age: .month).matches(undated, now: now))
        #expect(ItemFilter(safety: [.review], age: .year, size: .gigabyte1).criteriaCount == 3)
    }

    @Test("Les familles de méthodes")
    func families() {
        #expect(CleanupMethod.evictLocalCopy.family == .keepsFiles)
        #expect(CleanupMethod.compressInPlace.family == .keepsFiles)
        #expect(CleanupMethod.cloneOf(original: "/a").family == .keepsFiles)
        #expect(CleanupMethod.brewCleanup(executable: "/b").family == .tool)
        #expect(CleanupMethod.containerPrune(executable: "/d", scope: .buildCache, ids: []).family == .tool)
        #expect(CleanupMethod.trash.family == .macTrash)
        #expect(CleanupMethod.manual.family == .manual)
    }

    @Test("Les identifiants Docker : jamais une option ni un espace")
    func dockerReferences() {
        #expect(PruneScope.isPlainReference("ghcr.io/moi/outil:1.2"))
        #expect(PruneScope.isPlainReference("sha256:abc123"))
        #expect(!PruneScope.isPlainReference("-f"))
        #expect(!PruneScope.isPlainReference("a b"))
        #expect(PruneScope.unusedImages.arguments(ids: ["alpine:3.20"]) == ["image", "rm", "alpine:3.20"])
        #expect(PruneScope.stoppedContainers.arguments(ids: ["d1"]) == ["container", "rm", "d1"])
    }

    @Test("Éviction et compression comptent dans ce qui est rendu tout de suite")
    func reportCountsNewResults() {
        let session = UUID()
        let evicted = CleanupOutcome(sessionID: session, date: now, item: item("a", method: .evictLocalCopy),
                                     result: .evicted, bytes: 3_000)
        let compressed = CleanupOutcome(sessionID: session, date: now, item: item("b", method: .compressInPlace),
                                        result: .compressed, bytes: 2_000)
        // Ce que Docker rend reste dans son disque virtuel : pas « maintenant ».
        var docker = CleanupItem(title: "Images", paths: [], category: .containers, owner: "OrbStack",
                                 ruleID: "container.images", safety: .review,
                                 method: .containerPrune(executable: "/d", scope: .unusedImages, ids: ["x"]),
                                 rebuild: .download)
        docker.sizes = Sizes(private: 7_000)
        let pruned = CleanupOutcome(sessionID: session, date: now, item: docker, result: .delegated, bytes: 7_000)
        let report = CleanupReport(sessionID: session, startedAt: now, finishedAt: now,
                                   outcomes: [evicted, compressed, pruned], availableBefore: nil, availableAfter: nil)
        #expect(report.expectedNow == 5_000)
        #expect(report.succeeded.count == 3)
        #expect(CleanupMethod.evictLocalCopy.freesImmediately && CleanupMethod.compressInPlace.freesImmediately)
    }
}
