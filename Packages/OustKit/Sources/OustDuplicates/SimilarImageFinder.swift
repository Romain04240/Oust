import Accelerate
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import OustCore
import OustScan
import Synchronization
import Vision

// MARK: - Réglages et résultats

/// Réglages de la recherche d'images similaires dans les dossiers.
///
/// Les mêmes principes que les photos similaires de la photothèque
/// (`OustPhotos.SimilarOptions`) : une empreinte Vision par image, le même seuil
/// quand on sait que deux images viennent d'une même prise de vue, un seuil plus
/// strict sinon, et jamais tout comparé à tout.
public struct SimilarImageOptions: Sendable {
    public var roots: [URL]
    /// Jamais parcourus, même sous un dossier choisi : les dossiers de projets.
    public var excludedFolders: [URL]
    /// Distance de Vision en dessous de laquelle deux images d'une même prise de
    /// vue (dates EXIF à moins de `window`) ou d'un même nom (au suffixe de copie
    /// près) se ressemblent.
    ///
    /// Celui de Photos, remesuré le 18/10/2026 sur des fichiers (vignettes de
    /// 360 px) : une même image recadrée jusqu'à 60 %, éclaircie, assombrie,
    /// réduite, recompressée en JPEG ou en HEIC, tournée de 3° ou retournée
    /// reste sous 0,37 ; deux fonds d'écran différents de macOS ne descendent
    /// pas sous 0,50 (325 paires, médiane 1,07).
    public var threshold: Float
    /// Le seuil quand rien ne dit que deux images viennent d'une même prise de
    /// vue : seulement le même dossier, ou des dates de modification proches.
    ///
    /// Sur le Mac de Romain (18/10/2026), 91 illustrations d'espèces dans un
    /// même style, toutes différentes, générées à quelques minutes d'écart :
    /// 36 paires sous 0,45 (« Pigeon colombin » et « Pigeon ramier » réunis à
    /// 0,407), la plus proche à 0,338 (Corbeau freux et Corneille noire). Une
    /// copie réduite, recompressée, retournée, recadrée de 10 % ou éclaircie
    /// reste sous 0,27 ; un recadrage à 75 % ou 60 % sans date ni nom commun
    /// n'est pas retrouvé : un doublon manqué plutôt qu'une fausse sœur.
    public var strictThreshold: Float
    /// Deux images de dossiers différents ne sont comparées que prises (ou
    /// modifiées) à moins de cet écart : les variantes d'une photo naissent
    /// ensemble, ou gardent la date de prise de vue de l'original.
    public var window: TimeInterval
    /// Combien de voisines au plus pour chaque image, dans cette fenêtre.
    public var neighbours: Int
    /// Jusqu'à ce nombre d'images, un dossier est comparé paire à paire ; au-delà,
    /// chaque image à ses `folderNeighbours` voisines de date dans le dossier.
    public var folderLimit: Int
    public var folderNeighbours: Int
    /// En dessous, une image ne pèse rien : icônes, vignettes, pictogrammes.
    public var minimumSize: Int64
    /// Le plus petit côté, en pixels, d'une image qu'on compare.
    public var minimumSide: Int
    /// La vignette donnée à Vision. 360 px, comme Photos : à 512, une même image
    /// recadrée de 10 % s'éloignait à 0,36 contre 0,16 (mesuré le 18/10/2026) ;
    /// le modèle travaille sur une entrée de cet ordre.
    public var thumbnailSide: Int
    /// Vision et le décodage occupent le processeur : quatre images à la fois.
    public var concurrency: Int

    public init(roots: [URL], excludedFolders: [URL] = [], threshold: Float = 0.45, strictThreshold: Float = 0.30,
                window: TimeInterval = 300,
                neighbours: Int = 8, folderLimit: Int = 1_000, folderNeighbours: Int = 30,
                minimumSize: Int64 = 100_000, minimumSide: Int = 320, thumbnailSide: Int = 360, concurrency: Int = 4) {
        self.roots = roots
        self.excludedFolders = excludedFolders
        self.threshold = threshold
        self.strictThreshold = strictThreshold
        self.window = window
        self.neighbours = neighbours
        self.folderLimit = folderLimit
        self.folderNeighbours = folderNeighbours
        self.minimumSize = minimumSize
        self.minimumSide = minimumSide
        self.thumbnailSide = thumbnailSide
        self.concurrency = concurrency
    }

