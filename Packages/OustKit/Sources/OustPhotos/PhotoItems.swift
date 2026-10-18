import Foundation
import OustCore

/// D'où vient un élément de la photothèque montré dans Oust!.
public enum PhotoFinding: String, Sendable, Hashable, CaseIterable {
    case video, screenshot, duplicate, similar, utility

    public var category: ItemCategory {
        switch self {
        case .video: .photoVideos
        case .screenshot: .photoScreenshots
        case .duplicate: .photoDuplicates
        case .similar: .photoSimilar
        case .utility: .photoUtilities
        }
    }
}

extension PhotoEntry {
    /// Un identifiant par élément de la photothèque, quelle que soit la liste
    /// où il paraît : une vidéo qui est aussi un vieil enregistrement d'écran
    /// n'entre qu'une fois dans la corbeille, et n'est comptée qu'une fois.
    public static func itemID(_ assetID: String) -> String { "photo|\(assetID)" }

    public var itemID: String { Self.itemID(asset.id) }

    /// L'identifiant de la règle, qui porte l'explication (`rule.<id>.what`…).
    public func ruleID(for finding: PhotoFinding) -> String {
        switch finding {
        case .video: "photos.video"
        case .screenshot: asset.isScreenRecording ? "photos.screen_recording" : "photos.screenshot"
        case .duplicate: "photos.duplicate"
        case .similar: "photos.similar"
        case .utility: "photos.utility"
        }
    }

    /// L'élément de la corbeille d'Oust!.
    ///
    /// Toujours « À examiner » : une photo ne se régénère pas, et rien ici n'est
    /// coché d'office, pas même un doublon exact (RULES.md, règle 4). Sa taille
    /// libérable est ce qui est sur ce Mac, pas ce que compte iCloud.
    public func cleanupItem(for finding: PhotoFinding) -> CleanupItem {
        var detail = asset.created?.formatted(date: .abbreviated, time: .shortened)
        if asset.media == .video, asset.duration > 0 {
            let duration = Duration.seconds(asset.duration.rounded())
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
            detail = [detail, duration].compactMap { $0 }.joined(separator: " · ")
        }
        return CleanupItem(
            id: itemID,
            title: title,
            detail: detail,
            // Aucun chemin, à dessein : rien ne désigne un fichier du paquet
            // `.photoslibrary`, et la garde de chemins n'a rien à laisser passer.
            paths: [],
            category: finding.category,
            owner: "Photos",
            ruleID: ruleID(for: finding),
            safety: .review,
            protections: asset.facts.protections,
            notes: size.isMostlyInCloud ? [.photoInCloud] : [],
            method: .photoAsset(localIdentifier: asset.id),
            sizes: Sizes(allocated: size.total, freeable: size.local),
            lastActivity: asset.created,
            rebuild: .photosRecentlyDeleted,
            fingerprint: Fingerprint(modificationDate: asset.facts.editedAt, fileID: nil)
        )
    }
}
