import AppKit
import Foundation
import Observation
import OustClean
import OustClouds
import OustCore
import OustSafety
import OustScan

/// Les nuages vus depuis ce Mac : iCloud Drive et les File Providers, d'après
/// les fichiers fantômes que les services y laissent.
///
/// Réponse au « Cloud Cleanup » de CleanMyMac, qui se connecte aux comptes en
/// ligne : Oust! ne se connecte à rien (RULES.md, règle 11) et ne télécharge
/// rien. Il ne voit donc que ce que chaque service a déjà listé ici, et le dit.
@MainActor
@Observable
public final class CloudsModel {
    weak var app: AppModel?

    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case largest
        case oldest
        case duplicates
        case onThisMac

        public var id: String { rawValue }
        public var localizationKey: String { "clouds.tab.\(rawValue)" }

        public var symbol: String {
            switch self {
            case .largest: "scalemass"
            case .oldest: "calendar.badge.clock"
            case .duplicates: "doc.on.doc"
            case .onThisMac: "laptopcomputer"
            }
        }
    }

    /// Les seuils de taille, partagés par les listes.
    public enum SizePreset: Int64, CaseIterable, Identifiable, Sendable {
        case oneMegabyte = 1_000_000
        case tenMegabytes = 10_000_000
        case hundredMegabytes = 100_000_000
        case gigabyte = 1_000_000_000
        public var id: Int64 { rawValue }
    }

    /// « Pas modifié depuis ».
    public enum AgePreset: Int, CaseIterable, Identifiable, Sendable {
        case oneYear = 1
        case twoYears = 2
        case fiveYears = 5
        public var id: Int { rawValue }
        public var localizationKey: String { "clouds.age.\(rawValue)" }
    }

    public private(set) var phase: AppModel.Phase = .idle
    public private(set) var inventory: CloudInventory?
    /// Le nombre de fichiers vus pendant le parcours, lu par l'interface.
    public let progress = CloudListingProgress()

    public var tab: Tab = .largest
    /// Les comptes montrés ; vide : tous.
    public var selectedAccounts: Set<String> = [] { didSet { refreshLists() } }
    public var minimumSize: SizePreset = .tenMegabytes { didSet { refreshLists() } }
    public var age: AgePreset = .twoYears { didSet { refreshLists() } }
    /// Par nom ou par dossier, dans l'onglet ouvert : à l'essai du 18/10/2026,
    /// un fichier de 1,2 Mo était au rang 3 650 sur 3 889, introuvable.
    public var query = "" { didSet { if query != oldValue { refreshLists() } } }
    public var isSearching: Bool { !ItemFilter.tokens(of: query).isEmpty }

    public private(set) var largest: [CloudEntry] = []
    public private(set) var oldest: [CloudEntry] = []
    public private(set) var duplicates: [CloudDuplicateGroup] = []
    public private(set) var onThisMac: [CloudEntry] = []

    @ObservationIgnored private var cancellation: CleanupCancellation?
    /// Les éléments déjà construits, par chemin : chaque ligne affichée en a
    /// besoin, et la garde de chemins lit le disque.
    @ObservationIgnored private var itemCache: [String: CleanupItem] = [:]
    /// Le dernier nettoyage dont on a retiré les fichiers.
    @ObservationIgnored private var appliedCleaning: UUID?
    /// Les noms et dossiers, préparés pendant la lecture du cloud.
    @ObservationIgnored private var search = CloudSearch()

    init() {}

    // MARK: Analyse

    public func scan() async {
        guard !phase.isRunning, let home = app?.home else { return }
        phase = .running
        progress.set(0)
        let cancellation = CleanupCancellation()
        self.cancellation = cancellation
        let progress = progress
        // L'app d'un service fermée, son compte est déconnecté : rien n'y part.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let (found, search) = await Task.detached(priority: .userInitiated) { () -> (CloudInventory, CloudSearch) in
            let accounts = await CloudAccounts.connections(of: CloudAccounts.discover(home: home), running: running)
            let inventory = CloudInventory.scan(accounts, progress: progress) { cancellation.isCancelled }
            return (inventory, CloudSearch(inventory.files))
        }.value
        self.cancellation = nil
        if cancellation.isCancelled {
            phase = inventory == nil ? .idle : .done(inventory?.date ?? Date())
            return
        }
        inventory = found
        self.search = search
        itemCache = [:]
        appliedCleaning = nil
        // Un compte choisi qui a disparu ne doit pas tout cacher.
        selectedAccounts = selectedAccounts.filter { id in found.accounts.contains { $0.id == id } }
        refreshLists()
        phase = .done(found.date)
    }

    public func cancel() {
        cancellation?.cancel()
    }

    /// Ce qui vient de partir quitte les listes, sans relire les nuages.
    public func applyFinishedCleaning() {
        guard let app, case .finished(let report) = app.cleaning, report.sessionID != appliedCleaning,
              let inventory else { return }
        appliedCleaning = report.sessionID
        let gone = Set(report.outcomes.filter { $0.result.succeeded && $0.method == .trashFromCloud }.flatMap(\.paths))
        guard !gone.isEmpty else { return }
        self.inventory = inventory.removing(gone)
        refreshLists()
    }

    // MARK: Listes

    func refreshLists() {
        guard let inventory else {
            (largest, oldest, duplicates, onThisMac) = ([], [], [], [])
            return
        }
        let accounts = selectedAccounts
        let filter = search.filter(query)
        let matches: (CloudEntry) -> Bool = filter ?? { _ in true }
        // On cherche un fichier par son nom : le seuil de taille le cacherait.
        let minimum = filter == nil ? minimumSize.rawValue : 0
        let before = Calendar.current.date(byAdding: .year, value: -age.rawValue, to: Date()) ?? Date()
        largest = inventory.largest(in: accounts, minimumSize: minimum).filter(matches)
        oldest = inventory.oldest(in: accounts, before: before, minimumSize: minimum).filter(matches)
        // Les doublons évidents à partir de 1 Mo, quel que soit le seuil : un
        // seuil plus haut les cacherait presque tous. Un groupe entier dès
        // qu'un de ses fichiers répond : on choisit entre ses copies.
        duplicates = inventory.duplicates(in: accounts, minimumSize: min(minimumSize.rawValue, SizePreset.oneMegabyte.rawValue))
            .filter { $0.files.contains(where: matches) }
        onThisMac = inventory.onThisMac(in: accounts).filter(matches)
    }

    public var summary: CloudAccountSummary {
        inventory?.summary(of: selectedAccounts) ?? CloudAccountSummary()
    }

    public func count(_ tab: Tab) -> Int {
        switch tab {
        case .largest: largest.count
        case .oldest: oldest.count
        case .duplicates: duplicates.count
        case .onThisMac: onThisMac.count
        }
    }

    /// Ce que la liste pèse dans le nuage (les copies en trop, pour les doublons).
    public func cloudBytes(_ tab: Tab) -> Int64 {
        switch tab {
        case .largest: largest.reduce(0) { $0 + $1.cloudSize }
        case .oldest: oldest.reduce(0) { $0 + $1.cloudSize }
        case .duplicates: duplicates.reduce(0) { $0 + $1.cloudSavings }
        case .onThisMac: onThisMac.reduce(0) { $0 + $1.localSize }
        }
    }

    public func toggleAccount(_ id: String) {
        if selectedAccounts.contains(id) { selectedAccounts.remove(id) } else { selectedAccounts.insert(id) }
    }

    public func account(_ id: String) -> CloudAccount? { inventory?.account(id) }

    // MARK: Corbeille

    public func item(for file: CloudEntry) -> CleanupItem {
        if let cached = itemCache[file.id] { return cached }
        let account = account(file.accountID)
        let item: CleanupItem
        if let app, app.canMoveFiles {
            item = file.cleanupItem(account: account, guard: PathGuard(home: app.home))
        } else {
            item = file.cleanupItem(account: account, pathRefused: false)
        }
        itemCache[file.id] = item
        return item
    }

    public func isInCart(_ file: CloudEntry) -> Bool {
        app?.isInCart(item(for: file).id) ?? false
    }

    public func toggle(_ file: CloudEntry) {
        app?.toggle(item(for: file))
    }

    /// Le dernier exemplaire d'un groupe de doublons reste : on n'en jette
    /// jamais toutes les copies d'ici (SPEC §7), d'autant que rien ne prouve
    /// qu'elles soient identiques.
    public func canToggle(_ file: CloudEntry, in group: CloudDuplicateGroup) -> Bool {
        guard app?.canSelectForCleanup(item(for: file)) == true else { return false }
        if isInCart(file) { return true }
        let others = group.files.filter { $0.id != file.id }
        return others.contains { !isInCart($0) }
    }
}