    /// Images, Bureau, Téléchargements et Documents, quand ils existent.
    public static func standardFolders(home: URL) -> [URL] {
        ["Pictures", "Desktop", "Downloads", "Documents"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Une image d'un groupe.
public struct SimilarImage: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let logicalSize: Int64
    public let allocated: Int64
    /// Ce que sa suppression rendrait vraiment (clones et snapshots déduits).
    public let privateSize: Int64
    public let modified: Date?
    /// La prise de vue (EXIF), quand le fichier la porte.
    public let captured: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(url: URL, logicalSize: Int64, allocated: Int64, privateSize: Int64, modified: Date?, captured: Date?,
                pixelWidth: Int, pixelHeight: Int) {
        self.url = url
        self.logicalSize = logicalSize
        self.allocated = allocated
        self.privateSize = privateSize
        self.modified = modified
        self.captured = captured
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var pixels: Int { pixelWidth * pixelHeight }
    /// Tous ses blocs sont partagés avec un autre fichier (clone APFS) : la
    /// jeter ne rendrait rien tant que l'autre existe.
    public var isClone: Bool { privateSize == 0 && allocated > 0 }

    /// La meilleure copie à garder : la plus grande résolution, puis l'originale,
    /// c'est-à-dire la plus ancienne (Romain, 18/10/2026 : l'étoile allait à une
    /// version éclaircie, plus récente, plutôt qu'à l'original), puis la plus
    /// lourde (le RAW d'un couple RAW + JPEG), puis le chemin pour trancher sans
    /// hasard.
    public func isBetter(than other: SimilarImage) -> Bool {
        if pixels != other.pixels { return pixels > other.pixels }
        if let mine = modified, let theirs = other.modified, abs(mine.timeIntervalSince(theirs)) >= 1 {
            return mine < theirs
        }
        if logicalSize != other.logicalSize { return logicalSize > other.logicalSize }
        return url.path < other.url.path
    }
}

/// Des images qui se ressemblent toutes deux à deux.
public struct SimilarImageGroup: Sendable, Hashable, Identifiable {
    /// La meilleure d'abord : celle que l'étoile suggère de garder. Rien n'est
    /// coché pour autant (RULES.md, règle 4).
    public let images: [SimilarImage]

    public init(images: [SimilarImage]) {
        self.images = images.sorted { $0.isBetter(than: $1) }
    }

    public var id: String { images.map(\.id).min() ?? "" }
    public var best: SimilarImage? { images.first }
    /// Ce que le groupe rendrait si l'on ne gardait que la meilleure.
    public var potential: Int64 { images.dropFirst().reduce(0) { $0 + $1.privateSize } }
}

/// Ce que la recherche a trouvé, et ce qu'elle a laissé de côté.
public struct SimilarImageFindings: Sendable {
    public var groups: [SimilarImageGroup] = []
    /// Les images examinées (assez grandes, lisibles).
    public var examined = 0
    /// Non téléchargées d'iCloud : on ne les lit pas, elles ne prennent rien ici.
    public var skippedInCloud = 0
    /// Illisibles : on ne propose pas ce qu'on n'a pas pu voir (RULES.md, règle 3).
    public var unreadable = 0

    public init() {}
}

/// L'avancement, lu par l'interface pendant que la recherche tourne.
public final class SimilarImageProgress: Sendable {
    public enum Stage: Int, Sendable {
        case listing, reading, printing, comparing
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

// MARK: - Empreintes

/// L'empreinte visuelle d'une image, comme `OustPhotos.FeaturePrint` : un
/// vecteur de Vision (révision 2, norme 1), comparé par distance euclidienne.
/// Gardée en mémoire le temps de la recherche, jamais écrite sur le disque.
public struct ImagePrint: Sendable, Hashable {
    public let vector: [Float]

    public init(_ vector: [Float]) {
        self.vector = vector
    }

    /// `nil` si les deux empreintes ne viennent pas du même modèle.
    public func distance(to other: ImagePrint) -> Float? {
        guard vector.count == other.vector.count, !vector.isEmpty else { return nil }
        var squared: Float = 0
        vDSP_distancesq(vector, 1, other.vector, 1, &squared, vDSP_Length(vector.count))
        return squared.squareRoot()
    }
}

/// Ce qui calcule l'empreinte d'une image : Vision, ou un faux dans les tests.
public protocol ImagePrinter: Sendable {
    func featurePrint(of url: URL, side: Int) -> ImagePrint?
}

/// Vision, sur une vignette décodée par ImageIO. Tout reste sur ce Mac :
/// `VNGenerateImageFeaturePrintRequest` tourne sur le processeur ou le Neural
/// Engine, sans réseau.
public struct VisionImagePrinter: ImagePrinter {
    public init() {}

    public func featurePrint(of url: URL, side: Int) -> ImagePrint? {
        guard let image = ImageReader.thumbnail(of: url, side: side) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first, observation.elementType == .float else { return nil }
        let vector = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return vector.count == observation.elementCount ? ImagePrint(vector) : nil
    }
}

/// Une vignette décodée. `CGImage` est immuable une fois créée : la passer
/// d'un fil à l'autre ne risque rien.
public struct ImageThumbnail: @unchecked Sendable {
    public let image: CGImage

    public init(_ image: CGImage) {
        self.image = image
    }
}

/// Lire une image sans la charger en entier.
public enum ImageReader {

    /// Ce que l'en-tête dit : dimensions affichées et date de prise de vue.
    public struct Facts: Sendable, Hashable {
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let captured: Date?
    }

    public static func facts(of url: URL) -> Facts? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        return Facts(pixelWidth: width, pixelHeight: height, captured: stamp.flatMap { exifDate($0, offset: offset) })
    }

    /// Une vignette d'au plus `side` pixels de côté, dans le bon sens.
    ///
    /// Décodée depuis l'image elle-même : la vignette EXIF d'un JPEG ne fait
    /// souvent que 160 px. Un RAW donne d'abord son aperçu intégré (un JPEG de
    /// bonne taille) : le développer entier prendrait une seconde par fichier.
    public static func thumbnail(of url: URL, side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        func make(always: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: always,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        if SimilarImageFinder.rawExtensions.contains(url.pathExtension.lowercased()),
           let preview = make(always: false), max(preview.width, preview.height) >= min(side, 320) {
            return preview
        }
        return make(always: true)
    }

    /// « 2026:10:18 14:32:10 », à l'heure de l'appareil : son décalage s'il l'a
    /// noté, sinon celui de ce Mac.
    static func exifDate(_ stamp: String, offset: String?) -> Date? {
        let digits = stamp.split(whereSeparator: { ":- T".contains($0) }).compactMap { Int($0) }
        guard digits.count >= 6, digits[0] > 1900 else { return nil }
        var components = DateComponents(year: digits[0], month: digits[1], day: digits[2],
                                        hour: digits[3], minute: digits[4], second: digits[5])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = offset.flatMap(timeZone) ?? .current
        components.calendar = calendar
        return components.date
    }

    /// « +02:00 » ou « -05:30 ».
    static func timeZone(_ offset: String) -> TimeZone? {
        let sign: Int = offset.hasPrefix("-") ? -1 : 1
        let parts = offset.trimmingCharacters(in: CharacterSet(charactersIn: "+-")).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return TimeZone(secondsFromGMT: sign * (parts[0] * 3_600 + parts[1] * 60))
    }
}

/// Les empreintes rendues par les fils de la file, chacune à sa place.
final class PrintSlots: Sendable {
    private let slots: Mutex<[ImagePrint?]>

    init(count: Int) {
        slots = Mutex([ImagePrint?](repeating: nil, count: count))
    }

    func set(_ slot: Int, _ print: ImagePrint?) {
        slots.withLock { $0[slot] = print }
    }

    var values: [ImagePrint?] { slots.withLock { $0 } }
}

// MARK: - Recherche

/// Les images qui se ressemblent dans les dossiers ordinaires, hors de la
/// photothèque (Romain, 18/10/2026 : « c'est bien de les prendre en compte même
/// si elles ne font pas partie de l'album photo »).
///
/// Sur demande seulement : il faut décoder chaque image et en tirer une
/// empreinte. Rien n'est envoyé nulle part ; les empreintes vivent en mémoire
/// le temps de la recherche. Rien n'est coché d'office (RULES.md, règle 4).
public enum SimilarImageFinder {

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp",
    ]
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f",
        "3fr", "iiq", "erf", "rwl",
    ]

    /// Ce qui n'est jamais ouvert, en plus des exclusions des doublons :
    /// photothèques, catalogues et leurs aperçus, bibliothèques d'applications,
    /// ressources de projets (les tailles d'une icône d'app se ressemblent
    /// toutes, et aucune n'est en trop).
    static let skippedExtensions: Set<String> = DuplicateFinder.skippedExtensions.union([
        "photolibrary", "migratedphotolibrary", "aplibrary", "lrlibrary", "lrdata", "lrcat-data", "cocatalog",
        "cosessiondb", "imovielibrary", "fcpbundle", "theater", "photoboothlibrary", "bundle", "framework",
        "plugin", "xcassets", "iconset", "appiconset", "imageset", "lproj", "xcodeproj", "xcworkspace",
    ])
    static let skippedFolderNames: Set<String> = DuplicateFinder.skippedFolders.union([
        "Photo Booth Library", "Lightroom", "Capture One", "Photos Library",
    ])
    /// Un fichier de catalogue écarte tout son dossier : Lightroom et Capture One
    /// y rangent aperçus et réglages, et parfois les images elles-mêmes.
    static let catalogExtensions: Set<String> = ["lrcat", "cocatalogdb", "cosessiondb"]

    public static func find(_ options: SimilarImageOptions, progress: SimilarImageProgress = SimilarImageProgress(),
                            printer: any ImagePrinter = VisionImagePrinter()) async -> SimilarImageFindings {
        // Lire un fichier iCloud non téléchargé le ferait télécharger : jamais.
        Scanner.configureProcessIOPolicy()
        var findings = SimilarImageFindings()

        progress.begin(.listing, total: 0)
        let listing = collect(options, progress: progress)
        findings.skippedInCloud = listing.skippedInCloud
        guard !progress.isCancelled else { return findings }

        // Dimensions et dates, par l'en-tête seulement.
        progress.begin(.reading, total: listing.files.count)
        var images: [Candidate] = []
        for file in listing.files {
            guard !progress.isCancelled else { return findings }
            progress.advance()
            guard let facts = ImageReader.facts(of: file.url) else { findings.unreadable += 1; continue }
            guard min(facts.pixelWidth, facts.pixelHeight) >= options.minimumSide else { continue }
            images.append(Candidate(file: file, facts: facts))
        }
        findings.examined = images.count

        let stems = images.map { stem(of: $0.file.url) }
        let pairs = candidatePairs(images, stems: stems, options: options)
        let needed = pairedImageIndices(pairs, imageCount: images.count)
        progress.begin(.printing, total: needed.count)
        let prints = await featurePrints(of: needed.map { images[$0].file.url }, options: options,
                                         printer: printer, progress: progress)
        guard !progress.isCancelled else { return findings }
        var printed: [Int: ImagePrint] = [:]
        for (slot, index) in needed.enumerated() {
            if let print = prints[slot] { printed[index] = print } else { findings.unreadable += 1 }
        }

        progress.begin(.comparing, total: pairs.count)
        let clusters = cluster(pairs: pairs, prints: printed) { a, b in
            sameShot(images[a], images[b], stems: (stems[a], stems[b]), window: options.window)
                ? options.threshold : options.strictThreshold
        }
        findings.groups = clusters.map { members in
            SimilarImageGroup(images: members.map { index in
                let file = images[index].file
                let facts = images[index].facts
                return SimilarImage(url: file.url, logicalSize: file.logicalSize, allocated: file.allocated,
                                    privateSize: Scanner.privateSize(of: file.url) ?? file.allocated,
                                    modified: file.modified, captured: facts.captured,
                                    pixelWidth: facts.pixelWidth, pixelHeight: facts.pixelHeight)
            })
        }
        .sorted { ($0.potential, $0.id) > ($1.potential, $1.id) }
        progress.advance(by: pairs.count)
        return findings
    }

    // MARK: Parcours

    struct File: Sendable, Hashable {
        let url: URL
        let logicalSize: Int64
        let allocated: Int64
        let fileID: String?
        let contentID: Int64?
        let sharesContent: Bool
        let modified: Date?
    }

    struct Candidate: Sendable {
        let file: File
        let facts: ImageReader.Facts
        /// La date qui rapproche deux images : la prise de vue, sinon la modification.
        var date: Date? { facts.captured ?? file.modified }
        var folder: String { file.url.deletingLastPathComponent().path }
    }

    static func collect(_ options: SimilarImageOptions,
                        progress: SimilarImageProgress) -> (files: [File], skippedInCloud: Int) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .fileResourceIdentifierKey, .fileContentIdentifierKey, .mayShareFileContentKey, .contentModificationDateKey,
        ]
        let excluded = Set(options.excludedFolders.map { $0.standardizedFileURL.path })
        var files: [File] = []
        var seen = Set<String>()
        var catalogFolders: [String] = []
        var skippedInCloud = 0
        for root in options.roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                guard !progress.isCancelled else { break }
                let ext = url.pathExtension.lowercased()
                // Par le nom seul : les attributs d'un catalogue vide, ou verrouillé
                // par Lightroom ouvert, peuvent ne pas se lire.
                if catalogExtensions.contains(ext) {
                    catalogFolders.append(url.deletingLastPathComponent().standardizedFileURL.path + "/")
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    // Un point de montage sous un dossier choisi : un autre disque,
                    // jamais parcouru sans qu'on l'ait choisi (RULES.md, règle 10).
                    if values.isVolume == true || skippedFolderNames.contains(url.lastPathComponent)
                        || skippedExtensions.contains(ext) || excluded.contains(url.standardizedFileURL.path)
                        || isRepository(url) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true, imageExtensions.contains(ext) || rawExtensions.contains(ext),
                      let size = values.fileSize, Int64(size) >= options.minimumSize else { continue }
                // Un fichier évincé par iCloud n'occupe rien : le lire le
                // téléchargerait, le jeter ne rendrait rien.
                guard let allocated = values.totalFileAllocatedSize, allocated > 0 else {
                    skippedInCloud += 1
                    continue
                }
                guard !isScreenshot(url), seen.insert(url.standardizedFileURL.path).inserted else { continue }
                progress.advance()
                files.append(File(
                    url: url.standardizedFileURL, logicalSize: Int64(size), allocated: Int64(allocated),
                    fileID: values.fileResourceIdentifier.map { "\($0)" }, contentID: values.fileContentIdentifier,
                    sharesContent: values.mayShareFileContent ?? false, modified: values.contentModificationDate
                ))
            }
        }
        if !catalogFolders.isEmpty {
            files.removeAll { file in catalogFolders.contains { file.url.path.hasPrefix($0) } }
        }
        return (collapseShared(files), skippedInCloud)
    }

