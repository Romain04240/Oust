import Darwin
import Foundation
import Testing
@testable import OustClouds
@testable import OustScan

/// Une fausse maison dans un dossier temporaire, avec ses nuages factices.
final class CloudBench {
    let root: URL
    var home: URL { root.appendingPathComponent("maison", isDirectory: true) }
    var drive: URL { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true) }
    var storage: URL { home.appendingPathComponent("Library/CloudStorage", isDirectory: true) }
    var trash: URL { root.appendingPathComponent("_corbeille", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-nuages-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ url: URL, bytes: Int = 10_000, modified: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    /// Un fichier creux : une grande taille logique, presque rien sur le disque.
    /// C'est ce qui ressemble le plus, dans un dossier temporaire, à un fantôme
    /// de nuage (le drapeau `SF_DATALESS` ne se pose que par le noyau).
    @discardableResult
    func sparse(_ url: URL, logical: UInt64) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: logical)
        try handle.close()
        return url
    }

    func folder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

@Suite("Le parcours des nuages ne lit que ce que le service a posé ici")
struct CloudListerTests {

    @Test("Fichiers, paquets comptés comme un fichier, caché et liens laissés de côté")
    func listsWhatTheFinderShows() throws {
        let bench = try CloudBench()
        try bench.file(bench.drive.appendingPathComponent("Business/facture.pdf"), bytes: 300_000)
        try bench.sparse(bench.drive.appendingPathComponent("Films/vacances.mov"), logical: 50_000_000)
        try bench.file(bench.drive.appendingPathComponent("Présentation.key/Index.zip"), bytes: 20_000)
        try bench.file(bench.drive.appendingPathComponent("Présentation.key/Data/image.jpg"), bytes: 30_000)
        try bench.file(bench.drive.appendingPathComponent(".DS_Store"))
        try bench.file(bench.drive.appendingPathComponent(".Trash/vieux.pdf"))
        try bench.folder(bench.home.appendingPathComponent("Desktop"))
        try FileManager.default.createSymbolicLink(at: bench.drive.appendingPathComponent("Desktop"),
                                                   withDestinationURL: bench.home.appendingPathComponent("Desktop"))
        try bench.file(bench.home.appendingPathComponent("Desktop/hors-nuage.txt"))

        let listing = CloudLister.list(bench.drive)

        let names = Set(listing.files.map { ($0.path as NSString).lastPathComponent })
        #expect(names == ["facture.pdf", "vacances.mov", "Présentation.key"])
        let film = try #require(listing.files.first { $0.path.hasSuffix("vacances.mov") })
        // Taille du nuage et taille ici, distinctes.
        #expect(film.logicalSize == 50_000_000)
        #expect(film.allocatedSize < 1_000_000)
        #expect(!film.isDataless)
        let keynote = try #require(listing.files.first { $0.path.hasSuffix("Présentation.key") })
        #expect(keynote.isPackage)
        #expect(keynote.logicalSize == 50_000)
        #expect(listing.unlistedFolders.isEmpty && listing.unreadableFolders.isEmpty)
    }

    @Test("Le progrès compte chaque fichier une fois")
    func progressCountsFiles() throws {
        let bench = try CloudBench()
        for index in 0..<5 { try bench.file(bench.drive.appendingPathComponent("a/\(index).txt")) }
        let progress = CloudListingProgress()

        _ = CloudLister.list(bench.drive, progress: { progress.add($0) })

        #expect(progress.files == 5)
    }

    @Test("Un dossier fantôme n'est jamais ouvert, un fichier fantôme est compté sans rien ici")
    func datalessEntries() {
        var folder = RawEntry()
        folder.name = "Archives"
        folder.type = Attr.typeDirectory
        folder.device = 1
        folder.flags = Attr.sfDataless
        #expect(CloudLister.classify(folder, device: 1) == .unlisted)

        var ghost = RawEntry()
        ghost.name = "rapport.pdf"
        ghost.type = Attr.typeRegular
        ghost.device = 1
        ghost.flags = Attr.sfDataless
        ghost.logicalSize = 6_427_253
        ghost.allocated = 0
        #expect(CloudLister.classify(ghost, device: 1) == .file)
        let file = CloudLister.file(ghost, path: "/x/rapport.pdf", directory: "/x")
        #expect(file.isDataless && file.logicalSize == 6_427_253 && file.allocatedSize == 0 && file.privateSize == nil)
    }

