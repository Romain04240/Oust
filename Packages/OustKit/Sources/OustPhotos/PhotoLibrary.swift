import AVFoundation
import CoreGraphics
import Foundation
import OustCore
import Photos

// MARK: - Ce que l'analyse demande à la photothèque

/// La photothèque, vue par Oust!.
///
/// Tout passe par PhotoKit : le paquet `.photoslibrary` n'est jamais lu ni
/// parcouru (la garde de chemins le refuse d'ailleurs, SPEC §5). Le protocole
/// existe pour que les tests tournent sans photothèque ni autorisation ;
/// `SystemPhotoLibrary` est la seule implémentation livrée.
///
/// Rien ici ne télécharge depuis iCloud (RULES.md, règle 11) : une ressource
/// absente du Mac reste absente, et ce qu'on ne peut pas lire n'est pas proposé.
public protocol PhotoLibrary: Sendable {
    /// L'état de l'autorisation, sans rien demander.
    func access() -> PhotoAccess
    /// Fait paraître l'invite de macOS si l'utilisateur n'a pas encore répondu.
    func requestAccess() async -> PhotoAccess
    /// Toute la photothèque de l'utilisateur, éléments masqués exclus.
    func assets() async -> [PhotoAsset]
    /// Les ressources de chaque élément : leur taille et leur présence sur ce
    /// Mac. Par lots, une requête à la base de Photos pour tout le lot.
    func resources(of ids: [String]) async -> [String: [PhotoResource]]
    /// SHA-256 des ressources originales, lues sur ce Mac seulement ; `nil` si
    /// l'une d'elles n'y est pas ou ne se lit pas.
    func digest(of id: String) async -> Data?
    /// L'empreinte visuelle (Vision) d'une vignette déjà présente sur ce Mac.
    func featurePrint(of id: String) async -> FeaturePrint?
    /// Ce que Vision voit sur une vignette locale : visages, codes, document, texte.
    func signals(of id: String) async -> PhotoSignals?
    /// Une vignette locale, pour qu'on choisisse en voyant.
    func thumbnail(of id: String, side: Int) async -> PhotoThumbnail?
    /// L'image en grand, pour l'aperçu. Sans réseau : la meilleure version
    /// présente sur ce Mac. Avec : l'original depuis iCloud, seulement quand
    /// l'utilisateur l'a demandé pour cet élément.
    func image(of id: String, side: Int, allowNetwork: Bool) async -> PhotoImage?
    /// La vidéo, à lire dans l'aperçu ; même règle pour le réseau.
    func video(of id: String, allowNetwork: Bool) async -> PhotoVideo?
    /// La Live Photo, qui s'anime dans l'aperçu ; même règle pour le réseau.
    func livePhoto(of id: String, side: Int, allowNetwork: Bool) async -> PhotoLive?
    /// Les albums de l'utilisateur qui contiennent l'élément.
    func albums(of id: String) async -> [String]
    /// Ceux de ces identifiants qui existent encore.
    func existing(_ ids: [String]) async -> Set<String>
    /// Un signal à chaque changement de la photothèque, y compris ceux faits
    /// dans Photos pendant qu'Oust! est ouvert.
    func changes() -> AsyncStream<Void>
}

/// L'autorisation d'accès à Photos.
public enum PhotoAccess: Sendable, Hashable {
    case notDetermined
    /// Refusée dans Réglages Système : seul l'utilisateur peut la rendre.
    case denied
    /// Interdite par un profil de gestion.
    case restricted
    case authorized
    /// Une sélection seulement : ce qu'on trouve n'est qu'une partie.
    case limited

    public var canRead: Bool { self == .authorized || self == .limited }
}

// MARK: - Éléments et ressources

public enum PhotoMedia: String, Sendable, Hashable, Codable {
    case image, video, other
}

/// Un élément de la photothèque, tel que PhotoKit le décrit sans rien lire.
public struct PhotoAsset: Sendable, Hashable, Identifiable {
    /// L'identifiant local de PhotoKit.
    public let id: String
    public var media: PhotoMedia
    public var isScreenshot: Bool
    public var isScreenRecording: Bool
    public var isLivePhoto: Bool
    public var created: Date?
    public var duration: TimeInterval
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var facts: PhotoFacts

    public init(id: String, media: PhotoMedia, isScreenshot: Bool = false, isScreenRecording: Bool = false,
                isLivePhoto: Bool = false, created: Date?, duration: TimeInterval = 0, pixelWidth: Int = 0,
                pixelHeight: Int = 0, facts: PhotoFacts = PhotoFacts()) {
        self.id = id
        self.media = media
        self.isScreenshot = isScreenshot
        self.isScreenRecording = isScreenRecording
        self.isLivePhoto = isLivePhoto
        self.created = created
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.facts = facts
    }
}

