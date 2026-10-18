import Foundation
import Testing
import OustCore
@testable import OustPhotos

/// Une photothèque en mémoire : ni PhotoKit, ni autorisation, ni fichier.
final class FakeLibrary: PhotoLibrary, @unchecked Sendable {
    var all: [PhotoAsset] = []
    var resourcesByID: [String: [PhotoResource]] = [:]
    var digests: [String: Data] = [:]
    var prints: [String: FeaturePrint] = [:]
    private let lock = NSLock()
    private var digestCalls: [String] = []
    private var printCalls: [String] = []

    var digested: [String] { lock.withLock { digestCalls } }
    var printed: [String] { lock.withLock { printCalls } }

    func access() -> PhotoAccess { .authorized }
    func requestAccess() async -> PhotoAccess { .authorized }
    func assets() async -> [PhotoAsset] { all }

    func resources(of ids: [String]) async -> [String: [PhotoResource]] {
        resourcesByID.filter { ids.contains($0.key) }
    }

    func digest(of id: String) async -> Data? {
        lock.withLock { digestCalls.append(id) }
        return digests[id]
    }

    func featurePrint(of id: String) async -> FeaturePrint? {
        lock.withLock { printCalls.append(id) }
        return prints[id]
    }

    func thumbnail(of id: String, side: Int) async -> PhotoThumbnail? { nil }
    func image(of id: String, side: Int, allowNetwork: Bool) async -> PhotoImage? { nil }
    func video(of id: String, allowNetwork: Bool) async -> PhotoVideo? { nil }
    func livePhoto(of id: String, side: Int, allowNetwork: Bool) async -> PhotoLive? { nil }
    func albums(of id: String) async -> [String] { [] }
    var signalsByID: [String: PhotoSignals] = [:]
    func signals(of id: String) async -> PhotoSignals? { signalsByID[id] }
    func existing(_ ids: [String]) async -> Set<String> { Set(all.map(\.id)).intersection(ids) }
    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    /// Un élément avec une ressource originale de `size` octets.
    func add(_ id: String, media: PhotoMedia = .image, created: Date, size: Int64, local: Bool? = true,
             screenshot: Bool = false, recording: Bool = false, duration: TimeInterval = 0,
             width: Int = 4032, height: Int = 3024, facts: PhotoFacts = PhotoFacts()) {
        all.append(PhotoAsset(id: id, media: media, isScreenshot: screenshot, isScreenRecording: recording,
                              created: created, duration: duration, pixelWidth: width, pixelHeight: height,
                              facts: facts))
        resourcesByID[id] = [PhotoResource(isOriginal: true, filename: "\(id).\(media == .video ? "MOV" : "HEIC")",
                                           size: size, isLocal: local)]
    }
}

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

@Suite("La photothèque : vidéos, captures et doublons, sans rien télécharger")
struct PhotoAnalyzerTests {

    @Test("Les plus grosses vidéos, triées, avec ce qui est vraiment sur ce Mac")
    func videos() async {
        let library = FakeLibrary()
        library.add("petite", media: .video, created: daysAgo(3), size: 20_000_000, duration: 4)
        library.add("grosse", media: .video, created: daysAgo(400), size: 3_000_000_000, duration: 600)
        library.add("nuage", media: .video, created: daysAgo(50), size: 900_000_000, local: false, duration: 120)
        library.add("photo", created: daysAgo(1), size: 4_000_000)

        let findings = await PhotoAnalyzer.analyze(library, options: PhotoOptions(now: now))

        #expect(findings.videos.map(\.id) == ["grosse", "nuage"])
        let cloud = findings.videos[1]
        #expect(cloud.size.total == 900_000_000)
        #expect(cloud.size.local == 0)
        let item = cloud.cleanupItem(for: .video)
        // Évincée par Photos iCloud : la supprimer ne rend rien ici, et on le dit.
        #expect(item.sizes.freeable == 0)
        #expect(item.sizes.allocated == 900_000_000)
        #expect(item.notes == [.photoInCloud])
        #expect(item.method == .photoAsset(localIdentifier: "nuage"))
        #expect(item.paths.isEmpty)
        #expect(findings.videos[0].cleanupItem(for: .video).sizes.freeable == 3_000_000_000)
    }

