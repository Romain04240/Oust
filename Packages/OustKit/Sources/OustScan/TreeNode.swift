import Foundation
import OustCore

/// Ce qu'on sait d'un dossier une fois parcouru.
public enum NodeStatus: Sendable, Hashable {
    case ok
    /// macOS en refuse la lecture (TCC ou permissions POSIX) ; `errno` conservé.
    case inaccessible(code: Int32)
    /// Point de montage : un autre système de fichiers, on ne le traverse pas.
    case otherVolume
    /// Firmlink vers une autre partie du disque, déjà comptée ailleurs.
    case firmlink
    /// Contenu iCloud non téléchargé : l'ouvrir déclencherait le téléchargement.
    case dataless
    /// Écarté par l'utilisateur ou par Oust! (liste d'exclusions).
    case excluded
}

/// Un fichier assez gros pour être montré seul dans l'arborescence.
public struct FileLeaf: Sendable, Hashable, Identifiable {
    public var id: UInt64 { fileID }
    public let name: String
    public let sizes: Sizes
    public let modified: Date?
    /// Le dernier accès selon le système de fichiers. APFS ne le met à jour que
    /// paresseusement (et pas du tout pendant l'analyse d'Oust!, qui le coupe) :
    /// un indice, pas une preuve.
    public let accessed: Date?
    public let fileID: UInt64
    public let isClone: Bool
    /// La taille logique (`st_size`) : les doublons se groupent sur elle.
    public let logicalSize: Int64
    /// L'identifiant de contenu APFS : deux clones complets le partagent.
    public let cloneID: UInt64

    init(name: String, sizes: Sizes, modified: Date?, accessed: Date?, fileID: UInt64, isClone: Bool,
         logicalSize: Int64 = 0, cloneID: UInt64 = 0) {
        self.name = name
        self.sizes = sizes
        self.modified = modified
        self.accessed = accessed
        self.fileID = fileID
        self.isClone = isClone
        self.logicalSize = logicalSize
        self.cloneID = cloneID
    }
}

/// Un dossier de l'arborescence, à la manière de TreeSize.
///
/// Seuls les dossiers et les fichiers d'au moins `leafThreshold` sont des nœuds
/// à part entière ; les petits fichiers d'un dossier sont regroupés. Sur un
/// disque de 1 To, garder un nœud par fichier coûterait des gigaoctets de
/// mémoire pour montrer des lignes que personne ne lit.
///
/// Concurrence : chaque nœud n'est écrit que par le thread qui parcourt son
/// dossier, puis relu après la fin du parcours. Les enfants sont attachés avant
/// d'être confiés à la file, et la file sert de barrière (verrou) : d'où le
/// `@unchecked Sendable`, justifié ici plutôt que masqué. Une arborescence
/// publiée ne change plus : la réanalyse incrémentale travaille sur une copie
/// (`clone()`), parce que l'Explorateur la lit depuis d'autres tâches.
public final class TreeNode: @unchecked Sendable, Identifiable {
    public let name: String
    public internal(set) weak var parent: TreeNode?
    public let fileID: UInt64
    /// Renseigné quand le dossier est une racine de mesure fraîche.
    var measurementDevice: Int32?
    public internal(set) var status: NodeStatus = .ok

    public internal(set) var children: [TreeNode] = []
    public internal(set) var files: [FileLeaf] = []
    /// Les fichiers trop petits pour être montrés un à un.
    public internal(set) var smallFiles = Sizes.zero
    public internal(set) var smallFileCount = 0
    /// Tous les fichiers directement dans ce dossier.
    public internal(set) var ownFiles = Sizes.zero
    public internal(set) var ownFileCount = 0
    /// Le dossier lui-même et ses fichiers directs : ce qu'une réanalyse
    /// partielle doit pouvoir recombiner sans relire les sous-dossiers.
    var ownLatestModification: Date?
    /// Ses totaux sont à refaire (il a été relu, ou un de ses descendants).
    var needsTotals = false
    /// Les petits fichiers dont le nom intéresse une règle (`ScanOptions.notableNames`).
    public internal(set) var notableFiles: [String] = []

    /// Calculés après le parcours, enfants compris.
    public internal(set) var latestModification: Date?
    public internal(set) var total = Sizes.zero
    public internal(set) var fileCount = 0
    public internal(set) var inaccessibleCount = 0

