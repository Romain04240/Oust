import Foundation
import OustCore
import Synchronization

// MARK: - Réglages et résultats

/// Réglages de l'analyse de la photothèque.
public struct PhotoOptions: Sendable {
    /// Une capture plus jeune a peut-être encore son usage : 30 jours, comme
    /// celles du Bureau (règle `screenshots.desktop`).
    public var screenshotAgeDays: Int
    /// En dessous, une vidéo ne pèse pas assez pour être montrée.
    public var minimumVideoSize: Int64
    public var now: Date

    public init(screenshotAgeDays: Int = 30, minimumVideoSize: Int64 = 50_000_000, now: Date = Date()) {
        self.screenshotAgeDays = screenshotAgeDays
        self.minimumVideoSize = minimumVideoSize
        self.now = now
    }
}

/// Réglages de la recherche de photos similaires.
public struct SimilarOptions: Sendable {
    /// Distance de Vision en dessous de laquelle deux photos se ressemblent.
    ///
    /// Mesuré le 18/10/2026 (révision 2, vecteurs de norme 1) : une même photo
    /// recadrée, décalée ou éclaircie reste entre 0,13 et 0,46 ; deux paysages
    /// différents d'une même série (Big Sur, Catalina) sont entre 0,62 et 1,10.
    /// 0,45 garde les rafales et les séries, pas les photos d'un même lieu.
    public var threshold: Float
    /// Deux photos ne sont comparées que prises à moins de cet écart : les
    /// photos semblables se font en série, et comparer toute la photothèque à
    /// elle-même coûterait des heures.
    public var window: TimeInterval
    /// Combien de voisines au plus pour chaque photo, dans cette fenêtre.
    public var neighbours: Int
    /// Seulement les photos prises depuis cette date ; `nil` : toutes.
    public var since: Date?

    public init(threshold: Float = 0.45, window: TimeInterval = 300, neighbours: Int = 8, since: Date? = nil) {
        self.threshold = threshold
        self.window = window
        self.neighbours = neighbours
        self.since = since
    }
}

/// Un élément trouvé, avec ce que sa suppression rendrait.
public struct PhotoEntry: Sendable, Hashable, Identifiable {
    public let asset: PhotoAsset
    /// Le nom de fichier d'origine (`IMG_1234.HEIC`) : jamais traduit.
    public let title: String
    public let size: PhotoSize

    public var id: String { asset.id }

    /// Peut partir : ni favori, ni partagé, ni masqué. Seul ce qui peut partir
    /// compte dans un total (RULES.md, règle 9).
    public var isFreeable: Bool { asset.facts.protections.isEmpty }

    public init(asset: PhotoAsset, title: String, size: PhotoSize) {
        self.asset = asset
        self.title = title
        self.size = size
    }
}

/// Des éléments identiques, ou qui se ressemblent.
public struct PhotoGroup: Sendable, Hashable, Identifiable {
    public let entries: [PhotoEntry]

    public init(entries: [PhotoEntry]) {
        self.entries = entries
    }

    public var id: String { entries.first?.id ?? "" }

    /// Ce que le groupe rendrait au plus sur ce Mac : tout ce qui peut partir,
    /// sauf un exemplaire. Un exemplaire protégé (un favori) est celui qu'on
    /// garde ; sinon, le plus lourd.
    public var potential: Int64 {
        let free = entries.filter(\.isFreeable).map(\.size.local).sorted()
        return (free.count == entries.count ? free.dropLast() : free[...]).reduce(0, +)
    }
}

/// Ce que l'analyse a trouvé.
public struct PhotoFindings: Sendable {
    /// Toute la photothèque lue, pour la recherche des similaires.
    public var assets: [PhotoAsset] = []
    /// Les plus grosses vidéos, de la plus lourde à la plus légère.
    public var videos: [PhotoEntry] = []
    /// Les captures et enregistrements d'écran anciens, du plus ancien au plus récent.
    public var screenshots: [PhotoEntry] = []
    /// Les doublons exacts, du groupe qui rendrait le plus au moins.
    public var duplicates: [PhotoGroup] = []
    /// Candidats aux doublons qu'on n'a pas pu vérifier : un original n'est que
    /// dans iCloud, et on ne télécharge rien pour comparer.
    public var unverifiable = 0

