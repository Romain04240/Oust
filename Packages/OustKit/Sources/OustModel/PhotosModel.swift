import Foundation
import Observation
import OustCore
import OustPhotos

/// La section Photos : la photothèque lue par PhotoKit, ce qu'on y trouve, et
/// le passage vers la corbeille d'Oust!.
///
/// Rien n'est coché d'office, pas même un doublon exact (RULES.md, règle 4),
/// et d'un groupe de doublons on ne peut jamais tout jeter (SPEC §7).
@MainActor
@Observable
public final class PhotosModel {
    weak var app: AppModel?
    let library: any PhotoLibrary

    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case videos, screenshots, duplicates, similar, utilities
        public var id: String { rawValue }
        public var localizationKey: String { "photos.tab.\(rawValue)" }
        public var finding: PhotoFinding {
            switch self {
            case .videos: .video
            case .screenshots: .screenshot
            case .duplicates: .duplicate
            case .similar: .similar
            case .utilities: .utility
            }
        }
    }

    /// Jusqu'où remonter pour les similaires et les photos utiles : chaque photo
    /// lue coûte une analyse Vision.
    public enum Period: Int, CaseIterable, Identifiable, Sendable {
        case threeMonths = 3
        case oneYear = 12
        case all = 0
        public var id: Int { rawValue }
        public var localizationKey: String { "photos.period.\(rawValue)" }
        func since(_ now: Date) -> Date? {
            rawValue == 0 ? nil : Calendar.current.date(byAdding: .month, value: -rawValue, to: now)
        }
    }

    public private(set) var access: PhotoAccess
    public private(set) var phase: AppModel.Phase = .idle
    public private(set) var progress = PhotoProgress()
    private var findings: PhotoFindings?
    public var tab: Tab = .videos

    public private(set) var similarPhase: AppModel.Phase = .idle
    public private(set) var similarProgress = PhotoProgress()
    private var similarGroups: [PhotoGroup] = []
    public var similarPeriod: Period = .oneYear

    public private(set) var utilityPhase: AppModel.Phase = .idle
    public private(set) var utilityProgress = PhotoProgress()
    private var utilityMatches: [PhotoUtilityMatch] = []
    public var utilityPeriod: Period = .oneYear

    /// Ce qui a quitté la photothèque depuis l'analyse : supprimé par Oust!, ou
    /// dans Photos pendant qu'Oust! était ouvert.
    private var gone: Set<String> = []
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var thumbnails: [String: PhotoThumbnail] = [:]

    init(library: any PhotoLibrary = SystemPhotoLibrary()) {
        self.library = library
        self.access = library.access()
    }

    // MARK: Autorisation

    /// Relue à chaque passage dans la section : l'utilisateur a pu l'accorder
    /// ou la retirer dans Réglages Système entre-temps.
    public func refreshAccess() {
        access = library.access()
    }

    public func requestAccess() async {
        access = await library.requestAccess()
        if access.canRead { await analyze() }
    }

    // MARK: Analyse

    public func analyze() async {
        refreshAccess()
        guard access.canRead, !phase.isRunning else { return }
        phase = .running
        let progress = PhotoProgress()
        self.progress = progress
        let found = await PhotoAnalyzer.analyze(library, options: PhotoOptions(), progress: progress)
        guard !progress.isCancelled else {
            phase = findings == nil ? .idle : .done(Date())
            return
        }
        findings = found
        gone = []
        similarGroups = []
        similarPhase = .idle
        utilityMatches = []
        utilityPhase = .idle
        reconcileCart(with: found)
        // S'ouvrir sur une liste qui a quelque chose à montrer.
        if count(tab) == 0, let first = [Tab.videos, .screenshots, .duplicates].first(where: { count($0) > 0 }) {
            tab = first
        }
        phase = .done(Date())
        watchChanges()
    }

    /// Ce qui a quitté la photothèque, ou est devenu protégé (mis en favori,
    /// masqué) depuis qu'on l'a jeté, sort de la corbeille. La revalidation
    /// l'aurait de toute façon laissé, mais la corbeille ne doit pas promettre
    /// ce qui ne partira pas.
    private func reconcileCart(with found: PhotoFindings) {
        guard let app else { return }
        let prefix = PhotoEntry.itemID("")
        let valid = Set(found.assets.filter { $0.facts.protections.isEmpty }.map { PhotoEntry.itemID($0.id) })
        app.remove(app.cart.filter { $0.hasPrefix(prefix) && !valid.contains($0) })
    }

    /// Les photos similaires, sur demande : il faut une empreinte Vision par
    /// photo prise en série.
    public func findSimilar() async {
        guard let findings, !similarPhase.isRunning else { return }
        similarPhase = .running
        let progress = PhotoProgress()
        similarProgress = progress
        let excluded = Set(findings.duplicates.flatMap(\.entries).map(\.id))
        let options = SimilarOptions(since: similarPeriod.since(Date()))
        let groups = await PhotoAnalyzer.similar(library, among: findings.assets, excluding: excluded,
                                                 options: options, progress: progress)
        guard !progress.isCancelled else {
            similarPhase = .idle
            return
        }
        similarGroups = groups
        similarPhase = .done(Date())
    }

    /// Les photos prises pour garder une information, sur demande : Vision
    /// regarde chaque photo de la période. Les photos avec un visage sont écartées.
    public func findUtilities() async {
        guard let findings, !utilityPhase.isRunning else { return }
        utilityPhase = .running
        let progress = PhotoProgress()
        utilityProgress = progress
        let matches = await PhotoAnalyzer.utilities(library, among: findings.assets,
                                                    since: utilityPeriod.since(Date()), progress: progress)
        guard !progress.isCancelled else {
            utilityPhase = .idle
            return
        }
        utilityMatches = matches
        utilityPhase = .done(Date())
    }

    public func cancel() {
        progress.cancel()
        similarProgress.cancel()
        utilityProgress.cancel()
    }

    // MARK: Ce qui est montré

    public var videos: [PhotoEntry] { (findings?.videos ?? []).filter { !gone.contains($0.id) } }
    public var screenshots: [PhotoEntry] { (findings?.screenshots ?? []).filter { !gone.contains($0.id) } }
    public var duplicates: [PhotoGroup] { remaining(findings?.duplicates ?? []) }
    public var similar: [PhotoGroup] { remaining(similarGroups) }
    public var unverifiableDuplicates: Int { findings?.unverifiable ?? 0 }

    /// Les photos utiles d'une famille, dans l'ordre de l'écran.
    public func utilities(_ kind: PhotoUtilityKind) -> [PhotoEntry] {
        utilityMatches.filter { $0.kind == kind && !gone.contains($0.id) }.map(\.entry)
    }

    /// Toutes les photos utiles, famille par famille.
    public var utilities: [PhotoEntry] { PhotoUtilityKind.allCases.flatMap(utilities) }

    private func remaining(_ groups: [PhotoGroup]) -> [PhotoGroup] {
        groups.compactMap { group in
            let entries = group.entries.filter { !gone.contains($0.id) }
            return entries.count > 1 ? PhotoGroup(entries: entries) : nil
        }
    }

    /// Combien d'éléments dans un onglet (groupes pour les doublons et les similaires).
    public func count(_ tab: Tab) -> Int {
        switch tab {
        case .videos: videos.count
        case .screenshots: screenshots.count
        case .duplicates: duplicates.count
        case .similar: similar.count
        case .utilities: utilities.count
        }
    }

    /// Ce qu'un onglet rendrait au plus sur ce Mac. Pour un groupe, tout sauf
    /// un exemplaire ; une photo évincée par Photos iCloud ne compte presque pas,
    /// un favori pas du tout.
    public func reclaimable(_ tab: Tab) -> Int64 {
        switch tab {
        case .videos: videos.filter(\.isFreeable).reduce(0) { $0 + $1.size.local }
        case .screenshots: screenshots.filter(\.isFreeable).reduce(0) { $0 + $1.size.local }
        case .duplicates: duplicates.reduce(0) { $0 + $1.potential }
        case .similar: similar.reduce(0) { $0 + $1.potential }
        case .utilities: utilities.filter(\.isFreeable).reduce(0) { $0 + $1.size.local }
        }
    }

    /// Le total de la section : chaque élément une fois, même s'il paraît dans
    /// deux listes (une vidéo qui est aussi un vieil enregistrement d'écran).
    public var reclaimableTotal: Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for entry in videos + screenshots + utilities where entry.isFreeable && seen.insert(entry.id).inserted {
            total += entry.size.local
        }
        // D'un groupe, on garde l'exemplaire protégé s'il y en a un, sinon le plus lourd.
        for group in duplicates + similar {
            let free = group.entries.filter(\.isFreeable)
            let kept = free.count == group.entries.count ? free.max { $0.size.local < $1.size.local }?.id : nil
            for entry in free where entry.id != kept && seen.insert(entry.id).inserted {
                total += entry.size.local
            }
        }
        return total
    }

    /// La part de ce qui est montré qui n'est que dans iCloud (« Optimiser le
    /// stockage du Mac ») : la supprimer libère iCloud, pas ce Mac.
    public var cloudOnlyTotal: Int64 {
        var seen = Set<String>()
        let all = videos + screenshots + utilities + duplicates.flatMap(\.entries) + similar.flatMap(\.entries)
        return all.filter { seen.insert($0.id).inserted }.reduce(0) { $0 + $1.size.inCloudOnly }
    }

    /// Une taille ou une présence a manqué pour au moins un élément montré.
    public var hasIncompleteSizes: Bool {
        (videos + screenshots + utilities + duplicates.flatMap(\.entries) + similar.flatMap(\.entries))
            .contains { !$0.size.isComplete }
    }

    // MARK: Corbeille

    /// L'élément de la corbeille : celui qui y est déjà, s'il y est.
    public func item(for entry: PhotoEntry, in tab: Tab) -> CleanupItem {
        app?.items[entry.itemID] ?? entry.cleanupItem(for: tab.finding)
    }

    public func isInCart(_ entry: PhotoEntry) -> Bool {
        app?.isInCart(entry.itemID) ?? false
    }

    public func toggle(_ entry: PhotoEntry, in tab: Tab) {
        app?.toggle(item(for: entry, in: tab))
    }

    /// Dans un groupe de doublons, le dernier exemplaire ne peut pas partir :
    /// un favori ou un élément protégé compte comme gardé.
    public func canToggle(_ entry: PhotoEntry, in group: PhotoGroup, tab: Tab) -> Bool {
        guard item(for: entry, in: tab).isSelectable else { return false }
        guard tab == .duplicates, !isInCart(entry) else { return true }
        return group.entries.count(where: isInCart) < group.entries.count - 1
    }

    /// Cocher ou décocher toute une liste, à la demande de l'utilisateur.
    public func toggleAll(_ entries: [PhotoEntry], in tab: Tab) {
        guard let app else { return }
        let items = entries.map { item(for: $0, in: tab) }.filter(\.isSelectable)
        if items.allSatisfy({ app.isInCart($0.id) }) {
            app.remove(items.map(\.id))
        } else {
            app.add(items)
        }
    }

    public func selectionCount(_ entries: [PhotoEntry], in tab: Tab) -> (selected: Int, selectable: Int) {
        let items = entries.map { item(for: $0, in: tab) }.filter(\.isSelectable)
        return (items.count(where: { app?.isInCart($0.id) == true }), items.count)
    }

    // MARK: Aperçu

    /// L'aperçu ouvert : ce qu'il fait défiler, et d'où il vient.
    public struct Preview: Equatable, Sendable {
        public var sequence: PhotoSequence
        public let tab: Tab
        /// Le groupe montré : ses copies côte à côte (doublons), et la règle du
        /// dernier exemplaire, la même que dans la liste.
        public let group: PhotoGroup?
        /// Ceux dont l'utilisateur a accepté le téléchargement depuis iCloud.
        public var downloads: Set<String> = []
    }

    /// L'élément choisi d'un clic dans la liste : la barre d'espace l'ouvre en grand.
    public var selection: String?
    public private(set) var preview: Preview?

    /// L'aperçu en grand, façon Coup d'œil (Romain, 18/10/2026 : « en petit comme
    /// ça, c'est compliqué de se faire une idée […], on risque de faire des erreurs »).
    public func openPreview(_ entry: PhotoEntry, in tab: Tab, group: PhotoGroup? = nil) {
        guard let sequence = PhotoSequence(group?.entries ?? list(for: tab), at: entry.id) else { return }
        selection = entry.id
        preview = Preview(sequence: sequence, tab: tab, group: group)
    }

    /// La barre d'espace sur l'élément choisi.
    public func previewSelection() {
        guard let selection else { return }
        if let group = groups(for: tab).first(where: { $0.entries.contains { $0.id == selection } }),
           let entry = group.entries.first(where: { $0.id == selection }) {
            openPreview(entry, in: tab, group: group)
        } else if let entry = list(for: tab).first(where: { $0.id == selection }) {
            openPreview(entry, in: tab)
        }
    }

    /// Les flèches dans l'aperçu : l'élément voisin de la liste ou du groupe.
    public func stepPreview(_ delta: Int) {
        guard preview?.sequence.step(delta) == true else { return }
        selection = preview?.sequence.current.id
    }

    /// Un clic sur une copie, dans l'aperçu d'un doublon.
    public func showInPreview(_ id: String) {
        preview?.sequence.show(id)
        selection = id
    }

    public func closePreview() {
        preview = nil
    }

    /// L'utilisateur a confirmé : Photos peut télécharger cet élément depuis iCloud.
    public func allowDownload(_ id: String) {
        preview?.downloads.insert(id)
    }

    /// « Pour toute cette session » (Romain, 18/10/2026) : plus de confirmation
    /// pour ce qu'on ouvre dans l'aperçu, jusqu'à la fermeture d'Oust!. Gardé en
    /// mémoire seulement, jamais d'un lancement à l'autre ; les vignettes des
    /// listes restent, elles, sans réseau.
    public private(set) var downloadsAllowedForSession = false

    public func allowDownloadsForSession() {
        downloadsAllowedForSession = true
    }

    public func stopDownloadsForSession() {
        downloadsAllowedForSession = false
    }

    /// Photos peut-il aller chercher cet élément dans iCloud pour l'aperçu ?
    public func allowsDownload(_ id: String) -> Bool {
        downloadsAllowedForSession || preview?.downloads.contains(id) == true
    }

    /// Les flèches dans la liste : le choix passe à l'élément voisin.
    public func moveSelection(_ delta: Int) {
        let ids = (list(for: tab) + groups(for: tab).flatMap(\.entries)).map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selection.flatMap({ ids.firstIndex(of: $0) }) else {
            selection = delta < 0 ? ids.last : ids.first
            return
        }
        selection = ids[min(max(0, current + delta), ids.count - 1)]
    }

    private func list(for tab: Tab) -> [PhotoEntry] {
        switch tab {
        case .videos: videos
        case .screenshots: screenshots
        case .utilities: utilities
        case .duplicates, .similar: []
        }
    }

    private func groups(for tab: Tab) -> [PhotoGroup] {
        switch tab {
        case .duplicates: duplicates
        case .similar: similar
        case .videos, .screenshots, .utilities: []
        }
    }

    public func image(for id: String, side: Int, allowNetwork: Bool) async -> PhotoImage? {
        await library.image(of: id, side: side, allowNetwork: allowNetwork)
    }

    public func video(for id: String, allowNetwork: Bool) async -> PhotoVideo? {
        await library.video(of: id, allowNetwork: allowNetwork)
    }

    public func livePhoto(for id: String, side: Int, allowNetwork: Bool) async -> PhotoLive? {
        await library.livePhoto(of: id, side: side, allowNetwork: allowNetwork)
    }

    public func albums(for id: String) async -> [String] {
        await library.albums(of: id)
    }

    // MARK: Vignettes

    public func thumbnail(for id: String, side: Int) async -> PhotoThumbnail? {
        let key = "\(id)|\(side)"
        if let cached = thumbnails[key] { return cached }
        let thumbnail = await library.thumbnail(of: id, side: side)
        // Quelques centaines de vignettes suffisent à une liste qu'on fait défiler.
        if thumbnails.count > 600 { thumbnails.removeAll(keepingCapacity: true) }
        thumbnails[key] = thumbnail
        return thumbnail
    }

    // MARK: Changements

    /// Ce qui disparaît de la photothèque disparaît d'ici, et de la corbeille.
    private func watchChanges() {
        guard watching == nil else { return }
        let changes = library.changes()
        watching = Task { [weak self] in
            for await _ in changes {
                // Photos envoie ses changements en rafale : on les laisse finir.
                try? await Task.sleep(for: .milliseconds(500))
                await self?.pruneVanished()
            }
        }
    }

    private func pruneVanished() async {
        var seen = Set<String>()
        let shown = (videos + screenshots + utilities + duplicates.flatMap(\.entries) + similar.flatMap(\.entries))
            .map(\.id).filter { seen.insert($0).inserted }
        guard !shown.isEmpty else { return }
        let existing = await library.existing(shown)
        let vanished = Set(shown).subtracting(existing)
        guard !vanished.isEmpty else { return }
        gone.formUnion(vanished)
        app?.remove(vanished.map(PhotoEntry.itemID))
    }
}