/// Une ressource d'un élément : la photo, la vidéo d'une Live Photo, le RAW,
/// une retouche…
public struct PhotoResource: Sendable, Hashable {
    /// Ce que l'appareil ou l'import a produit (photo, vidéo, son, RAW, vidéo
    /// jumelée) : c'est ce qu'on compare entre deux doublons. Les retouches et
    /// leurs rendus n'en sont pas.
    public var isOriginal: Bool
    public var filename: String
    /// En octets ; `nil` quand Photos ne le dit pas.
    public var size: Int64?
    /// Présente sur ce Mac ; `nil` quand on n'a pas pu le savoir.
    public var isLocal: Bool?

    public init(isOriginal: Bool, filename: String, size: Int64?, isLocal: Bool?) {
        self.isOriginal = isOriginal
        self.filename = filename
        self.size = size
        self.isLocal = isLocal
    }
}

/// Ce que la suppression d'un élément rendrait (RULES.md, règle 9).
public struct PhotoSize: Sendable, Hashable {
    /// Toutes ses ressources, où qu'elles soient : ce que compte iCloud.
    public var total: Int64
    /// Celles qui sont sur ce Mac : ce que la suppression y rend vraiment.
    /// Une ressource dont on ignore la présence n'y est pas comptée.
    public var local: Int64
    /// Faux si une taille ou une présence manquait : les chiffres sont des minima.
    public var isComplete: Bool

    public init(total: Int64, local: Int64, isComplete: Bool = true) {
        self.total = total
        self.local = min(local, total)
        self.isComplete = isComplete
    }

    public init(_ resources: [PhotoResource]) {
        var total: Int64 = 0
        var local: Int64 = 0
        var complete = true
        for resource in resources {
            guard let size = resource.size else { complete = false; continue }
            total += size
            switch resource.isLocal {
            case true?: local += size
            case false?: break
            case nil: complete = false
            }
        }
        self.init(total: total, local: local, isComplete: complete)
    }

    /// La part qui n'est que dans iCloud (« Optimiser le stockage du Mac »).
    public var inCloudOnly: Int64 { max(0, total - local) }

    /// Évincé par Photos iCloud : la suppression rendrait moins d'un dixième
    /// de la taille de l'élément sur ce Mac.
    public var isMostlyInCloud: Bool { total > 0 && local * 10 < total }

    public static let zero = PhotoSize(total: 0, local: 0)
}

// MARK: - Empreintes et vignettes

/// L'empreinte visuelle d'une photo, d'après `VNFeaturePrintObservation`.
///
/// Gardée en simple vecteur : la distance se calcule sans Vision, et les tests
/// en fabriquent à la main. Vision (révision 2) rend des vecteurs de norme 1 ;
/// sa `computeDistance` est la distance euclidienne, recalculée ici à
/// l'identique (vérifié le 18/10/2026 : 0,903685 des deux côtés).
public struct FeaturePrint: Sendable, Hashable {
    public let vector: [Float]

    public init(_ vector: [Float]) {
        self.vector = vector
    }

    /// `nil` si les deux empreintes ne viennent pas du même modèle.
    public func distance(to other: FeaturePrint) -> Float? {
        guard vector.count == other.vector.count, !vector.isEmpty else { return nil }
        var sum: Float = 0
        for index in vector.indices {
            let delta = vector[index] - other.vector[index]
            sum += delta * delta
        }
        return sum.squareRoot()
    }
}

/// Une vignette. `CGImage` est immuable une fois créée : la passer d'un fil à
/// l'autre ne risque rien.
public struct PhotoThumbnail: @unchecked Sendable {
    public let image: CGImage

    public init(_ image: CGImage) {
        self.image = image
    }
}

/// L'image de l'aperçu.
public struct PhotoImage: Sendable {
    public let thumbnail: PhotoThumbnail
    /// L'original n'est que dans iCloud : c'est une version réduite, gardée sur
    /// ce Mac, qu'on montre — et on le dit.
    public let isReduced: Bool

    public init(_ thumbnail: PhotoThumbnail, isReduced: Bool) {
        self.thumbnail = thumbnail
        self.isReduced = isReduced
    }
}

/// La vidéo de l'aperçu. L'objet ne passe qu'une fois d'un fil à l'autre, de
/// PhotoKit au lecteur, qui seul s'en sert ensuite.
public struct PhotoVideo: @unchecked Sendable {
    public let item: AVPlayerItem

    public init(_ item: AVPlayerItem) {
        self.item = item
    }
}

/// La Live Photo de l'aperçu ; `PHLivePhoto` est immuable.
public struct PhotoLive: @unchecked Sendable {
    public let livePhoto: PHLivePhoto
    /// Il manque une partie du contenu (la vidéo, dans iCloud) : elle ne s'animera pas.
    public let isReduced: Bool

    public init(_ livePhoto: PHLivePhoto, isReduced: Bool) {
        self.livePhoto = livePhoto
        self.isReduced = isReduced
    }
}
