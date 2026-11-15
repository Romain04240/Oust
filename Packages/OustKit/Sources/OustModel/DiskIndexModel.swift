import Darwin
import Foundation
import Observation
import OustCore
import OustRules
import OustScan
import OustVolume

/// L'arborescence du disque de démarrage, faite une fois et partagée :
/// l'Explorateur l'affiche, les règles y lisent leurs tailles, les doublons y
/// trouvent leurs candidats.
///
/// Gardée sur disque (`TreeStore`), elle s'affiche dès l'ouverture ; FSEvents dit
/// ensuite quels dossiers relire. Un parcours complet de ce Mac prend 22 s, la
/// réanalyse qui suit une seconde ou deux (mesuré le 18/10/2026).
@MainActor
@Observable
public final class DiskIndexModel {
    weak var app: AppModel?
    @ObservationIgnored let store: TreeStore
    // La jauge s'abonne via currentTree/currentScanDate : ignorer l'index
    // la laissait sur un premier résultat vide après le chargement du cache.
    private var index: ScanIndex?
    /// L'arbre partagé tel qu'il est, sans attendre de rafraîchissement (panneau des disques).
    var currentTree: TreeNode? { index?.root }
    var currentScanDate: Date? { index?.scannedAt }
    @ObservationIgnored private var refreshTask: Task<ScanIndex?, Never>?
    @ObservationIgnored private var spotlightTask: Task<Void, Never>?
    @ObservationIgnored private var runningProgress: ScanProgress?

    /// Comment s'est fait le dernier rafraîchissement, et en combien de temps.
    public private(set) var lastRefresh: IndexRefresh?
    public private(set) var lastDuration: TimeInterval?
    /// Un rafraîchissement tourne ; l'arbre affiché est le précédent.
    public private(set) var isRefreshing = false
    /// Les gros fichiers d'après Spotlight, le temps qu'un premier parcours
    /// complet se fasse. Vide dès que l'arbre existe.
    public private(set) var spotlightFiles: [SpotlightFile] = []

    /// Les réglages de l'arbre partagé : les fichiers de 100 Ko et plus un à un
    /// (onglets Types et Âge de l'Explorateur), et les marqueurs de projets
    /// retenus même petits (chercheur d'artefacts).
    static func options(for home: URL) -> ScanOptions {
        ScanOptions(leafThreshold: 100_000, notableNames: RuleEngine.notableNames,
                    readOnlyPreferencesDirectory: preferencesDirectory(for: home),
                           accountArchivesDirectory: AccountArchivePath.root.path)
    }

    nonisolated static func preferencesDirectory(for home: URL) -> String {
        PreferenceDirectory.url(in: home.standardizedFileURL).path
    }

    /// Les gros fichiers montrés en attendant l'arbre : le seuil le plus bas de
    /// « Gros et vieux fichiers ».
    static let spotlightMinimum: Int64 = 10_000_000

    init(store: TreeStore = .standard()) {
        self.store = store
    }

    // MARK: Ouverture

    /// L'arbre de la dernière fois, tout de suite, puis seulement ce qui a changé.
    func start() async {
        guard let app, let boot = app.bootVolume else { return }
        let store = store
        let root = boot.scanRoot.standardizedFileURL.path
        let loaded = await Task.detached(priority: .userInitiated) { store.load(rootPath: root) }.value
        guard let loaded, loaded.canReuse(for: Self.options(for: app.home)), index == nil, refreshTask == nil else { return }
        index = loaded
        attachExplorer()
        refresh()
    }

    // MARK: Rafraîchir

    /// L'Explorateur ouvre le disque de démarrage : l'arbre connu s'il y en a
    /// un, rafraîchi derrière ; sinon le parcours en cours, avec sa progression.
    func explore() {
        refresh()
        attachExplorer()
    }

    /// Lance un rafraîchissement, ou rejoint celui qui tourne. La tâche rend
    /// l'index à jour (ou `nil` si on l'a arrêté).
    @discardableResult
    func refresh() -> Task<ScanIndex?, Never> {
        if let refreshTask { return refreshTask }
        guard let app, let boot = app.bootVolume else { return Task { nil } }
        let previous = index
        let progress = ScanProgress()
        runningProgress = progress
        if previous == nil { findLargeFilesWithSpotlight(boot) }
        isRefreshing = true
        let store = store
        let options = Self.options(for: app.home)
        let started = Date()
        let task = Task<ScanIndex?, Never> {
            let (scanned, how) = await ScanIndex.refresh(previous, root: boot.scanRoot, options: options,
                                                         progress: progress)
            self.refreshTask = nil
            self.runningProgress = nil
            self.isRefreshing = false
            guard !progress.isCancelled else { return nil }
            let fresh = scanned.checkedForDisplay(for: Self.options(for: app.home))
            self.index = fresh
            self.lastRefresh = how
            self.lastDuration = Date().timeIntervalSince(started)
            self.app?.refreshVolumes()
            self.spotlightTask?.cancel()
            self.spotlightFiles = []
            self.attachExplorer()
            // Écrit en arrière-plan : la prochaine ouverture repartira d'ici.
            Task.detached(priority: .utility) { try? store.save(fresh) }
            return fresh
        }
        refreshTask = task
        attachExplorer()
        return task
    }

