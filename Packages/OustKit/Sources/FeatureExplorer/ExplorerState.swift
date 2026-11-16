import Foundation
import Observation
import OustCore
import OustModel
import OustScan

/// L'état d'une arborescence affichée : onglet, tri, recherche, dossier ouvert,
/// statistiques et évolution depuis la dernière analyse.
@MainActor
@Observable
final class ExplorerState {

    enum Tab: String, CaseIterable, Identifiable {
        case tree, sunburst, types, ages, largest, growth
        var id: String { rawValue }
        var localizationKey: String { "explorer.tab.\(rawValue)" }
        var symbol: String {
            switch self {
            case .tree: "list.bullet.indent"
            case .sunburst: "sun.max"
            case .types: "chart.pie"
            case .ages: "calendar"
            case .largest: "arrow.up.right.square"
            case .growth: "chart.line.uptrend.xyaxis"
            }
        }
    }

    /// Ce que mesurent les barres et les pourcentages.
    enum Metric: String, CaseIterable {
        case size, files
    }

    let root: TreeNode
    let volumeName: String
    var focus: TreeNode
    var tab: Tab = .tree
    /// Le tri du tableau ; un clic sur un en-tête le change.
    var sortOrder: [KeyPathComparator<ExplorerRow>] = [KeyPathComparator(\ExplorerRow.size, order: .reverse)] {
        didSet { rebuildRows() }
    }
    var metric: Metric = .size {
        didSet { rebuildRows() }
    }
    var showFiles = true {
        didSet { rebuildRows() }
    }
    var selection = Set<ExplorerRow.ID>()
    /// Les lignes du dossier ouvert ; leurs enfants se construisent à l'ouverture.
    private(set) var rows: [ExplorerRow] = []
    var query = "" {
        didSet { scheduleSearch() }
    }
    private(set) var hits: [SearchHit] = []
    private(set) var searching = false

    private(set) var analytics: TreeAnalytics?
    private(set) var previous: TreeSummary?
    private(set) var changes: [TreeSummary.Change] = []

    private var searchTask: Task<Void, Never>?

    private let store: TreeSummaryStore

    /// Sans effet de bord : les calculs partent de `prepare()`, appelé une fois
    /// par arbre. Une vue qui crée l'état dans son `init` le recrée à chaque
    /// rendu de son parent.
    init(root: TreeNode, volumeName: String, store: TreeSummaryStore = .standard()) {
        self.root = root
        self.focus = root
        self.volumeName = volumeName
        self.store = store
        rebuildRows()
    }

    /// La base d'Évolution n'est remplacée qu'au bout de 12 heures. L'arbre
    /// partagé se rafraîchit à chaque lancement : la remplacer à chaque fois ne
    /// laissait à comparer que les secondes écoulées depuis l'arbre précédent.
    static let baselineLifetime: TimeInterval = 12 * 3600

    /// Statistiques et comparaison, hors du fil principal : sur un disque de
    /// cinq millions de fichiers, la traversée prend une à deux secondes.
    func prepare() async {
        let root = root
        let (analytics, summary) = await Task.detached(priority: .userInitiated) {
            (TreeAnalytics.compute(root), TreeSummary.make(from: root))
        }.value
        self.analytics = analytics
        let previous = store.load(rootPath: root.path)
        self.previous = previous
        self.changes = previous?.changes(comparedTo: summary) ?? []
        if previous.map({ summary.date.timeIntervalSince($0.date) >= Self.baselineLifetime }) ?? true {
            try? store.save(summary)
        }
        // Les colonnes Dossiers et Évolution attendaient ces deux calculs.
        rebuildRows()
    }

    // MARK: Navigation

    /// Du dossier racine au dossier ouvert, pour le fil d'Ariane.
    var trail: [TreeNode] {
        var nodes: [TreeNode] = []
        var current: TreeNode? = focus
        while let node = current {
            nodes.insert(node, at: 0)
            if node === root { break }
            current = node.parent
        }
        return nodes
    }

    func open(_ node: TreeNode) {
        focus = node
        query = ""
        selection.removeAll()
        rebuildRows()
    }

    func open(path: String) {
        if let node = root.node(at: path) { open(node) }
    }

    // MARK: Lignes du tableau

    func rebuildRows() {
        rows = makeRows(for: focus)
    }

    /// Les lignes d'un dossier, triées : sous-dossiers, gros fichiers, petits
    /// fichiers regroupés.
    func makeRows(for node: TreeNode) -> [ExplorerRow] {
        var result = node.children.map { ExplorerRow(folder: $0, state: self) }
        if showFiles {
            result += node.files.map { ExplorerRow(file: $0, in: node, state: self) }
        }
        result.sort(using: sortOrder)
        if showFiles, node.smallFileCount > 0 {
            result.append(ExplorerRow(smallFilesOf: node, state: self))
        }
        return result
    }

    /// La ligne correspondant à un identifiant, parmi celles déjà construites.
    func row(_ id: ExplorerRow.ID) -> ExplorerRow? {
        var stack = rows
        while let row = stack.popLast() {
            if row.id == id { return row }
            if let children = row.loadedChildren { stack.append(contentsOf: children) }
        }
        return nil
    }

    // MARK: Mesures

    func folders(in node: TreeNode) -> Int { analytics?.folders(in: node) ?? 0 }

    func delta(for node: TreeNode) -> Int64? { previous?.delta(for: node) }

    /// La part d'un nœud dans son parent, selon la mesure choisie.
    func fraction(of node: TreeNode) -> Double {
        guard let parent = node.parent else { return 1 }
        switch metric {
        case .size: return node.fractionOfParent
        case .files: return parent.fileCount > 0 ? Double(node.fileCount) / Double(parent.fileCount) : 0
        }
    }

    func fraction(of file: FileLeaf, in parent: TreeNode) -> Double {
        switch metric {
        case .size: return parent.total.allocated > 0 ? Double(file.sizes.allocated) / Double(parent.total.allocated) : 0
        case .files: return parent.fileCount > 0 ? 1 / Double(parent.fileCount) : 0
        }
    }

    // MARK: Recherche

    private func scheduleSearch() {
        searchTask?.cancel()
        let needle = query
        guard needle.trimmingCharacters(in: .whitespaces).count >= 2 else {
            hits = []
            searching = false
            return
        }
        searching = true
        let root = focus
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                TreeAnalytics.search(root, query: needle)
            }.value
            guard !Task.isCancelled else { return }
            self.hits = found
            self.searching = false
        }
    }

}
