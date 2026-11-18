import Foundation
import Observation
import OustCore
import OustSafety
import OustScan
import OustUninstall

/// Le désinstalleur : les applications installées, et pour celle qu'on choisit,
/// ses restes trouvés en correspondance stricte.
@MainActor
@Observable
public final class ApplicationsModel {
    weak var app: AppModel?

    public private(set) var phase: AppModel.Phase = .idle
    public private(set) var apps: [InstalledApp] = []
    /// Combien d'applications ont déjà leur taille.
    public private(set) var measuredCount = 0
    /// Les applications ouvertes au moment de la lecture, par identifiant.
    public private(set) var runningIDs: Set<String> = []

    public private(set) var selectedID: String?
    public private(set) var leftovers: [Leftover] = []
    public private(set) var leftoversLoading = false
    /// Ce que l'utilisateur a coché pour l'application choisie (identifiants d'éléments).
    public var chosen: Set<String> = []

    public var showsProtected = false

    // MARK: Restes d'applications disparues

    public private(set) var orphanPhase: AppModel.Phase = .idle
    public private(set) var orphans: [OrphanGroup] = []
    /// Le détail montre les restes d'applications disparues, pas une application.
    public private(set) var showsOrphans = false
    /// Sans l'Accès complet au disque, la fiche des conteneurs n'est pas lue.
    public private(set) var orphansReadContainers = true

    // MARK: Applications mises à la corbeille du Mac

    /// Le détail montre la revue d'une application qu'on vient de mettre à la
    /// corbeille du Mac (`TrashedAppsModel`), par son chemin dans la corbeille.
    public private(set) var trashedReviewID: String?

    init() {}

    public var selected: InstalledApp? { apps.first { $0.id == selectedID } }

    /// Désinstallables d'abord, les plus lourdes en tête.
    public var uninstallable: [InstalledApp] { apps.filter(\.isUninstallable) }
    public var excluded: [InstalledApp] { apps.filter { !$0.isUninstallable } }

    // MARK: Lecture

    /// Lit les applications, puis les mesure une à une : la liste paraît tout de
    /// suite, les tailles arrivent au fil de l'eau.
    public func load() async {
        guard !phase.isRunning, let home = app?.home else { return }
        phase = .running
        measuredCount = 0
        // Et le dossier Applications de chaque autre disque branché : une
        // application rangée sur un disque externe se désinstalle comme les
        // autres. Jamais une sauvegarde Time Machine.
        let volumeRoots = (app?.volumes ?? []).filter { !$0.isBoot && app?.canAnalyzeVolume($0) == true }
            .map { $0.mountURL.appendingPathComponent("Applications", isDirectory: true) }
        let roots = AppCatalog.standardRoots(home: home) + volumeRoots
        let listed = await Task.detached(priority: .userInitiated) { AppCatalog.installedApps(in: roots) }.value
        apps = listed
        refreshRunning()
        // Les restes ne dépendent que de la liste, pas des tailles : on les
        // cherche pendant que les applications se mesurent.
        Task { await findOrphans() }
        for installed in listed {
            let measure = await Scanner.measure(installed.url)
            if let index = apps.firstIndex(where: { $0.id == installed.id }) { apps[index].sizes = measure.sizes }
            measuredCount += 1
        }
        apps.sort { $0.sizes.allocated > $1.sizes.allocated }
        phase = .done(Date())
        if let selectedID, !apps.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    public func refreshRunning() {
        let snapshot = ProcessSnapshot.current()
        runningIDs = Set(apps.filter { snapshot.running(inside: $0.url.path) != nil }.map(\.id))
    }

    // MARK: Choix d'une application

    /// Rien n'est coché d'office, pas même l'application : elle ne se régénère
    /// pas (RULES.md, règle 4). La cocher coche avec elle les restes qui ne
    /// servent plus à rien sans elle.
    public func select(_ installed: InstalledApp) async {
        showsOrphans = false
        trashedReviewID = nil
        selectedID = installed.id
        leftovers = []
        chosen = []
        guard installed.isUninstallable, let home = app?.home else { return }
        leftoversLoading = true
        let all = apps
        let found = await Task.detached(priority: .userInitiated) {
            LeftoverFinder.leftovers(of: installed, among: all, home: home)
        }.value
        let measured = await LeftoverFinder.measured(found)
        guard selectedID == installed.id else { return }
        leftovers = measured.sorted { $0.sizes.allocated > $1.sizes.allocated }
        if chosen.contains(installed.cleanupItem().id) { checkDisposableLeftovers(of: installed) }
        leftoversLoading = false
    }

    private func checkDisposableLeftovers(of installed: InstalledApp) {
        for leftover in leftovers where leftover.isPreselected {
            chosen.insert(leftover.cleanupItem(for: installed).id)
        }
    }

    /// Retire de la liste ce qui a quitté le disque depuis (désinstallé par la
    /// corbeille d'Oust!, ou à la main).
    public func pruneMissing() {
        pruneMissingOrphans()
        leftovers = LeftoverFinder.recheckingPreferenceVeto(leftovers)
        if let selected {
            let blocked = leftovers.map { $0.cleanupItem(for: selected) }.filter { !$0.isSelectable }.map(\.id)
            chosen.subtract(blocked)
            app?.remove(blocked)
        }
        let before = apps.count
        apps.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        guard apps.count != before else { return }
        if let selectedID, !apps.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            leftovers = []
            chosen = []
        }
    }