    @Test("Seules les captures et enregistrements d'écran de plus de 30 jours")
    func screenshots() async {
        let library = FakeLibrary()
        library.add("vieille", created: daysAgo(45), size: 2_000_000, screenshot: true)
        library.add("recente", created: daysAgo(5), size: 2_000_000, screenshot: true)
        library.add("film", media: .video, created: daysAgo(90), size: 30_000_000, recording: true, duration: 30)
        library.add("vacances", created: daysAgo(300), size: 3_000_000)

        let findings = await PhotoAnalyzer.analyze(library, options: PhotoOptions(now: now))

        #expect(findings.screenshots.map(\.id) == ["film", "vieille"])
        #expect(findings.screenshots[0].cleanupItem(for: .screenshot).ruleID == "photos.screen_recording")
        #expect(findings.screenshots[1].cleanupItem(for: .screenshot).ruleID == "photos.screenshot")
    }

    @Test("Doublons exacts : même seconde, même taille, puis même empreinte")
    func duplicates() async {
        let library = FakeLibrary()
        let shot = daysAgo(100)
        library.add("a", created: shot, size: 5_000_000)
        library.add("b", created: shot, size: 5_000_000)
        library.add("c", created: shot, size: 5_000_000)
        // Même taille et même seconde, mais l'original n'est que dans iCloud.
        library.add("d", created: shot, size: 5_000_000, local: false)
        // Même seconde, autre taille : jamais lu.
        library.add("e", created: shot, size: 4_000_000)
        // Même taille, autre seconde : jamais comparé.
        library.add("f", created: shot.addingTimeInterval(2), size: 5_000_000)
        library.digests = ["a": Data([1]), "b": Data([1]), "c": Data([2]), "e": Data([1]), "f": Data([1])]

        let findings = await PhotoAnalyzer.analyze(library, options: PhotoOptions(now: now))

        #expect(findings.duplicates.count == 1)
        #expect(findings.duplicates[0].entries.map(\.id) == ["a", "b"])
        #expect(findings.duplicates[0].potential == 5_000_000)
        #expect(findings.unverifiable == 1)
        #expect(Set(library.digested) == ["a", "b", "c", "d"])
    }

    @Test("Rien n'est coché d'office, pas même un doublon exact")
    func noPreselection() async {
        let library = FakeLibrary()
        let shot = daysAgo(100)
        library.add("a", created: shot, size: 5_000_000)
        library.add("b", created: shot, size: 5_000_000)
        library.add("v", media: .video, created: daysAgo(10), size: 1_000_000_000, duration: 60)
        library.add("s", created: daysAgo(60), size: 1_000_000, screenshot: true)
        library.digests = ["a": Data([7]), "b": Data([7])]

        let findings = await PhotoAnalyzer.analyze(library, options: PhotoOptions(now: now))
        let items = findings.videos.map { $0.cleanupItem(for: .video) }
            + findings.screenshots.map { $0.cleanupItem(for: .screenshot) }
            + findings.duplicates.flatMap(\.entries).map { $0.cleanupItem(for: .duplicate) }

        #expect(items.count == 4)
        for item in items {
            #expect(item.safety == .review)
            #expect(item.isSelectable)
            #expect(!PreselectionPolicy().preselects(item, now: now))
        }
    }

    @Test("Favoris, éléments partagés et masqués sont protégés")
    func protections() {
        #expect(PhotoFacts(isFavorite: true).protections == [.photoFavorite])
        #expect(PhotoFacts(isShared: true).protections == [.photoShared])
        #expect(PhotoFacts(isHidden: true).protections == [.photoHidden])
        #expect(PhotoFacts(canDelete: false).protections == [.unknownState])
        #expect(PhotoFacts().protections.isEmpty)

        let asset = PhotoAsset(id: "x", media: .video, created: now, facts: PhotoFacts(isFavorite: true))
        let item = PhotoEntry(asset: asset, title: "x.MOV", size: PhotoSize(total: 10, local: 10)).cleanupItem(for: .video)
        #expect(item.safety == .protected)
        #expect(!item.isSelectable)
    }

    @Test("Un favori ne compte pas : dans un groupe, c'est lui qu'on garde")
    func protectedCopyIsKept() {
        func entry(_ id: String, _ bytes: Int64, favorite: Bool = false) -> PhotoEntry {
            PhotoEntry(asset: PhotoAsset(id: id, media: .image, created: now, facts: PhotoFacts(isFavorite: favorite)),
                       title: id, size: PhotoSize(total: bytes, local: bytes))
        }
        // Sans favori, on garde le plus lourd ; avec, tout le reste peut partir.
        #expect(PhotoGroup(entries: [entry("a", 3), entry("b", 5), entry("c", 4)]).potential == 7)
        #expect(PhotoGroup(entries: [entry("a", 3), entry("b", 5, favorite: true), entry("c", 4)]).potential == 7)
        #expect(PhotoGroup(entries: [entry("a", 9, favorite: true), entry("b", 5), entry("c", 4)]).potential == 9)
    }

