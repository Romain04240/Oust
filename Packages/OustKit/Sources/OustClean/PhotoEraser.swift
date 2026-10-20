import Foundation
import OustCore
import Photos

/// Ce que Photos répond à une demande de suppression.
public enum PhotoErasure: Sendable, Hashable {
    case deleted
    /// Refusée dans l'invite de macOS : rien n'est parti.
    case declined
    case failed(message: String)
}

/// Supprime des éléments de la photothèque, et relit leur état juste avant.
///
/// Le seul endroit d'Oust! qui demande à Photos de supprimer (RULES.md,
/// règle 1). Le paquet `.photoslibrary` n'est jamais touché : PhotoKit seul y
/// écrit, et l'élément passe 30 jours dans « Supprimés récemment ».
public protocol PhotoEraser: Sendable {
    /// L'état actuel de chaque élément ; un identifiant absent n'existe plus.
    /// `nil` : la photothèque ne se lit plus (accès retiré entre-temps).
    func facts(of ids: [String]) async -> [String: PhotoFacts]?
    /// Une seule demande pour tous : macOS fait confirmer une seule fois.
    func delete(_ ids: [String]) async -> PhotoErasure
}

/// Par PhotoKit.
public struct SystemPhotoEraser: PhotoEraser {
    public init() {}

    public func facts(of ids: [String]) async -> [String: PhotoFacts]? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        guard !ids.isEmpty else { return [:] }
        // Les éléments masqués depuis l'analyse sont relus aussi : c'est ce qui
        // permet de les voir devenus protégés.
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var facts: [String: PhotoFacts] = [:]
        for index in 0..<result.count {
            let asset = result.object(at: index)
            facts[asset.localIdentifier] = Self.facts(of: asset)
        }
        return facts
    }

    /// Les mêmes propriétés que l'analyse (`SystemPhotoLibrary.facts` dans
    /// OustPhotos) : toute retouche ici se reporte là-bas.
    static func facts(of asset: PHAsset) -> PhotoFacts {
        var shared = asset.sourceType != .typeUserLibrary
        // La photothèque partagée d'iCloud, sans API publique : voir OustPhotos.
        if !shared, asset.responds(to: NSSelectorFromString("participatesInLibraryScope")) {
            shared = (asset.value(forKey: "participatesInLibraryScope") as? Bool) ?? false
        }
        return PhotoFacts(isFavorite: asset.isFavorite, isHidden: asset.isHidden, isShared: shared,
                          canDelete: asset.canPerform(.delete), editedAt: asset.adjustmentTimestamp)
    }

    public func delete(_ ids: [String]) async -> PhotoErasure {
        guard !ids.isEmpty else { return .deleted }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
            }
            return .deleted
        } catch {
            let error = error as NSError
            // « Ne pas autoriser » dans l'invite : PHPhotosErrorUserCancelled, ou
            // NSUserCancelledError selon les versions — même code, 3072.
            if error.code == PHPhotosError.userCancelled.rawValue || error.code == NSUserCancelledError {
                return .declined
            }
            return .failed(message: error.localizedDescription)
        }
    }
}

extension CleanupEngine {
    /// Toutes les photos de la corbeille d'un coup : une seule invite de macOS.
    ///
    /// Chacune est revalidée juste avant (RULES.md, règle 2) : elle existe
    /// encore, n'est devenue ni favorite, ni partagée, ni masquée, et n'a pas
    /// été retouchée depuis l'analyse. Après la suppression, on relit : seule
    /// une photo qui a vraiment disparu est notée supprimée.
    func erasePhotos(_ items: [CleanupItem], session: UUID, isCancelled: () -> Bool,
                     progress: (CleanupPhase) -> Void = { _ in }) async -> [CleanupOutcome] {
        func outcome(_ item: CleanupItem, _ result: OutcomeResult) -> CleanupOutcome {
            CleanupOutcome(sessionID: session, date: Date(), item: item, result: result,
                           bytes: result.succeeded ? item.sizes.freeable : 0)
        }
        let ids = items.compactMap(\.method.photoAssetID)
        progress(.revalidating)
        guard let current = await photos.facts(of: ids) else {
            return items.map { outcome($0, .skipped(.nowProtected(.unknownState))) }
        }
        var outcomes: [String: CleanupOutcome] = [:]
        var cleared: [(item: CleanupItem, id: String)] = []
        for item in items {
            guard let id = item.method.photoAssetID, let facts = current[id] else {
                outcomes[item.id] = outcome(item, .skipped(.vanished))
                continue
            }
            if let reason = facts.protections.first {
                outcomes[item.id] = outcome(item, .skipped(.nowProtected(reason)))
            } else if Self.editedSinceScan(facts.editedAt, scanned: item.fingerprint?.modificationDate) {
                outcomes[item.id] = outcome(item, .skipped(.changedSinceScan))
            } else {
                cleared.append((item, id))
            }
        }
        if !cleared.isEmpty {
            if isCancelled() {
                for one in cleared { outcomes[one.item.id] = outcome(one.item, .skipped(.cancelled)) }
            } else {
                progress(.deleting)
                switch await photos.delete(cleared.map(\.id)) {
                case .deleted:
                    let remaining = await photos.facts(of: cleared.map(\.id)) ?? [:]
                    for one in cleared {
                        outcomes[one.item.id] = remaining[one.id] == nil
                            ? outcome(one.item, .recentlyDeleted) : outcome(one.item, .failed(message: "Photos"))
                    }
                case .declined:
                    for one in cleared { outcomes[one.item.id] = outcome(one.item, .skipped(.cancelled)) }
                case .failed(let message):
                    for one in cleared { outcomes[one.item.id] = outcome(one.item, .failed(message: message)) }
                }
            }
        }
        return items.compactMap { outcomes[$0.id] }
    }

    /// Retouchée (ou ramenée à l'original) depuis l'analyse : ce n'est plus la
    /// photo qu'on a montrée.
    static func editedSinceScan(_ current: Date?, scanned: Date?) -> Bool {
        switch (current, scanned) {
        case (nil, nil): false
        case let (now?, then?): abs(now.timeIntervalSince(then)) > 1
        default: true
        }
    }
}
