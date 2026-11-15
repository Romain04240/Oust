import CoreGraphics
import Foundation
import Observation
import OustCore
import OustDuplicates

/// Les images similaires des dossiers ordinaires, dans la section Doublons :
/// les dossiers à parcourir, la recherche, et le passage vers la corbeille.
///
/// Rien n'est coché d'office, pas même la copie la plus faible d'un groupe
/// (RULES.md, règle 4) ; l'étoile ne fait que suggérer la meilleure. D'un
/// groupe, on ne peut jamais tout jeter (SPEC §7).
@MainActor
@Observable
public final class SimilarImagesModel {
    weak var app: AppModel?
    private let home: URL

    public private(set) var phase: AppModel.Phase = .idle
    public private(set) var progress = SimilarImageProgress()
    private var findings: SimilarImageFindings?
    /// Quand la recherche a fini : ce que l'Historique a vu partir depuis quitte les groupes.
    private var searchedAt: Date?

    /// L'onglet « Similaires » est celui qu'on regarde ; gardé ici pour qu'on le
    /// retrouve en revenant dans la section.
    public var isSelected = false

    /// Les dossiers parcourus : Images, Bureau, Téléchargements, Documents, et
    /// ceux qu'on ajoute. Gardés le temps de la session.
    public private(set) var folders: [URL]

    @ObservationIgnored private var thumbnails: [String: ImageThumbnail] = [:]

    init(home: URL) {
        self.home = home
        self.folders = SimilarImageOptions.standardFolders(home: home)
    }

    // MARK: Dossiers

    public var standardFolders: [URL] { SimilarImageOptions.standardFolders(home: home) }