    public init() {}
}

/// L'avancement, lu par l'interface pendant que l'analyse tourne.
public final class PhotoProgress: Sendable {
    public enum Stage: Int, Sendable {
        case listing, measuring, comparing, printing, classifying
    }

    private let stageValue = Atomic<Int>(Stage.listing.rawValue)
    private let doneCount = Atomic<Int>(0)
    private let totalCount = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)

    public init() {}

    public var stage: Stage { Stage(rawValue: stageValue.load(ordering: .relaxed)) ?? .listing }
    public var done: Int { doneCount.load(ordering: .relaxed) }
    public var total: Int { totalCount.load(ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) || Task.isCancelled }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }

    func begin(_ stage: Stage, total: Int) {
        stageValue.store(stage.rawValue, ordering: .relaxed)
        doneCount.store(0, ordering: .relaxed)
        totalCount.store(total, ordering: .relaxed)
    }

    func advance(by count: Int = 1) { doneCount.add(count, ordering: .relaxed) }
}

// MARK: - Analyse

/// Ce qui encombre la photothèque, trouvé sans rien télécharger ni supprimer.
///
/// L'analyse ne fait que lire : vidéos et captures par les propriétés de
/// PhotoKit, doublons exacts par la taille des ressources originales puis leur
/// empreinte complète. La suppression est l'affaire d'OustClean.
public enum PhotoAnalyzer {

    /// Par lots : chaque lot est une requête à la base de Photos.
    static let batchSize = 200

    public static func analyze(_ library: any PhotoLibrary, options: PhotoOptions = PhotoOptions(),
                               progress: PhotoProgress = PhotoProgress()) async -> PhotoFindings {
        var findings = PhotoFindings()
        progress.begin(.listing, total: 0)
        let all = await library.assets()
        findings.assets = all
        guard !progress.isCancelled else { return findings }

        let cutoff = options.now.addingTimeInterval(-Double(options.screenshotAgeDays) * 86_400)
        let videos = all.filter { $0.media == .video }
        let screenshots = all.filter { ($0.isScreenshot || $0.isScreenRecording) && ($0.created.map { $0 < cutoff } ?? false) }
        let buckets = duplicateBuckets(all)

        // Une seule lecture des ressources par élément, quelle que soit la liste.
        var wanted: [String] = []
        var seen = Set<String>()
        for asset in videos + screenshots + buckets.joined() where seen.insert(asset.id).inserted {
            wanted.append(asset.id)
        }
        progress.begin(.measuring, total: wanted.count)
        var resources: [String: [PhotoResource]] = [:]
        for start in stride(from: 0, to: wanted.count, by: batchSize) {
            guard !progress.isCancelled else { return findings }
            let batch = Array(wanted[start..<min(start + batchSize, wanted.count)])
            resources.merge(await library.resources(of: batch)) { _, new in new }
            progress.advance(by: batch.count)
        }

        func entry(_ asset: PhotoAsset) -> PhotoEntry {
            let list = resources[asset.id] ?? []
            return PhotoEntry(asset: asset, title: title(of: list, fallback: asset), size: PhotoSize(list))
        }

        findings.videos = videos.map(entry)
            .filter { $0.size.total >= options.minimumVideoSize }
            .sorted { ($0.size.total, $0.id) > ($1.size.total, $1.id) }
        findings.screenshots = screenshots.map(entry)
            .sorted { ($0.asset.created ?? .distantPast, $0.id) < ($1.asset.created ?? .distantPast, $1.id) }

        progress.begin(.comparing, total: buckets.reduce(0) { $0 + $1.count })
        var groups: [PhotoGroup] = []
        for bucket in buckets {
            guard !progress.isCancelled else { return findings }
            let (found, unverifiable) = await exactDuplicates(in: bucket.map(entry), resources: resources, library: library)
            groups += found
            findings.unverifiable += unverifiable
            progress.advance(by: bucket.count)
        }
        findings.duplicates = groups.sorted { ($0.potential, $0.id) > ($1.potential, $1.id) }
        return findings
    }

