import Foundation
import OustCore
import OustScan

/// Une ligne du tableau façon TreeSize : un dossier, un gros fichier, ou les
/// petits fichiers d'un dossier regroupés.
///
/// Les valeurs triables sont calculées une fois, à la création : `Table` les
/// relit à chaque tri et à chaque défilement. Les enfants ne sont construits
/// qu'au moment où l'on déplie la ligne — sur un disque de 800 000 dossiers,
/// tout construire d'avance coûterait des secondes pour rien.
///
/// Les valeurs triables sont des constantes, lisibles de partout : le tri de
/// `Table` exige des chemins de clés `Sendable`, ce qu'une classe isolée sur le
/// fil principal ne permet pas. Seuls la construction et le dépliage, qui
/// touchent l'état de l'Explorateur, restent sur le fil principal.
final class ExplorerRow: Identifiable, @unchecked Sendable {
    enum Kind {
        case folder(TreeNode)
        case file(FileLeaf, TreeNode)
        case smallFiles(TreeNode)
    }

    let id: String
    let kind: Kind
    let name: String
    let size: Int64
    let files: Int
    let folders: Int
    let modified: Date
    let growth: Int64
    let share: Double
    private weak var state: ExplorerState?
    private(set) var loadedChildren: [ExplorerRow]?

    @MainActor
    init(folder node: TreeNode, state: ExplorerState) {
        id = "d:" + node.path
        kind = .folder(node)
        name = node.name
        size = node.total.allocated
        files = node.fileCount
        folders = state.folders(in: node)
        modified = node.latestModification ?? .distantPast
        growth = state.delta(for: node) ?? 0
        share = state.fraction(of: node)
        self.state = state
    }

    @MainActor
    init(file: FileLeaf, in parent: TreeNode, state: ExplorerState) {
        id = "f:" + parent.path + "/" + file.name
        kind = .file(file, parent)
        name = file.name
        size = file.sizes.allocated
        files = 1
        folders = 0
        modified = file.modified ?? .distantPast
        growth = 0
        share = state.fraction(of: file, in: parent)
        self.state = state
    }

    @MainActor
    init(smallFilesOf node: TreeNode, state: ExplorerState) {
        id = "s:" + node.path
        kind = .smallFiles(node)
        name = ""
        size = node.smallFiles.allocated
        files = node.smallFileCount
        folders = 0
        modified = .distantPast
        growth = 0
        share = node.total.allocated > 0 ? Double(node.smallFiles.allocated) / Double(node.total.allocated) : 0
        self.state = state
    }

    /// Les enfants, pour le dépliage ; `nil` pour ce qui ne se déplie pas.
    ///
    /// `Table` ne lit ce chemin de clé que depuis le fil principal, où vit
    /// l'état de l'Explorateur : `assumeIsolated` le vérifie au lieu de le
    /// supposer en silence.
    var children: [ExplorerRow]? {
        guard case .folder(let node) = kind, node.status == .ok,
              !(node.children.isEmpty && node.files.isEmpty && node.smallFileCount == 0) else { return nil }
        if let loadedChildren { return loadedChildren }
        let made = MainActor.assumeIsolated { state?.makeRows(for: node) ?? [] }
        loadedChildren = made
        return made
    }

    var node: TreeNode? {
        if case .folder(let node) = kind { return node }
        return nil
    }

    /// Le chemin complet, pour révéler et copier.
    var path: String {
        switch kind {
        case .folder(let node): node.path
        case .file(let file, let parent): parent.path + "/" + file.name
        case .smallFiles(let node): node.path
        }
    }
}