    /// Les éléments de la désinstallation, l'application en premier.
    public var items: [CleanupItem] {
        guard let selected else { return [] }
        return [selected.cleanupItem()] + leftovers.map { $0.cleanupItem(for: selected) }
    }

    public func canSelectForCleanup(_ item: CleanupItem) -> Bool {
        app?.canSelectForCleanup(item) == true
    }

    public func toggle(_ item: CleanupItem) {
        guard canSelectForCleanup(item) else { return }
        if chosen.contains(item.id) {
            chosen.remove(item.id)
        } else {
            chosen.insert(item.id)
            if let selected, item.id == selected.cleanupItem().id { checkDisposableLeftovers(of: selected) }
        }
    }

    /// Tout ce qui peut être coché l'est déjà.
    public var allChosen: Bool {
        let selectable = items.filter(canSelectForCleanup)
        return !selectable.isEmpty && selectable.allSatisfy { chosen.contains($0.id) }
    }

    /// Tout cocher d'un coup, ou tout décocher si tout l'est déjà (demande de
    /// Romain, 18/10/2026). Les éléments protégés restent hors de portée.
    public func toggleAll() {
        chosen = allChosen ? [] : Set(items.filter(canSelectForCleanup).map(\.id))
    }

    public var chosenItems: [CleanupItem] { items.filter { chosen.contains($0.id) && canSelectForCleanup($0) } }
    public var chosenBytes: Int64 { chosenItems.reduce(0) { $0 + $1.sizes.freeable } }
    public var leftoverBytes: Int64 { leftovers.filter { $0.protection == nil }.reduce(0) { $0 + $1.sizes.freeable } }

    /// Jette dans la corbeille d'Oust! ce qui est coché ; le vide se fait de là,
    /// avec sa revue et sa confirmation, comme tout le reste (SPEC §6.3).
    public func sendToBin() {
        guard let app, !chosenItems.isEmpty else { return }
        app.add(chosenItems)
        app.section = .cart
    }

    public func isRunning(_ installed: InstalledApp) -> Bool { runningIDs.contains(installed.id) }

    // MARK: Restes d'applications disparues

    public func showOrphans() {
        pruneMissingOrphans()
        selectedID = nil
        leftovers = []
        chosen = []
        trashedReviewID = nil
        showsOrphans = true
    }

    private func pruneMissingOrphans() {
        updateOrphans(orphans.compactMap { group in
            var group = group
            group.leftovers.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
            return group.leftovers.isEmpty ? nil : group
        })
    }

    /// La revue d'une application mise à la corbeille du Mac.
    public func showTrashed(_ id: String) {
        selectedID = nil
        leftovers = []
        chosen = []
        showsOrphans = false
        trashedReviewID = id
    }

    public func hideTrashed(_ id: String) {
        if trashedReviewID == id { trashedReviewID = nil }
    }

    /// Cherche ce qu'ont laissé les applications qui ne sont plus là. Rien n'est
    /// coché : chaque reste entre dans la corbeille d'Oust! par la main de
    /// l'utilisateur, comme dans les autres sections (RULES.md, règle 4).
    public func findOrphans() async {
        // Sans la liste des applications, tout passerait pour orphelin : on ne
        // cherche rien tant qu'elle n'est pas lue (RULES.md, règle 3).
        guard !orphanPhase.isRunning, let app, !apps.isEmpty else { return }
        orphanPhase = .running
        let home = app.home
        let installed = apps
        // Relu ici : au premier affichage, l'état de l'application ne le sait peut-être pas encore.
        let canRead = FullDiskAccess.isGranted(home: home) == true
        let recency = app.preferences.recencyDays
        let found = await Task.detached(priority: .userInitiated) {
            OrphanFinder.orphans(home: home, installed: installed,
                                 sources: .standard(home: home, canReadContainers: canRead))
        }.value
        let measured = await OrphanFinder.measured(found, canReadContainers: canRead, recencyDays: recency)
        // Ce qu'on peut retirer d'abord ; ce qui est gardé par prudence ensuite.
        updateOrphans(measured)
        orphansReadContainers = canRead
        orphanPhase = .done(Date())
    }

    func updateOrphans(_ groups: [OrphanGroup]) {
        let checked = OrphanFinder.recheckingPreferenceVeto(groups)
        orphans = checked.filter { !$0.isFullyProtected } + checked.filter(\.isFullyProtected)
        // Un reste jeté dans la corbeille d'Oust! que la nouvelle recherche ne
        // propose plus (l'application est revenue, quelque chose y écrit) en sort.
        let proposed = Set(orphans.flatMap(items(of:)).filter(canSelectForCleanup).map(\.id))
        if let app {
            app.remove(app.cartItems.filter { $0.category == .appLeftovers && !proposed.contains($0.id) }.map(\.id))
        }
    }

    public func items(of group: OrphanGroup) -> [CleanupItem] {
        group.leftovers.map { $0.cleanupItem(in: group) }
    }

    public var proposedOrphans: [OrphanGroup] { orphans.filter { !$0.isFullyProtected } }
    public var protectedOrphans: [OrphanGroup] { orphans.filter(\.isFullyProtected) }
    public var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.freeable } }

    /// Tout le groupe dans la corbeille d'Oust!, ou tout le groupe hors d'elle
    /// s'il y est déjà.
    public func toggleAll(of group: OrphanGroup) {
        guard let app else { return }
        let selectable = items(of: group).filter(canSelectForCleanup)
        if selectable.allSatisfy({ app.isInCart($0.id) }) {
            app.remove(selectable.map(\.id))
        } else {
            app.add(selectable)
        }
    }
}