    /// Deux images d'une même prise de vue, ou deux copies d'un même fichier :
    /// mêmes dates EXIF à `window` près, ou même nom au suffixe de copie près.
    /// La date de modification ne compte pas : des images générées ou
    /// téléchargées en lot naissent à quelques secondes d'écart sans rien avoir
    /// de commun.
    static func sameShot(_ a: Candidate, _ b: Candidate, stems: (String, String), window: TimeInterval) -> Bool {
        if stems.0 == stems.1 { return true }
        guard let first = a.facts.captured, let second = b.facts.captured else { return false }
        return abs(first.timeIntervalSince(second)) <= window
    }

    /// Un dépôt git : ses images sont des ressources du projet, suivies par git.
    static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// Les captures d'écran ont leur règle (`screenshots.desktop`) ; les
    /// comparer réunirait toutes celles d'une même application, qui disent
    /// chacune autre chose. Photos les écarte de même. Même preuve que la règle :
    /// l'attribut posé par macOS, sinon le nom.
    static func isScreenshot(_ url: URL) -> Bool {
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW) > 0 { return true }
        let name = url.lastPathComponent
        return ["Screenshot", "Screen Shot", "Capture d’écran", "Capture d'écran", "CleanShot"].contains { name.hasPrefix($0) }
    }

    /// Un lien physique ou un clone complet n'est pas une copie de plus : le
    /// retirer ne rendrait rien. Un seul représentant.
    static func collapseShared(_ files: [File]) -> [File] {
        var inodes = Set<String>()
        var contents = Set<Int64>()
        return files.filter { file in
            if let id = file.fileID, !inodes.insert(id).inserted { return false }
            if file.sharesContent, let content = file.contentID, !contents.insert(content).inserted { return false }
            return true
        }
    }

    // MARK: Paires

    /// Les paires à comparer, jamais tout à tout :
    /// - dans un même dossier, toutes (ou les voisines de date, s'il est très grand) ;
    /// - d'un dossier à l'autre, les images prises ou modifiées à moins de `window` ;
    /// - où qu'elles soient, celles qui portent le même nom au suffixe de copie près.
    static func candidatePairs(_ images: [Candidate], stems: [String],
                               options: SimilarImageOptions) -> [(Int, Int)] {
        var keys = Set<UInt64>()
        func add(_ a: Int, _ b: Int) {
            guard a != b else { return }
            keys.insert(UInt64(min(a, b)) << 32 | UInt64(max(a, b)))
        }
        func byDate(_ indices: [Int]) -> [Int] {
            indices.sorted { (images[$0].date ?? .distantPast, $0) < (images[$1].date ?? .distantPast, $1) }
        }

        for (_, members) in Dictionary(grouping: images.indices, by: { images[$0].folder }) where members.count > 1 {
            if members.count <= options.folderLimit {
                for (position, a) in members.enumerated() {
                    for b in members[(position + 1)...] { add(a, b) }
                }
            } else {
                let sorted = byDate(members)
                for position in sorted.indices {
                    for other in (position + 1)..<min(sorted.count, position + 1 + options.folderNeighbours) {
                        add(sorted[position], sorted[other])
                    }
                }
            }
        }

        let dated = byDate(images.indices.filter { images[$0].date != nil })
        for position in dated.indices {
            let start = images[dated[position]].date!
            var other = position + 1
            while other < dated.count, other - position <= options.neighbours,
                  images[dated[other]].date!.timeIntervalSince(start) <= options.window {
                add(dated[position], dated[other])
                other += 1
            }
        }

        for (_, members) in Dictionary(grouping: images.indices, by: { stems[$0] })
        where members.count > 1 && members.count <= 30 {
            for (position, a) in members.enumerated() {
                for b in members[(position + 1)...] { add(a, b) }
            }
        }

        return keys.sorted().map { (Int($0 >> 32), Int($0 & 0xFFFF_FFFF)) }
    }

    /// Marque les images à lire sans créer un tableau de deux éléments par paire.
    static func pairedImageIndices(_ pairs: [(Int, Int)], imageCount: Int) -> [Int] {
        var paired = Array(repeating: false, count: imageCount)
        for (first, second) in pairs {
            paired[first] = true
            paired[second] = true
        }
        return paired.indices.filter { paired[$0] }
    }

    /// Le nom sans extension ni suffixe de copie : « IMG_1234 (1).jpg »,
    /// « IMG_1234 copie.heic » et « IMG_1234-edited.png » donnent « img_1234 ».
    static func stem(of url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent.lowercased()
        let suffixes = [#" \(\d{1,3}\)$"#, #" (copy|copie|kopie|copia)( \d+)?$"#, #"[-_ ](edited|modifié|modifie|bearbeitet|small|large|web|export|final)$"#,
                        #"@\dx$"#]
        var changed = true
        while changed {
            changed = false
            for pattern in suffixes {
                if let range = name.range(of: pattern, options: .regularExpression), range.lowerBound > name.startIndex {
                    name.removeSubrange(range)
                    changed = true
                }
            }
        }
        return name
    }

    // MARK: Empreintes et groupes

    /// Les empreintes, `concurrency` à la fois, sur des fils à elles.
    ///
    /// Pas dans le pool coopératif de Swift : Vision y attend un travail
    /// interne, et plusieurs appels à la fois l'ont figé pour de bon (tests du
    /// 18/10/2026 : tous les fils arrêtés dans `VNControlledCapacityTasksQueue`,
    /// trois recherches en parallèle). Dans l'app, la recherche de Photos et
    /// celle-ci tournant ensemble auraient pu en faire autant.
    static func featurePrints(of urls: [URL], options: SimilarImageOptions, printer: any ImagePrinter,
                              progress: SimilarImageProgress) async -> [ImagePrint?] {
        let prints = PrintSlots(count: urls.count)
        let side = options.thumbnailSide
        let width = max(1, options.concurrency)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let queue = OperationQueue()
                queue.name = "fr.meaillais.oust.similar-images"
                queue.maxConcurrentOperationCount = width
                queue.qualityOfService = .userInitiated
                for (slot, url) in urls.enumerated() {
                    queue.addOperation {
                        defer { progress.advance() }
                        guard !progress.isCancelled else { return }
                        prints.set(slot, autoreleasepool { printer.featurePrint(of: url, side: side) })
                    }
                }
                queue.addBarrierBlock { continuation.resume() }
            }
        } onCancel: {
            // Les fils de la file ne voient pas l'annulation de la tâche : le drapeau, si.
            progress.cancel()
        }
        return prints.values
    }

    /// Les groupes, de la paire la plus proche à la plus lointaine. Deux groupes
    /// ne se joignent que si chacune de leurs images ressemble à chacune des
    /// autres : de proche en proche, une suite de photos d'un même lieu finirait
    /// en un seul groupe dont les deux bouts n'ont plus rien de commun.
    ///
    /// `threshold` : le seuil d'une paire, selon ce qu'on sait d'elle (même prise
    /// de vue ou non).
    static func cluster(pairs: [(Int, Int)], prints: [Int: ImagePrint],
                        threshold: (Int, Int) -> Float) -> [[Int]] {
        var edges: [(Float, Int, Int)] = []
        for (a, b) in pairs {
            guard let first = prints[a], let second = prints[b], let distance = first.distance(to: second),
                  distance <= threshold(a, b) else { continue }
            edges.append((distance, a, b))
        }
        edges.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }

        var groupOf: [Int: Int] = [:]
        var members: [Int: [Int]] = [:]
        func group(_ index: Int) -> Int {
            if let id = groupOf[index] { return id }
            groupOf[index] = index
            members[index] = [index]
            return index
        }
        for (_, a, b) in edges {
            let (ga, gb) = (group(a), group(b))
            guard ga != gb, let left = members[ga], let right = members[gb] else { continue }
            let alike = left.allSatisfy { x in
                right.allSatisfy { y in
                    guard let px = prints[x], let py = prints[y], let distance = px.distance(to: py) else { return false }
                    return distance <= threshold(x, y)
                }
            }
            guard alike else { continue }
            let (kept, merged) = left.count >= right.count ? (ga, gb) : (gb, ga)
            for index in members[merged] ?? [] { groupOf[index] = kept }
            members[kept, default: []] += members[merged] ?? []
            members[merged] = nil
        }
        return members.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}