    @Test("Autre volume, firmlink, lien, caché : laissés de côté")
    func skipsWhatIsNotTheCloud() {
        var entry = RawEntry()
        entry.name = "Ailleurs"
        entry.type = Attr.typeDirectory
        entry.device = 1
        entry.mountStatus = Attr.dirMountPoint
        #expect(CloudLister.classify(entry, device: 1) == .skip)
        entry.mountStatus = 0
        entry.device = 2
        #expect(CloudLister.classify(entry, device: 1) == .skip)
        entry.device = 1
        entry.flags = Attr.sfFirmlink
        #expect(CloudLister.classify(entry, device: 1) == .skip)
        entry.flags = CloudLister.hiddenFlag
        #expect(CloudLister.classify(entry, device: 1) == .skip)
        entry.flags = 0
        entry.type = Attr.typeSymlink
        #expect(CloudLister.classify(entry, device: 1) == .skip)
        entry.type = Attr.typeDirectory
        entry.name = ".shortcut-targets-by-id"
        #expect(CloudLister.classify(entry, device: 1) == .skip)
        entry.name = "Projet.pages"
        #expect(CloudLister.classify(entry, device: 1) == .package)
        entry.name = "Projet"
        #expect(CloudLister.classify(entry, device: 1) == .folder)
    }
}

@Suite("Les comptes se lisent dans les dossiers, sans réseau")
struct CloudAccountsTests {

    @Test("iCloud Drive, ses dossiers d'applications, Google Drive ; ni coffre, ni ancien compte, ni téléphone")
    func discovers() throws {
        let bench = try CloudBench()
        let mobile = bench.home.appendingPathComponent("Library/Mobile Documents")
        try bench.folder(bench.drive)
        try bench.folder(mobile.appendingPathComponent("com~apple~Pages/Documents"))
        try bench.folder(mobile.appendingPathComponent("com~apple~mail/Data"))
        try bench.folder(mobile.appendingPathComponent("2BUA8C4S2C~com~agilebits~onepassword/Documents"))
        try bench.folder(bench.home.appendingPathComponent("Desktop"))
        try bench.folder(bench.home.appendingPathComponent("Documents"))
        try bench.folder(bench.storage.appendingPathComponent("GoogleDrive-romain@exemple.fr/Mon Drive"))
        try bench.folder(bench.storage.appendingPathComponent("GoogleDrive-romain@exemple.fr (10-07-2026 16:41)"))
        try bench.folder(bench.storage.appendingPathComponent("O+Connect-DeviceSpace"))

        let accounts = CloudAccounts.discover(
            home: bench.home,
            // Les Documents ne sont pas synchronisés, l'ancien compte n'est plus vivant.
            isLive: { !$0.path.contains("(") && $0.lastPathComponent != "Documents" },
            containerName: { CloudAccounts.fallbackName($0.lastPathComponent) },
            displayName: { $0.lastPathComponent == "Desktop" ? "Bureau" : $0.lastPathComponent }
        )

        #expect(accounts.map(\.service) == [.iCloudDrive, .googleDrive])
        let iCloud = accounts[0]
        #expect(iCloud.roots.map(\.label) == [nil, "Bureau", "Pages"])
        #expect(accounts[1].account == "romain@exemple.fr")
        #expect(accounts[1].roots.map(\.url.lastPathComponent) == ["GoogleDrive-romain@exemple.fr"])
    }

    @Test("Les services reconnus d'après leur dossier")
    func services() {
        #expect(CloudService.fileProvider(folder: "GoogleDrive-a@b.fr") == .googleDrive)
        #expect(CloudService.fileProvider(folder: "OneDrive-Personal") == .oneDrive)
        #expect(CloudService.fileProvider(folder: "Dropbox") == .dropbox)
        #expect(CloudService.fileProvider(folder: "O+Connect-DeviceSpace") == nil)
        #expect(CloudAccounts.fallbackName("iCloud~md~obsidian") == "Obsidian")
    }
}