    public func addFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        guard !folders.contains(where: { $0.standardizedFileURL == folder }) else { return }
        folders.append(folder)
    }

    public func removeFolder(_ url: URL) {
        folders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
    }

    // MARK: Recherche

    public func search() async {
        guard !phase.isRunning, !folders.isEmpty else { return }
        phase = .running
        let progress = SimilarImageProgress()
        self.progress = progress
        let options = SimilarImageOptions(roots: folders, excludedFolders: app?.preferences.projectRoots ?? [])
        let found = await SimilarImageFinder.find(options, progress: progress)
        guard !progress.isCancelled else {
            phase = findings == nil ? .idle : .done(searchedAt ?? Date())
            return
        }
        findings = found
        searchedAt = Date()
        thumbnails = [:]
        reconcileCart()
        phase = .done(Date())
    }

    public func cancel() {
        progress.cancel()
    }

    /// Une image jetée lors d'une recherche précédente et qui n'a plus de sœur
    /// sort de la corbeille : elle n'est plus « en trop ».
    private func reconcileCart() {
        guard let app else { return }
        let grouped = Set(groups.flatMap(\.images).map(\.url.path))
        app.remove(app.cart.filter { id in
            guard let item = app.items[id], item.category == .similarImages else { return false }
            return !item.paths.allSatisfy { grouped.contains($0.path) }
        }.map { $0 })
    }

    // MARK: Ce qui est montré

    /// Les groupes montrés : ceux qui rendraient quelque chose. Les groupes de
    /// clones APFS sont masqués (Romain, 18/10/2026 : « les masquer, oui ») ;
    /// leurs images partagent leur stockage avec d'autres fichiers, les jeter ne
    /// libérerait rien. Sur son Mac, c'était les 19 groupes trouvés.
    public var groups: [SimilarImageGroup] { remainingGroups.filter { $0.potential > 0 } }

    /// Combien de groupes de clones sont masqués : l'écran le dit.
    public var hiddenCloneGroups: Int { remainingGroups.count(where: { $0.potential == 0 }) }

    /// Les groupes, sans ce qui est parti depuis la recherche ; un groupe
    /// réduit à une image n'en est plus un.
    private var remainingGroups: [SimilarImageGroup] {
        let all = findings?.groups ?? []
        let gone = gonePaths
        guard !gone.isEmpty else { return all }
        return all.compactMap { group in
            let left = group.images.filter { !gone.contains($0.url.path) }
            return left.count > 1 ? SimilarImageGroup(images: left) : nil
        }
    }

    /// Ce que la mise à la Corbeille rendrait en gardant la meilleure image.
    public var potential: Int64 { groups.reduce(0) { $0 + reclaimableBytes(in: $1) } }

    public func reclaimableBytes(in group: SimilarImageGroup) -> Int64 {
        app?.canMoveFiles == true ? group.potential : 0
    }
    public var examined: Int { findings?.examined ?? 0 }
    public var skippedInCloud: Int { findings?.skippedInCloud ?? 0 }
    public var unreadable: Int { findings?.unreadable ?? 0 }

    private var gonePaths: Set<String> {
        guard let app, let searchedAt else { return [] }
        let outcomes = app.historyEntries.filter { $0.date >= searchedAt } + app.liveOutcomes
        return Set(outcomes.filter(\.result.succeeded).flatMap(\.paths))
    }

    // MARK: Corbeille

    /// Les chemins dans la corbeille, sous quelque élément que ce soit : une
    /// image déjà jetée depuis « Identiques » est cochée ici aussi, et n'est
    /// comptée qu'une fois (RULES.md, règle 9).
    public func cartPaths() -> Set<String> {
        guard let app else { return [] }
        return Set(app.cart.compactMap { app.items[$0] }.flatMap { $0.paths.map(\.path) })
    }

    public func isInCart(_ image: SimilarImage, paths: Set<String>? = nil) -> Bool {
        (paths ?? cartPaths()).contains(image.url.path)
    }

    public func item(for image: SimilarImage, in group: SimilarImageGroup) -> CleanupItem {
        var item = group.cleanupItem(for: image)
        if app?.canSelectForCleanup(item) != true {
            item.protect(.unknownState)
            item.sizes.freeable = 0
        }
        return item
    }

    /// Cocher une image n'est possible que s'il en reste au moins une autre du
    /// groupe à garder. Décocher l'est toujours.
    public func canToggle(_ image: SimilarImage, in group: SimilarImageGroup, paths: Set<String>? = nil) -> Bool {
        guard app != nil else { return false }
        let checked = paths ?? cartPaths()
        return group.canToggle(image, checked: checked)
            && (checked.contains(image.url.path) || item(for: image, in: group).isSelectable)
    }

    public func toggle(_ image: SimilarImage, in group: SimilarImageGroup) {
        guard let app else { return }
        let path = image.url.path
        let holding = app.cart.filter { app.items[$0]?.paths.contains { $0.path == path } == true }
        if !holding.isEmpty {
            app.remove(Array(holding))
        } else if canToggle(image, in: group) {
            app.toggle(item(for: image, in: group))
        }
    }

    public func canKeepBest(in group: SimilarImageGroup, paths: Set<String>? = nil) -> Bool {
        guard app?.canMoveFiles == true else { return false }
        let checked = paths ?? cartPaths()
        return group.images.dropFirst().contains { !checked.contains($0.url.path) }
    }

    public func keepBest(in group: SimilarImageGroup) {
        guard canKeepBest(in: group), let best = group.best else { return }
        if isInCart(best) { toggle(best, in: group) }
        for image in group.images.dropFirst() where !isInCart(image) {
            toggle(image, in: group)
        }
    }

    // MARK: Vignettes

    /// Une vignette pour l'écran, décodée hors du fil principal et gardée le
    /// temps de la recherche ; aucune n'est écrite sur le disque.
    public func thumbnail(for url: URL, side: Int) async -> CGImage? {
        let key = "\(side)|\(url.path)"
        if let cached = thumbnails[key] { return cached.image }
        let made = await Task.detached(priority: .userInitiated) {
            ImageReader.thumbnail(of: url, side: side).map(ImageThumbnail.init)
        }.value
        // Une centaine de groupes à l'écran au plus : au-delà, on repart de zéro
        // plutôt que de garder des centaines de mégaoctets d'images décodées.
        if thumbnails.count > 600 { thumbnails = [:] }
        if let made { thumbnails[key] = made }
        return made?.image
    }
}