    /// Le chemin complet n'est gardé qu'à la racine : les autres le recomposent.
    let rootPath: String?

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, parent: TreeNode?, fileID: UInt64, rootPath: String? = nil) {
        self.name = name
        self.parent = parent
        self.fileID = fileID
        self.rootPath = rootPath
    }

    public var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// Part de ce nœud dans son parent, de 0 à 1.
    public var fractionOfParent: Double {
        guard let parent, parent.total.allocated > 0 else { return 1 }
        return Double(total.allocated) / Double(parent.total.allocated)
    }

    /// Cherche un descendant par chemin (relatif ou absolu).
    public func node(at path: String) -> TreeNode? {
        let base = self.path
        guard path.hasPrefix(base) else { return nil }
        let relative = path.dropFirst(base.count).split(separator: "/")
        var current = self
        for component in relative {
            guard let next = current.child(named: component) else { return nil }
            current = next
        }
        return current
    }

    /// Le sous-dossier de ce nom, s'il a été vu.
    public func child(named name: some StringProtocol) -> TreeNode? {
        children.first { $0.name == name }
    }

    /// Additionne les enfants, du bas vers le haut, puis trie par taille.
    func finalize() {
        // Parcours itératif en post-ordre : l'arborescence d'un disque peut être
        // profonde, et la pile d'un thread secondaire n'est pas extensible.
        var stack: [(TreeNode, Bool)] = [(self, false)]
        while let (node, visited) = stack.popLast() {
            if visited {
                node.recomputeTotals()
                node.files.sort { $0.sizes.allocated > $1.sizes.allocated }
            } else {
                stack.append((node, true))
                for child in node.children { stack.append((child, false)) }
            }
        }
    }

    /// Les totaux de ce seul nœud, d'après ses fichiers et les totaux (déjà
    /// justes) de ses enfants.
    func recomputeTotals() {
        var total = ownFiles
        var count = ownFileCount
        var inaccessible = status.isInaccessible ? 1 : 0
        var latest = ownLatestModification
        for child in children {
            total += child.total
            count += child.fileCount
            inaccessible += child.inaccessibleCount
            if let date = child.latestModification, date > (latest ?? .distantPast) { latest = date }
        }
        self.total = total
        fileCount = count
        inaccessibleCount = inaccessible
        latestModification = latest
        children.sort { $0.total.allocated > $1.total.allocated }
    }

    /// Une copie profonde des dossiers. Les feuilles sont des valeurs : leurs
    /// tableaux ne sont recopiés qu'au moment d'être modifiés.
    func clone() -> TreeNode {
        let root = TreeNode(name: name, parent: nil, fileID: fileID, rootPath: rootPath ?? path)
        var stack: [(source: TreeNode, copy: TreeNode)] = [(self, root)]
        while let (source, copy) = stack.popLast() {
            copy.status = source.status
            copy.files = source.files
            copy.smallFiles = source.smallFiles
            copy.smallFileCount = source.smallFileCount
            copy.ownFiles = source.ownFiles
            copy.ownFileCount = source.ownFileCount
            copy.ownLatestModification = source.ownLatestModification
            copy.notableFiles = source.notableFiles
            copy.latestModification = source.latestModification
            copy.total = source.total
            copy.fileCount = source.fileCount
            copy.inaccessibleCount = source.inaccessibleCount
            copy.children.reserveCapacity(source.children.count)
            for child in source.children {
                let childCopy = TreeNode(name: child.name, parent: copy, fileID: child.fileID)
                copy.children.append(childCopy)
                stack.append((child, childCopy))
            }
        }
        return root
    }

    /// Les nœuds refusés par macOS, pour les montrer au lieu de les taire.
    public func inaccessiblePaths(limit: Int = 500) -> [String] {
        var found: [String] = []
        var stack: [TreeNode] = [self]
        while let node = stack.popLast(), found.count < limit {
            if node.status.isInaccessible { found.append(node.path) }
            stack.append(contentsOf: node.children)
        }
        return found
    }
}

extension NodeStatus {
    public var isInaccessible: Bool {
        if case .inaccessible = self { return true }
        return false
    }
}

// MARK: - Interroger l'arborescence

extension TreeNode {
    /// Le chemin relatif à cette racine, quel que soit le nom sous lequel on le
    /// donne.
    ///
    /// Le volume de données se parcourt depuis `/System/Volumes/Data`, mais les
    /// règles parlent de `/Users/…` (firmlink) et FSEvents de `/private/var/…`
    /// quand le dossier a été ouvert par `/var/…` (lien symbolique). Sans cette
    /// traduction, une règle ne retrouverait jamais son dossier dans l'arbre, et
    /// un changement signalé ne serait jamais relu.
    func relativeComponents(of path: String) -> [Substring]? {
        let base = Self.physical(self.path)
        let target = Self.physical(path)
        if target == base { return [] }
        let prefix = base == "/" ? "/" : base + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return target.dropFirst(prefix.count).split(separator: "/")
    }

    /// Un seul nom par dossier du volume de données : sans le préfixe
    /// `/System/Volumes/Data`, avec le `/private` que cachent `/var`, `/tmp` et
    /// `/etc`.
    static func physical(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/System/Volumes/Data" { return "/" }
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    /// Le dossier de cette arborescence qui correspond à un chemin, sous l'un ou
    /// l'autre de ses noms.
    public func descendant(atPath path: String) -> TreeNode? {
        guard let components = relativeComponents(of: path) else { return nil }
        var current = self
        for component in components {
            guard let next = current.child(named: component) else { return nil }
            current = next
        }
        return current
    }

    /// Ce que l'arborescence sait d'un élément, sans relire le disque.
    ///
    /// `nil` quand elle ne le sait pas : dossier hors de l'arbre ou non parcouru
    /// (autre volume, exclu), fichier trop petit pour être une feuille. On
    /// mesure alors le disque, plutôt que d'annoncer zéro.
    public func measurement(of url: URL) -> Measurement? {
        let path = url.standardizedFileURL.path
        if let node = descendant(atPath: path) {
            guard node.status == .ok || node.status.isInaccessible else { return nil }
            return Measurement(sizes: node.total, fileCount: node.fileCount,
                               latestModification: node.latestModification,
                               inaccessible: node.status.isInaccessible)
        }
        let parentPath = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let parent = descendant(atPath: parentPath), parent.status == .ok,
              let leaf = parent.files.first(where: { $0.name == name }) else { return nil }
        return Measurement(sizes: leaf.sizes, fileCount: 1, latestModification: leaf.modified, inaccessible: false)
    }
}
