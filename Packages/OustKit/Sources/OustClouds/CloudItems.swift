import Foundation
import OustCore
import OustSafety

extension CloudEntry {
    /// Comme élément de la corbeille d'Oust! : du contenu personnel, à
    /// examiner, jamais coché d'office (RULES.md, règle 4). Il part dans la
    /// corbeille du Mac par le Finder, et le service le supprime alors aussi dans
    /// le nuage et sur les autres appareils.
    ///
    /// La taille annoncée est ce qui revient sur ce Mac : rien pour un fichier
    /// resté en ligne (règle 9). Ce qu'il pèse dans le nuage se lit dans la
    /// section, à part.
    public func cleanupItem(account: CloudAccount?, guard pathGuard: PathGuard) -> CleanupItem {
        var item = CleanupItem(
            id: "cloudfile|\(url.path)", title: name, detail: place(account: account),
            paths: [url], category: .cloudItems, owner: account.map(\.displayName) ?? "", ruleID: "clouds.file",
            safety: .review, notes: isDataless ? [.cloudOnly] : [], method: .trashFromCloud,
            sizes: Sizes(allocated: localSize, freeable: freeable), lastActivity: modified, rebuild: .cloudTrash,
            fingerprint: Fingerprint(modificationDate: modified, fileID: fileID)
        )
        if !pathGuard.allowsCloudTrash(url) { item.protect(.systemPath) }
        // Listé, mais rien à cocher : le Finder refuserait, après une alerte qui
        // bloque le nettoyage (essai du 18/10/2026 ; Romain : carte « déconnecté »).
        switch account?.connection {
        case .appClosed: item.protect(.cloudAppClosed(name: account?.service.displayName ?? ""))
        case .disconnected: item.protect(.cloudDisconnected)
        case .connected, nil: break
        }
        return item
    }

    /// « Google Drive › Mon Drive › Factures » : où le trouver dans le nuage.
    public func place(account: CloudAccount?) -> String {
        ([account?.service.displayName].compactMap { $0 } + folder).joined(separator: " › ")
    }
}

extension CloudAccount {
    /// « Google Drive · romain@exemple.fr », « iCloud Drive ».
    public var displayName: String {
        account.map { "\(service.displayName) · \($0)" } ?? service.displayName
    }
}
