import AppKit
import CryptoKit
import Foundation
import OustCore
import Photos
import Vision

/// La photothèque système, par PhotoKit et Vision.
///
/// Toutes les requêtes interdisent le réseau (`isNetworkAccessAllowed = false`) :
/// Oust! ne fait rien télécharger d'iCloud, pas même une vignette (RULES.md,
/// règle 11). Ce qui n'est pas sur le Mac est dit tel, et jamais comparé.
public struct SystemPhotoLibrary: PhotoLibrary {
    public init() {}

    // MARK: Autorisation

    public func access() -> PhotoAccess {
        Self.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAccess() async -> PhotoAccess {
        Self.access(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func access(_ status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: Éléments

    public func assets() async -> [PhotoAsset] {
        guard access().canRead else { return [] }
        let options = PHFetchOptions()
        // Les éléments masqués ne sont pas lus : on ne propose pas ce que
        // l'utilisateur a mis à l'écart, et que l'accès ne montre pas toujours.
        options.includeHiddenAssets = false
        // Sa photothèque seulement : les albums partagés sont à d'autres.
        options.includeAssetSourceTypes = [.typeUserLibrary]
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PhotoAsset] = []
        assets.reserveCapacity(result.count)
        for index in 0..<result.count {
            assets.append(Self.describe(result.object(at: index)))
        }
        return assets
    }

    static func describe(_ asset: PHAsset) -> PhotoAsset {
        let media: PhotoMedia = switch asset.mediaType {
        case .image: .image
        case .video: .video
        default: .other
        }
        return PhotoAsset(
            id: asset.localIdentifier, media: media,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isScreenRecording: asset.mediaSubtypes.contains(.videoScreenRecording),
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            created: asset.creationDate, duration: asset.duration,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            facts: facts(of: asset)
        )
    }

    /// Ce qui décide de la protection. OustClean relit les mêmes propriétés,
    /// juste avant de supprimer (`SystemPhotoEraser.facts`) : toute retouche
    /// ici se reporte là-bas.
    static func facts(of asset: PHAsset) -> PhotoFacts {
        PhotoFacts(
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            isShared: asset.sourceType != .typeUserLibrary || isInSharedLibrary(asset),
            canDelete: asset.canPerform(.delete),
            editedAt: asset.adjustmentTimestamp
        )
    }

    /// La photothèque partagée d'iCloud n'a pas d'API publique : PhotoKit
    /// répond par `participatesInLibraryScope`, qu'on n'interroge que s'il
    /// existe. Supprimer un élément partagé le retirerait chez tous les
    /// participants ; mieux vaut le protéger à tort que l'inverse.
    static func isInSharedLibrary(_ asset: PHAsset) -> Bool {
        guard asset.responds(to: NSSelectorFromString("participatesInLibraryScope")) else { return false }
        return (asset.value(forKey: "participatesInLibraryScope") as? Bool) ?? false
    }

    public func existing(_ ids: [String]) async -> Set<String> {
        guard access().canRead, !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var found = Set<String>()
        for index in 0..<result.count { found.insert(result.object(at: index).localIdentifier) }
        return found
    }

    // MARK: Ressources

    /// Ce que produit l'appareil ou l'import ; les retouches et leurs rendus n'en sont pas.
    static let originalTypes: Set<PHAssetResourceType> = [.photo, .video, .audio, .alternatePhoto, .pairedVideo]

    public func resources(of ids: [String]) async -> [String: [PhotoResource]] {
        guard access().canRead, !ids.isEmpty else { return [:] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: [PhotoResource]] = [:]
        for index in 0..<result.count {
            let asset = result.object(at: index)
            var list: [PhotoResource] = []
            for resource in PHAssetResource.assetResources(for: asset) {
                let local = await Self.isLocal(resource)
                list.append(PhotoResource(isOriginal: Self.originalTypes.contains(resource.type),
                                          filename: Self.filename(of: resource), size: Self.size(of: resource),
                                          isLocal: local))
            }
            byID[asset.localIdentifier] = list
        }
        return byID
    }

    static func filename(of resource: PHAssetResource) -> String {
        if #available(macOS 27, *) { return resource.filename ?? "" }
        return resource.originalFilename
    }

    /// La taille d'une ressource. Publique depuis macOS 27 (`dataSize`) ; avant,
    /// seulement par la propriété privée `fileSize`, lue si elle existe.
    static func size(of resource: PHAssetResource) -> Int64? {
        if #available(macOS 27, *), let size = resource.dataSize { return Int64(size) }
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    /// La ressource est-elle sur ce Mac ? PhotoKit le sait (`locallyAvailable`)
    /// sans le publier ; à défaut, on demande ses premiers octets sans réseau :
    /// s'ils arrivent, elle est là.
    static func isLocal(_ resource: PHAssetResource) async -> Bool? {
        if resource.responds(to: NSSelectorFromString("isLocallyAvailable")) {
            return resource.value(forKey: "locallyAvailable") as? Bool
        }
        return await probeLocal(resource)
    }

    static func probeLocal(_ resource: PHAssetResource) async -> Bool? {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let manager = PHAssetResourceManager.default()
        let request = Locked<PHAssetResourceDataRequestID?>(nil)
        let answered = Locked(false)
        return await withCheckedContinuation { continuation in
            let id = manager.requestData(for: resource, options: options) { _ in
                guard answered.claim() else { return }
                continuation.resume(returning: true)
                if let id = request.withLock({ $0 }) { manager.cancelDataRequest(id) }
            } completionHandler: { error in
                guard answered.claim() else { return }
                // Une ressource vide mais présente finit sans erreur ni octet.
                continuation.resume(returning: error == nil ? true : (Self.isNotLocal(error) ? false : nil))
            }
            request.withLock { $0 = id }
        }
    }

    static func isNotLocal(_ error: (any Error)?) -> Bool {
        guard let error = error as? NSError else { return false }
        return error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.networkAccessRequired.rawValue
    }

    // MARK: Empreintes

    public func digest(of id: String) async -> Data? {
        guard access().canRead, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let originals = PHAssetResource.assetResources(for: asset)
            .filter { Self.originalTypes.contains($0.type) }
            .sorted { $0.type.rawValue < $1.type.rawValue }
        guard !originals.isEmpty else { return nil }
        let hasher = Locked(SHA256())
        for resource in originals {
            hasher.withLock { $0.update(data: Data("\(resource.type.rawValue)|".utf8)) }
            guard await Self.read(resource, into: hasher) else { return nil }
        }
        return Data(hasher.withLock { $0.finalize() })
    }

    /// Lit une ressource jusqu'au bout, sans réseau, dans l'empreinte.
    static func read(_ resource: PHAssetResource, into hasher: Locked<SHA256>) async -> Bool {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                hasher.withLock { $0.update(data: data) }
            } completionHandler: { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    public func featurePrint(of id: String) async -> FeaturePrint? {
        // 360 pt : la taille des vignettes que Photos garde sur le Mac, même
        // quand l'original est dans iCloud. Toutes les empreintes partent ainsi
        // d'images comparables.
        guard let thumbnail = await thumbnail(of: id, side: 360) else { return nil }
        let image = thumbnail.image
        return await VisionQueue.run {
            let request = VNGenerateImageFeaturePrintRequest()
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return nil
            }
            guard let observation = request.results?.first, observation.elementType == .float else { return nil }
            let vector = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return vector.count == observation.elementCount ? FeaturePrint(vector) : nil
        }
    }

    /// Cinq analyses Vision sur une vignette de 1 024 points : en dessous, le
    /// texte d'une page photographiée ne se lit plus (mesuré le 18/10/2026 : 0 à
    /// 47 caractères à 512 points, 87 à 1 916 à 1 024).
    public func signals(of id: String) async -> PhotoSignals? {
        guard let thumbnail = await thumbnail(of: id, side: 1024) else { return nil }
        let image = thumbnail.image
        return await VisionQueue.run { Self.signals(of: image) }
    }

    private static func signals(of image: CGImage) -> PhotoSignals? {
        let faces = VNDetectFaceRectanglesRequest()
        let barcodes = VNDetectBarcodesRequest()
        let classes = VNClassifyImageRequest()
        let outline = VNDetectDocumentSegmentationRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image).perform([faces, barcodes, classes, outline, text])
        } catch {
            return nil
        }
        var labels: [String: Float] = [:]
        for observation in classes.results ?? [] where observation.confidence >= 0.05 {
            labels[observation.identifier] = observation.confidence
        }
        let characters = (text.results ?? []).reduce(0) { $0 + ($1.topCandidates(1).first?.string.count ?? 0) }
        return PhotoSignals(faces: faces.results?.count ?? 0, barcodes: barcodes.results?.count ?? 0, labels: labels,
                            documentOutline: outline.results?.first?.confidence ?? 0, textCharacters: characters)
    }

    // MARK: Vignettes

    public func thumbnail(of id: String, side: Int) async -> PhotoThumbnail? {
        await image(of: id, side: side, allowNetwork: false, resize: .fast)?.thumbnail
    }

    public func image(of id: String, side: Int, allowNetwork: Bool) async -> PhotoImage? {
        await image(of: id, side: side, allowNetwork: allowNetwork, resize: .exact)
    }

    private func image(of id: String, side: Int, allowNetwork: Bool, resize: PHImageRequestOptionsResizeMode) async -> PhotoImage? {
        guard let asset = fetch(id) else { return nil }
        let options = PHImageRequestOptions()
        // Le réseau n'est ouvert que sur demande expresse, élément par élément.
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .opportunistic
        options.resizeMode = resize
        let target = CGSize(width: side, height: side)
        // En mode opportuniste, Photos rend d'abord une image dégradée, puis la
        // définitive. Sans réseau, la définitive manque quand l'original est dans
        // iCloud : on garde alors la dégradée, qui est locale, et on le dit.
        let degraded = Locked<PhotoThumbnail?>(nil)
        let answered = Locked(false)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                                  options: options) { image, info in
                let thumbnail = image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(PhotoThumbnail.init)
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded {
                    if let thumbnail { degraded.withLock { $0 = thumbnail } }
                    return
                }
                guard answered.claim() else { return }
                if let thumbnail {
                    continuation.resume(returning: PhotoImage(thumbnail, isReduced: false))
                } else {
                    continuation.resume(returning: degraded.withLock { $0 }.map { PhotoImage($0, isReduced: true) })
                }
            }
        }
    }