    /// Les candidats aux doublons, d'après ce que PhotoKit dit sans rien lire :
    /// même type, mêmes dimensions, même durée, même date de prise de vue à la
    /// seconde. Deux imports d'un même fichier ont tout cela en commun ; deux
    /// photos d'un même iPhone, presque jamais la même seconde. Une photo dont
    /// on a changé la date échappe au tri : c'est un doublon manqué, jamais un
    /// faux doublon (l'empreinte tranche ensuite).
    static func duplicateBuckets(_ assets: [PhotoAsset]) -> [[PhotoAsset]] {
        struct Key: Hashable {
            let media: PhotoMedia
            let width: Int, height: Int
            let duration: Int
            let second: Int64
        }
        var buckets: [Key: [PhotoAsset]] = [:]
        for asset in assets where asset.media != .other {
            guard let created = asset.created else { continue }
            let key = Key(media: asset.media, width: asset.pixelWidth, height: asset.pixelHeight,
                          duration: Int((asset.duration * 10).rounded()), second: Int64(created.timeIntervalSince1970.rounded(.down)))
            buckets[key, default: []].append(asset)
        }
        return buckets.values.filter { $0.count > 1 }
            .map { $0.sorted { $0.id < $1.id } }
            .sorted { $0[0].id < $1[0].id }
    }

    /// Mêmes ressources originales, mêmes tailles, puis même empreinte complète.
    /// Ce dont on ignore une taille, ou qui n'est pas entièrement sur ce Mac,
    /// n'est pas proposé (RULES.md, règle 3).
    static func exactDuplicates(in entries: [PhotoEntry], resources: [String: [PhotoResource]],
                                library: any PhotoLibrary) async -> (groups: [PhotoGroup], unverifiable: Int) {
        var bySizes: [[Int64]: [PhotoEntry]] = [:]
        var unverifiable = 0
        for entry in entries {
            let originals = (resources[entry.id] ?? []).filter(\.isOriginal)
            let sizes = originals.compactMap(\.size)
            guard !originals.isEmpty, sizes.count == originals.count else { unverifiable += 1; continue }
            bySizes[sizes.sorted(), default: []].append(entry)
        }
        var groups: [PhotoGroup] = []
        for candidates in bySizes.values where candidates.count > 1 {
            var byDigest: [Data: [PhotoEntry]] = [:]
            for entry in candidates {
                guard let digest = await library.digest(of: entry.id) else { unverifiable += 1; continue }
                byDigest[digest, default: []].append(entry)
            }
            for same in byDigest.values where same.count > 1 {
                groups.append(PhotoGroup(entries: same.sorted {
                    ($0.asset.created ?? .distantPast, $0.id) < ($1.asset.created ?? .distantPast, $1.id)
                }))
            }
        }
        return (groups, unverifiable)
    }

    /// Le nom de fichier d'origine, ou à défaut le type et la date.
    static func title(of resources: [PhotoResource], fallback asset: PhotoAsset) -> String {
        if let name = resources.first(where: { $0.isOriginal && !$0.filename.isEmpty })?.filename { return name }
        if let name = resources.first(where: { !$0.filename.isEmpty })?.filename { return name }
        return asset.created?.formatted(date: .abbreviated, time: .shortened) ?? asset.id
    }

    // MARK: Similaires