    @Test("Un élément n'a qu'un identifiant, quelle que soit la liste")
    func oneIdentifier() {
        let asset = PhotoAsset(id: "rec", media: .video, isScreenRecording: true, created: now, duration: 30)
        let entry = PhotoEntry(asset: asset, title: "rec.MOV", size: PhotoSize(total: 10, local: 10))
        #expect(entry.cleanupItem(for: .video).id == entry.cleanupItem(for: .screenshot).id)
        #expect(entry.cleanupItem(for: .video).id == PhotoEntry.itemID("rec"))
    }

    @Test("Une taille ou une présence inconnue n'est jamais comptée comme libérable")
    func unknownSizes() {
        let size = PhotoSize([
            PhotoResource(isOriginal: true, filename: "a", size: 100, isLocal: true),
            PhotoResource(isOriginal: true, filename: "b", size: 50, isLocal: nil),
            PhotoResource(isOriginal: false, filename: "c", size: nil, isLocal: true),
        ])
        #expect(size.total == 150)
        #expect(size.local == 100)
        #expect(!size.isComplete)
    }
}

@Suite("Les photos similaires, à part et jamais cochées")
struct SimilarPhotoTests {

    @Test("Seules les voisines dans la fenêtre sont comparées, sous le seuil")
    func neighbours() async {
        let library = FakeLibrary()
        let start = daysAgo(20)
        library.add("p1", created: start, size: 3_000_000)
        library.add("p2", created: start.addingTimeInterval(10), size: 2_000_000)
        library.add("p3", created: start.addingTimeInterval(20), size: 3_000_000)
        library.add("isolee", created: start.addingTimeInterval(3_600), size: 3_000_000)
        library.add("capture", created: start.addingTimeInterval(5), size: 1_000_000, screenshot: true)
        library.prints = [
            "p1": FeaturePrint([1, 0]), "p2": FeaturePrint([0.9, 0.1]), "p3": FeaturePrint([0, 1]),
            "isolee": FeaturePrint([1, 0]), "capture": FeaturePrint([1, 0]),
        ]

        let groups = await PhotoAnalyzer.similar(library, among: library.all)

        #expect(groups.map { $0.entries.map(\.id) } == [["p1", "p2"]])
        // Une photo sans voisine n'est pas lue ; une capture n'est jamais comparée.
        #expect(Set(library.printed) == ["p1", "p2", "p3"])
        #expect(groups[0].potential == 2_000_000)
        let item = groups[0].entries[0].cleanupItem(for: .similar)
        #expect(item.ruleID == "photos.similar")
        #expect(!PreselectionPolicy().preselects(item, now: now))
    }

    @Test("Les doublons exacts déjà trouvés ne reviennent pas parmi les similaires")
    func excludesDuplicates() async {
        let library = FakeLibrary()
        let start = daysAgo(20)
        library.add("a", created: start, size: 1)
        library.add("b", created: start.addingTimeInterval(1), size: 1)
        library.prints = ["a": FeaturePrint([1, 0]), "b": FeaturePrint([1, 0])]

        let groups = await PhotoAnalyzer.similar(library, among: library.all, excluding: ["b"])

        #expect(groups.isEmpty)
    }

    @Test("La distance est celle de Vision : euclidienne")
    func distance() {
        #expect(FeaturePrint([0, 0]).distance(to: FeaturePrint([3, 4])) == 5)
        #expect(FeaturePrint([1]).distance(to: FeaturePrint([1, 2])) == nil)
    }
}

@Suite("L'aperçu fait défiler la liste ou le groupe, sans tourner en boucle")
struct PhotoSequenceTests {
    func entries(_ ids: [String]) -> [PhotoEntry] {
        ids.map { PhotoEntry(asset: PhotoAsset(id: $0, media: .image, created: now), title: $0, size: .zero) }
    }

    @Test("Ouvre sur l'élément cliqué, s'arrête aux bouts")
    func steps() throws {
        var sequence = try #require(PhotoSequence(entries(["a", "b", "c"]), at: "b"))
        #expect(sequence.current.id == "b")
        let forward = sequence.step(1)
        #expect(forward && sequence.current.id == "c")
        let pastEnd = sequence.step(1)
        #expect(!pastEnd && !sequence.canGoForward)
        let back = sequence.step(-5)
        #expect(back && sequence.current.id == "a")
        #expect(!sequence.canGoBack)
        sequence.show("c")
        #expect(sequence.current.id == "c")
    }

    @Test("Un élément inconnu ouvre sur le premier ; une liste vide n'ouvre rien")
    func edges() {
        #expect(PhotoSequence(entries(["a", "b"]), at: "z")?.current.id == "a")
        #expect(PhotoSequence([], at: "a") == nil)
    }
}