    public func video(of id: String, allowNetwork: Bool) async -> PhotoVideo? {
        guard let asset = fetch(id), asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item.map(PhotoVideo.init))
            }
        }
    }

    public func livePhoto(of id: String, side: Int, allowNetwork: Bool) async -> PhotoLive? {
        guard let asset = fetch(id), asset.mediaSubtypes.contains(.photoLive) else { return nil }
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .opportunistic
        let target = CGSize(width: side, height: side)
        let degraded = Locked<PHLivePhoto?>(nil)
        let answered = Locked(false)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestLivePhoto(for: asset, targetSize: target, contentMode: .aspectFit,
                                                      options: options) { live, info in
                let isDegraded = (info?[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                if isDegraded {
                    if let live { degraded.withLock { $0 = live } }
                    return
                }
                guard answered.claim() else { return }
                if let live {
                    continuation.resume(returning: PhotoLive(live, isReduced: false))
                } else {
                    continuation.resume(returning: degraded.withLock { $0 }.map { PhotoLive($0, isReduced: true) })
                }
            }
        }
    }

    public func albums(of id: String) async -> [String] {
        guard let asset = fetch(id) else { return [] }
        let result = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var names: [String] = []
        for index in 0..<result.count {
            if let title = result.object(at: index).localizedTitle { names.append(title) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func fetch(_ id: String) -> PHAsset? {
        guard access().canRead else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    // MARK: Changements

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            guard access().canRead else {
                continuation.finish()
                return
            }
            let observer = ChangeObserver { continuation.yield() }
            PHPhotoLibrary.shared().register(observer)
            continuation.onTermination = { _ in PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        }
    }
}

/// Une valeur partagée entre les rappels de PhotoKit, qui arrivent sur des
/// files quelconques, sous verrou.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

extension Locked where Value == Bool {
    /// Vrai au premier appel seulement : une continuation ne reprend qu'une fois.
    func claim() -> Bool {
        withLock { done in
            defer { done = true }
            return !done
        }
    }
}

/// Relaie les changements de la photothèque.
private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

/// Vision hors du pool coopératif de Swift. Appelé de façon synchrone dans des
/// tâches de ce pool, il y attend un travail interne, et plusieurs recherches à
/// la fois l'ont figé pour de bon (constaté le 18/10/2026 avec la recherche des
/// images similaires : tous les fils arrêtés dans
/// `VNControlledCapacityTasksQueue`). Photos et les images similaires tournant
/// ensemble auraient pu figer l'app.
enum VisionQueue {
    static let shared: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "fr.meaillais.oust.photos-vision"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            shared.addOperation { continuation.resume(returning: autoreleasepool { work() }) }
        }
    }
}