    /// Les photos qui se ressemblent, à part des doublons et sur demande : il
    /// faut une empreinte Vision par photo, ce qui prend du temps.
    ///
    /// Seules les photos prises à moins de `window` d'une autre sont lues (une
    /// photo isolée n'a pas de sœur), puis comparées à leurs voisines. Les
    /// groupes se forment de proche en proche. Rien n'est jamais coché d'office
    /// (RULES.md, règle 4).
    public static func similar(_ library: any PhotoLibrary, among assets: [PhotoAsset], excluding: Set<String> = [],
                               options: SimilarOptions = SimilarOptions(),
                               progress: PhotoProgress = PhotoProgress()) async -> [PhotoGroup] {
        let photos = assets
            .filter { asset in
                guard asset.media == .image, !asset.isScreenshot, !excluding.contains(asset.id),
                      let created = asset.created else { return false }
                return options.since.map { created >= $0 } ?? true
            }
            .sorted { ($0.created ?? .distantPast, $0.id) < ($1.created ?? .distantPast, $1.id) }
        let pairs = neighbourPairs(photos, options: options)
        let needed = Set(pairs.flatMap { [$0.0, $0.1] }).sorted()

        progress.begin(.printing, total: needed.count)
        var prints: [Int: FeaturePrint] = [:]
        await withTaskGroup(of: (Int, FeaturePrint?).self) { group in
            var next = 0
            // Vision et le décodage des vignettes occupent le processeur : quatre à la fois.
            func launch() {
                guard next < needed.count else { return }
                let index = needed[next]
                let id = photos[index].id
                next += 1
                group.addTask { (index, progress.isCancelled ? nil : await library.featurePrint(of: id)) }
            }
            for _ in 0..<4 { launch() }
            for await (index, print) in group {
                if let print { prints[index] = print }
                progress.advance()
                if !progress.isCancelled { launch() }
            }
        }
        guard !progress.isCancelled else { return [] }

        var links = UnionFind(count: photos.count)
        for (first, second) in pairs {
            guard let a = prints[first], let b = prints[second], let distance = a.distance(to: b),
                  distance <= options.threshold else { continue }
            links.union(first, second)
        }
        let clusters = links.groups().filter { $0.count > 1 }
        let members = clusters.flatMap { $0.map { photos[$0].id } }
        var resources: [String: [PhotoResource]] = [:]
        for start in stride(from: 0, to: members.count, by: batchSize) {
            let batch = Array(members[start..<min(start + batchSize, members.count)])
            resources.merge(await library.resources(of: batch)) { _, new in new }
        }
        return clusters.map { cluster in
            PhotoGroup(entries: cluster.sorted().map { index in
                let asset = photos[index]
                let list = resources[asset.id] ?? []
                return PhotoEntry(asset: asset, title: title(of: list, fallback: asset), size: PhotoSize(list))
            })
        }
        .sorted { ($0.potential, $0.id) > ($1.potential, $1.id) }
    }

    /// Les paires à comparer : chaque photo et ses voisines suivantes prises
    /// dans la fenêtre, `neighbours` au plus. `photos` est trié par date.
    static func neighbourPairs(_ photos: [PhotoAsset], options: SimilarOptions) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for index in photos.indices {
            guard let start = photos[index].created else { continue }
            var other = index + 1
            while other < photos.count, other - index <= options.neighbours,
                  let date = photos[other].created, date.timeIntervalSince(start) <= options.window {
                pairs.append((index, other))
                other += 1
            }
        }
        return pairs
    }
}

/// Des ensembles qui fusionnent : de quoi former des groupes de proche en proche.
struct UnionFind {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    mutating func find(_ index: Int) -> Int {
        var root = index
        while parent[root] != root { root = parent[root] }
        var current = index
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a), rootB = find(b)
        if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
    }

    mutating func groups() -> [[Int]] {
        var byRoot: [Int: [Int]] = [:]
        for index in parent.indices { byRoot[find(index), default: []].append(index) }
        return byRoot.keys.sorted().map { byRoot[$0]! }
    }
}
