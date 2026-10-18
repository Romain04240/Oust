import Foundation
import OustCore

/// Ce qu'une photo prise « pour garder une information » montre.
///
/// Demandé par Romain (18/10/2026) : les étiquettes, les écrans d'ordinateur, les
/// codes-barres, les documents photographiés pour les scanner — prises un instant,
/// oubliées ensuite. L'ordre des cas est celui du tri à l'écran.
public enum PhotoUtilityKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case barcode, document, receipt, card, screen, text

    public var id: String { rawValue }
    public var localizationKey: String { "photos.utility_kind.\(rawValue)" }

    public var symbol: String {
        switch self {
        case .barcode: "barcode.viewfinder"
        case .document: "doc.text.viewfinder"
        case .receipt: "receipt"
        case .card: "creditcard"
        case .screen: "display"
        case .text: "text.viewfinder"
        }
    }

    /// Une pièce d'identité, un contrat, une carte bancaire ne se jettent pas par
    /// lot : ces deux familles se cochent une par une.
    public var allowsSelectAll: Bool {
        switch self {
        case .document, .card: false
        case .barcode, .receipt, .screen, .text: true
        }
    }
}

/// Ce que Vision voit sur une vignette de la photo, sur ce Mac.
public struct PhotoSignals: Sendable, Hashable {
    /// Visages détectés : une photo où figure quelqu'un n'est jamais proposée.
    public var faces: Int
    /// Codes-barres et QR codes lisibles.
    public var barcodes: Int
    /// Le classement de Vision (`VNClassifyImageRequest`) : étiquette → confiance.
    public var labels: [String: Float]
    /// La confiance qu'une feuille entière est photographiée (son contour).
    public var documentOutline: Float
    /// Combien de caractères Vision lit sur l'image.
    public var textCharacters: Int

    public init(faces: Int = 0, barcodes: Int = 0, labels: [String: Float] = [:], documentOutline: Float = 0,
                textCharacters: Int = 0) {
        self.faces = faces
        self.barcodes = barcodes
        self.labels = labels
        self.documentOutline = documentOutline
        self.textCharacters = textCharacters
    }
}

/// Décide, d'après les signaux, si une photo est « utile » et de quelle famille.
///
/// Seuils mesurés le 18/10/2026 sur des vignettes de 1 024 points : une page à
/// plat donne « document » à 0,49 ; photographiée de biais, 0,64 et un contour
/// à 0,99 ; un ticket photographié, « document » à 0,32, un contour à 0,99 et
/// 87 caractères lus ; des paysages, rien de tout cela et aucun caractère. Codes
/// QR et Code 128 : détectés à chaque fois. Dans le doute, la photo n'est pas
/// proposée.
public enum UtilityClassifier {
    static let people = ["people", "adult", "child", "baby", "portrait", "selfie", "crowd"]
    static let receipts = ["receipt", "ticket"]
    static let cards = ["credit_card", "gift_card"]
    static let screens = ["computer_monitor", "laptop", "computer_keyboard", "screenshot"]
    static let documents = ["document", "printed_page", "handwriting", "newspaper", "whiteboard"]

    public static func kind(of signals: PhotoSignals) -> PhotoUtilityKind? {
        func score(_ names: [String]) -> Float { names.map { signals.labels[$0] ?? 0 }.max() ?? 0 }
        guard signals.faces == 0, score(people) < 0.3 else { return nil }
        if signals.barcodes > 0 { return .barcode }
        if score(receipts) >= 0.4 { return .receipt }
        if score(cards) >= 0.4 { return .card }
        if score(screens) >= 0.5 { return .screen }
        let document = score(documents)
        if document >= 0.45 || (document >= 0.25 && signals.documentOutline >= 0.8) { return .document }
        if signals.textCharacters >= 60 { return .text }
        return nil
    }
}

/// Une photo utile trouvée, et sa famille.
public struct PhotoUtilityMatch: Sendable, Hashable, Identifiable {
    public let entry: PhotoEntry
    public let kind: PhotoUtilityKind

    public var id: String { entry.id }

    public init(entry: PhotoEntry, kind: PhotoUtilityKind) {
        self.entry = entry
        self.kind = kind
    }
}

extension PhotoAnalyzer {
    /// Les photos utiles, sur demande : Vision regarde chaque photo de la période.
    ///
    /// Les captures d'écran ont leur onglet, les vidéos aussi : seules les photos
    /// sont lues. Rien n'est jamais coché d'office (RULES.md, règle 4).
    public static func utilities(_ library: any PhotoLibrary, among assets: [PhotoAsset], since: Date? = nil,
                                 progress: PhotoProgress = PhotoProgress()) async -> [PhotoUtilityMatch] {
        let photos = assets.filter { asset in
            guard asset.media == .image, !asset.isScreenshot else { return false }
            guard let since else { return true }
            return asset.created.map { $0 >= since } ?? false
        }
        progress.begin(.classifying, total: photos.count)
        var kinds: [String: PhotoUtilityKind] = [:]
        await withTaskGroup(of: (String, PhotoUtilityKind?).self) { group in
            var next = 0
            // Cinq analyses Vision par photo : quatre photos à la fois.
            func launch() {
                guard next < photos.count else { return }
                let id = photos[next].id
                next += 1
                group.addTask {
                    guard !progress.isCancelled, let signals = await library.signals(of: id) else { return (id, nil) }
                    return (id, UtilityClassifier.kind(of: signals))
                }
            }
            for _ in 0..<4 { launch() }
            for await (id, kind) in group {
                if let kind { kinds[id] = kind }
                progress.advance()
                if !progress.isCancelled { launch() }
            }
        }
        guard !progress.isCancelled else { return [] }

        let found = photos.filter { kinds[$0.id] != nil }
        var resources: [String: [PhotoResource]] = [:]
        for start in stride(from: 0, to: found.count, by: batchSize) {
            let batch = found[start..<min(start + batchSize, found.count)].map(\.id)
            resources.merge(await library.resources(of: batch)) { _, new in new }
        }
        let order = Dictionary(uniqueKeysWithValues: PhotoUtilityKind.allCases.enumerated().map { ($1, $0) })
        return found.compactMap { asset -> PhotoUtilityMatch? in
            guard let kind = kinds[asset.id] else { return nil }
            let list = resources[asset.id] ?? []
            return PhotoUtilityMatch(entry: PhotoEntry(asset: asset, title: title(of: list, fallback: asset), size: PhotoSize(list)),
                                     kind: kind)
        }
        // Par famille, puis de la plus récente à la plus ancienne.
        .sorted {
            (order[$0.kind] ?? 0, -($0.entry.asset.created?.timeIntervalSince1970 ?? 0), $0.id)
                < (order[$1.kind] ?? 0, -($1.entry.asset.created?.timeIntervalSince1970 ?? 0), $1.id)
        }
    }
}
