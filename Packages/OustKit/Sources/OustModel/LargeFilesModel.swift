import Foundation
import Observation
import OustCore
import OustLargeFiles
import OustSafety
import OustScan

/// « Gros et vieux fichiers » : un filtre posé sur l'arborescence de l'Explorateur.
@MainActor
@Observable
public final class LargeFilesModel {
    weak var app: AppModel?

    /// Les seuils proposés : de quoi trier un disque de 1 To sans réglage fin.
    public enum SizePreset: Int64, CaseIterable, Identifiable, Sendable {
        case tenMegabytes = 10_000_000
        case hundredMegabytes = 100_000_000
        case halfGigabyte = 500_000_000
        case gigabyte = 1_000_000_000
        case fiveGigabytes = 5_000_000_000
        public var id: Int64 { rawValue }
    }

    public enum AgePreset: Int, CaseIterable, Identifiable, Sendable {
        case any = 0
        case threeMonths = 3
        case sixMonths = 6
        case oneYear = 12
        case twoYears = 24
        public var id: Int { rawValue }
        public var localizationKey: String { "largefiles.age.\(rawValue)" }
    }

    public var size: SizePreset = .hundredMegabytes { didSet { refresh() } }
    public var age: AgePreset = .sixMonths { didSet { refresh() } }
    /// Vide : toutes les familles.
    public var kinds: Set<FileKind> = [] { didSet { refresh() } }

    public private(set) var result: LargeFileResult?
    public private(set) var computing = false
    private var refreshTask: Task<Void, Never>?
    /// L'arborescence pour laquelle `result` a été calculé.
    private weak var computedFor: TreeNode?

    init() {}

    public var filter: LargeFileFilter {
        let since = age == .any ? nil : Calendar.current.date(byAdding: .month, value: -age.rawValue, to: Date())
        return LargeFileFilter(minimumSize: size.rawValue, unusedSince: since, kinds: kinds)
    }

    /// À appeler quand l'arborescence de l'Explorateur change.
    public func refreshIfNeeded() {
        if app?.tree !== computedFor || result == nil { refresh() }
    }

    public func revalidateGains() async {
        guard let app else { return }
        let treeIsCurrent = await app.revalidateExplorerGains()
        let spotlightIsCurrent = await app.disk.revalidateSpotlightGains()
        guard !Task.isCancelled else { return }
        if !treeIsCurrent || !spotlightIsCurrent || app.tree !== computedFor {
            result = nil
            refresh()
        }
    }

    func invalidateResult() {
        result = nil
    }

    public func refresh() {
        refreshTask?.cancel()
        computing = true
        refreshTask = Task {
            guard let app else { computing = false; return }
            let treeCheck = await app.revalidateExplorerGains()
            let previewCheck = await app.disk.revalidateSpotlightGains()
            guard !Task.isCancelled else { return }
            if !treeCheck || !previewCheck || app.tree !== computedFor { result = nil }
            let filter = filter
            guard let tree = app.tree else {
                let preview = app.disk.spotlightFiles
                result = previewCheck && !preview.isEmpty ? LargeFileFinder.preview(preview, filter: filter) : nil
                computedFor = nil
                computing = false
                return
            }
            computedFor = tree
            let found = await Task.detached(priority: .userInitiated) { LargeFileFinder.find(in: tree, filter: filter) }.value
            let stillCurrent = await app.revalidateExplorerGains()
            guard !Task.isCancelled else { return }
            guard stillCurrent, app.tree === tree else {
                result = nil
                refresh()
                return
            }
            result = found
            computing = false
        }
    }

    public func toggleKind(_ kind: FileKind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }

    /// Un gros fichier comme élément de la corbeille d'Oust!. Si une règle le
    /// connaît (sauvegarde iOS, image Docker), c'est son élément qui sert.
    public func item(for file: LargeFileMatch) -> CleanupItem {
        guard let app else { return file.cleanupItem(volume: "", guard: PathGuard()) }
        if let known = knownItems(app)[PathNormalizer.normalize(file.url.path)] { return known }
        let volume = app.treeVolume?.name ?? ""
        return app.canMoveFiles ? file.cleanupItem(volume: volume, guard: PathGuard(home: app.home))
            : file.cleanupItem(volume: volume, protected: true)
    }

    /// Les éléments des règles, par chemin. Recalculé seulement quand la liste
    /// change : chaque ligne affichée le consulte, et la liste en compte des
    /// centaines.
    @ObservationIgnored private var known: (count: Int, byPath: [String: CleanupItem]) = (-1, [:])

    private func knownItems(_ app: AppModel) -> [String: CleanupItem] {
        let items = app.items
        if known.count != items.count {
            var byPath: [String: CleanupItem] = [:]
            for item in items.values where item.paths.count == 1 {
                byPath[PathNormalizer.normalize(item.paths[0].path)] = item
            }
            known = (items.count, byPath)
        }
        return known.byPath
    }
}