    /// Montre dans l'Explorateur l'arbre connu, ou la progression du premier
    /// parcours, s'il montre le disque de démarrage (ou rien encore).
    private func attachExplorer() {
        guard let app, let boot = app.bootVolume, app.treeVolume == nil || app.treeVolume?.isBoot == true else { return }
        if let index, index.canReuse(for: Self.options(for: app.home))
            || (index.hasWithheldGains && runningProgress == nil) {
            app.showExplorerIndex(index, volume: boot)
        } else if let runningProgress {
            app.showSharedScan(volume: boot, progress: runningProgress)
        }
    }

    /// De quoi attendre l'arbre à jour depuis une autre tâche (règles, doublons).
    func treeProvider() -> @Sendable () async -> TreeNode? {
        guard app?.bootVolume != nil else { return { nil } }
        let task = refresh()
        return { await task.value?.root }
    }

    // MARK: Spotlight

    private func findLargeFilesWithSpotlight(_ boot: VolumeDescriptor) {
        guard let app else { return }
        let preferencesDirectory = Self.preferencesDirectory(for: app.home)
        spotlightTask?.cancel()
        spotlightTask = Task {
            let files = await Spotlight.largeFiles(minimumBytes: Self.spotlightMinimum, under: boot.scanRoot,
                                                   readOnlyPreferencesDirectory: preferencesDirectory,
                                                   accountArchivesDirectory: AccountArchivePath.root.path)
            guard !Task.isCancelled, self.index == nil else { return }
            self.spotlightFiles = files
        }
    }
}

extension AppModel {
    /// Publie l’arbre du volume ou du dossier affiché dans l’Explorateur.
    func showExplorerIndex(_ index: ScanIndex, volume: VolumeDescriptor) {
        let displayed = index.checkedForDisplay()
        displayedExplorerIndex = displayed
        treeVolume = volume
        tree = displayed.root
        explorer = .done(displayed.scannedAt)
    }

    /// Écarte les gains de l'arbre affiché dès que les dossiers protégés changent.
    @discardableResult
    public func revalidateExplorerGains() -> Bool {
        guard let index = displayedExplorerIndex, let volume = treeVolume, tree === index.root else { return true }
        let checked = index.checkedForDisplay()
        guard checked.root !== index.root else { return true }
        showExplorerIndex(checked, volume: volume)
        return false
    }

    @discardableResult
    package func exportExplorerCSV(
        to destination: URL,
        for root: TreeNode,
        render: () -> String?,
        stage: (String, URL) throws -> Void = { try $0.write(to: $1, atomically: false, encoding: .utf8) }
    ) throws -> Bool {
        guard tree === root, revalidateExplorerGains() else { return false }
        let original = try ExplorerCSVPermissions(at: destination)
        guard let csv = render() else { return false }
        let manager = FileManager.default
        let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: destination.deletingLastPathComponent(), create: true)
        defer { try? manager.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("export.csv")
        try stage(csv, temporary)
        if let original { try original.copy(from: destination, to: temporary) }
        guard revalidateExplorerGains(), tree === root else { return false }
        // Une destination nouvelle ne peut pas écraser un fichier apparu pendant l'export.
        if let original, try ExplorerCSVPermissions(at: destination) != original { return false }
        let flags: UInt32 = original == nil ? UInt32(RENAME_EXCL) : 0
        guard renamex_np(temporary.path, destination.path, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    /// Le premier parcours du disque de démarrage, suivi par l'Explorateur.
    func showSharedScan(volume: VolumeDescriptor, progress: ScanProgress) {
        displayedExplorerIndex = nil
        treeVolume = volume
        scanProgress = progress
        tree = nil
        explorer = .running
    }
}

private struct ExplorerCSVPermissions: Equatable {
    private let device: dev_t
    private let inode: ino_t
    private let owner: uid_t
    private let group: gid_t
    private let mode: mode_t
    // Les changements de mode, de propriétaire et d'ACL modifient ce champ.
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    init?(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        self.init(info)
    }

    private init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        owner = info.st_uid
        group = info.st_gid
        mode = info.st_mode & 0o7777
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    func copy(from original: URL, to temporary: URL) throws {
        let input = open(original.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG, Self(info) == self else { throw POSIXError(.ESTALE) }

        let output = open(temporary.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(output) }
        guard fstat(output, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if info.st_uid != owner || info.st_gid != group {
            guard fchown(output, owner, group) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let sourceACL = try Self.readACL(input)
        defer { if let sourceACL { acl_free(UnsafeMutableRawPointer(sourceACL)) } }
        if let sourceACL {
            guard acl_set_fd_np(output, sourceACL, ACL_TYPE_EXTENDED) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else if let temporaryACL = try Self.readACL(output) {
            acl_free(UnsafeMutableRawPointer(temporaryACL))
            guard let empty = acl_init(0) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            guard acl_set_fd_np(output, empty, ACL_TYPE_EXTENDED) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard fchmod(output, mode) == 0, fstat(output, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let actualACL = try Self.readACL(output)
        defer { if let actualACL { acl_free(UnsafeMutableRawPointer(actualACL)) } }
        guard info.st_uid == owner, info.st_gid == group, info.st_mode & 0o7777 == mode,
              try Self.serializedACL(sourceACL) == Self.serializedACL(actualACL) else {
            throw POSIXError(.EPERM)
        }
    }

    private static func readACL(_ descriptor: Int32) throws -> acl_t? {
        if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) { return acl }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func serializedACL(_ acl: acl_t?) throws -> Data? {
        guard let acl else { return nil }
        let size = acl_size(acl)
        guard size > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var contents = Data(count: size)
        let copied = contents.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, acl, size) }
        guard copied == size else { throw POSIXError(.EIO) }
        return contents
    }
}
