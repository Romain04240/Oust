import Foundation

/// Ce qu'on sait d'un élément de la photothèque quand il s'agit de décider
/// s'il peut être proposé.
///
/// L'analyse (OustPhotos) et la revalidation juste avant la suppression
/// (OustClean) lisent chacune PhotoKit de leur côté ; elles passent toutes deux
/// par ce type pour appliquer la même règle, au mot près.
public struct PhotoFacts: Sendable, Hashable, Codable {
    public var isFavorite: Bool
    public var isHidden: Bool
    /// Dans un album partagé ou dans la photothèque partagée d'iCloud.
    public var isShared: Bool
    /// Photos accepte de le supprimer (`canPerformEditOperation(.delete)`).
    public var canDelete: Bool
    /// La dernière retouche (`adjustmentTimestamp`), et non `modificationDate` :
    /// Photos change cette dernière à chaque analyse de visages ou de scènes, et
    /// toute photo aurait fini « modifiée depuis l'analyse ».
    public var editedAt: Date?

    public init(isFavorite: Bool = false, isHidden: Bool = false, isShared: Bool = false,
                canDelete: Bool = true, editedAt: Date? = nil) {
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.isShared = isShared
        self.canDelete = canDelete
        self.editedAt = editedAt
    }

    /// Pourquoi l'élément ne peut pas être proposé ; vide s'il peut l'être.
    public var protections: [ProtectionReason] {
        var reasons: [ProtectionReason] = []
        if isFavorite { reasons.append(.photoFavorite) }
        if isShared { reasons.append(.photoShared) }
        if isHidden { reasons.append(.photoHidden) }
        // Photos refuse sans dire pourquoi : dans le doute, on garde (RULES.md, règle 3).
        if !canDelete, reasons.isEmpty { reasons.append(.unknownState) }
        return reasons
    }
}