extension SimilarImageGroup {
    /// Cocher une image n'est possible que s'il reste au moins une autre image
    /// du groupe à garder : jamais toutes (SPEC §7). Décocher l'est toujours.
    /// `checked` : les chemins déjà dans la corbeille, sous quelque élément que ce soit.
    public func canToggle(_ image: SimilarImage, checked: Set<String>) -> Bool {
        if checked.contains(image.url.path) { return true }
        return images.count(where: { checked.contains($0.url.path) }) < images.count - 1
    }

    /// L'élément de la corbeille d'une image du groupe. Toujours « À examiner » :
    /// une image ressemblante n'est pas une copie, et l'étoile n'est qu'une
    /// suggestion.
    public func cleanupItem(for image: SimilarImage) -> CleanupItem {
        CleanupItem(
            id: "similar|\(image.url.path)",
            title: image.url.lastPathComponent,
            detail: image.url.deletingLastPathComponent().path,
            paths: [image.url],
            category: .similarImages,
            owner: best?.url.lastPathComponent ?? "",
            ruleID: "duplicate.similar",
            safety: .review,
            method: .trash,
            sizes: Sizes(allocated: image.allocated, freeable: image.privateSize),
            lastActivity: image.modified,
            rebuild: .irreversible,
            fingerprint: Fingerprint(modificationDate: image.modified, fileID: nil)
        )
    }
}
