import Darwin
import Foundation
import Testing
import OustClean
import OustCore
import OustSafety
@testable import OustClouds

@Suite("La garde ne laisse jeter d'un nuage que les documents de l'utilisateur")
struct CloudTrashGuardTests {
    let home = URL(fileURLWithPath: "/Home/test")
    var guardian: PathGuard { PathGuard(home: home) }

    func allows(_ relative: String) -> Bool {
        guardian.allowsCloudTrash(home.appendingPathComponent(relative))
    }

    @Test("iCloud Drive : un document oui, le dossier lui-même ou un élément caché non")
    func iCloudDrive() {
        #expect(allows("Library/Mobile Documents/com~apple~CloudDocs/Business/facture.pdf"))
        #expect(allows("Library/Mobile Documents/com~apple~CloudDocs/facture.pdf"))
        #expect(!allows("Library/Mobile Documents/com~apple~CloudDocs"))
        #expect(!allows("Library/Mobile Documents"))
        #expect(!allows("Library/Mobile Documents/.Trash/facture.pdf"))
        #expect(!allows("Library/Mobile Documents/com~apple~CloudDocs/.Trash/facture.pdf"))
        // La garde ordinaire, elle, refuse toujours tout `Mobile Documents`.
        #expect(!guardian.allows(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/facture.pdf")))
    }

    @Test("Le dossier d'une application : ses Documents, jamais ses données ni un coffre")
    func appContainers() {
        #expect(allows("Library/Mobile Documents/com~apple~Pages/Documents/Rapport.pages"))
        #expect(!allows("Library/Mobile Documents/com~apple~Pages/Documents"))
        #expect(!allows("Library/Mobile Documents/com~apple~Pages"))
        #expect(!allows("Library/Mobile Documents/com~apple~mail/Data/réglages.plist"))
        #expect(!allows("Library/Mobile Documents/2BUA8C4S2C~com~agilebits~onepassword/Documents/coffre.opvault"))
    }

    @Test("Un File Provider : jamais la racine du compte ni « Mon Drive » entier")
    func fileProviders() {
        #expect(allows("Library/CloudStorage/GoogleDrive-a@b.fr/Mon Drive/facture.pdf"))
        #expect(allows("Library/CloudStorage/Dropbox/facture.pdf"))
        #expect(!allows("Library/CloudStorage/GoogleDrive-a@b.fr/Mon Drive"))
        #expect(!allows("Library/CloudStorage/GoogleDrive-a@b.fr/Drive partagés"))
        #expect(!allows("Library/CloudStorage/GoogleDrive-a@b.fr"))
        #expect(!allows("Library/CloudStorage"))
        #expect(!allows("Library/CloudStorage/GoogleDrive-a@b.fr/.Trash/facture.pdf"))
        #expect(!guardian.allowsCloudTrash(URL(fileURLWithPath: "/Home/test/Library/CloudStorage/../Caches/x")))
    }

    @Test("Le Bureau et les Documents synchronisés : la garde ordinaire")
    func syncedHomeFolders() {
        #expect(allows("Desktop/capture.png"))
        #expect(allows("Documents/Factures/2019.pdf"))
        #expect(!allows("Desktop"))
        #expect(!allows("Library/Keychains/login.keychain-db"))
    }

    @Test("Un lien au milieu du chemin ne fait pas sortir un fichier du nuage")
    func symlinkInTheMiddle() throws {
        let bench = try CloudBench()
        let keychains = bench.home.appendingPathComponent("Library/Keychains")
        try bench.folder(keychains)
        try bench.folder(bench.drive)
        try FileManager.default.createSymbolicLink(at: bench.drive.appendingPathComponent("raccourci"),
                                                   withDestinationURL: keychains)
        try bench.file(keychains.appendingPathComponent("login.keychain-db"))

        let guardian = PathGuard(home: bench.home)

        #expect(!guardian.allowsCloudTrash(bench.drive.appendingPathComponent("raccourci/login.keychain-db")))
    }
}

@Suite("Mettre à la corbeille un fichier d'un nuage passe par OustClean, revalidé")
struct CloudTrashEngineTests {

    /// Le banc n'est pas un vrai cloud : macOS n'en identifierait aucun fichier.
    /// La connexion est donc posée par le test.
    func engine(_ bench: CloudBench, connection: CloudConnection = .connected) -> CleanupEngine {
        CleanupEngine(trasher: FolderTrasher(folder: bench.trash), history: nil, pathGuard: PathGuard(home: bench.home),
                      processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil },
                      deleteSnapshots: { _ in false }, runningApps: { [] },
                      cloudConnection: { _, _, _ in connection })
    }

    func item(_ url: URL, bench: CloudBench) -> CleanupItem {
        var info = stat()
        lstat(url.path, &info)
        let file = CloudEntry(url: url, accountID: "icloud", folder: [], cloudSize: Int64(info.st_size),
                             localSize: Int64(info.st_blocks) * 512, freeable: Int64(info.st_blocks) * 512,
                             modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                             fileID: UInt64(info.st_ino), isDataless: false)
        return file.cleanupItem(account: nil, guard: PathGuard(home: bench.home))
    }

    func run(_ items: [CleanupItem], bench: CloudBench, connection: CloudConnection = .connected) async -> CleanupReport? {
        var report: CleanupReport?
        for await event in engine(bench, connection: connection).run(items) {
            if case .finished(let final) = event { report = final }
        }
        return report
    }

    @Test("Un document d'iCloud Drive part à la corbeille, avec son emplacement d'origine")
    func trashesADocument() async throws {
        let bench = try CloudBench()
        let facture = try bench.file(bench.drive.appendingPathComponent("Business/facture.pdf"), bytes: 40_000)

        let report = await run([item(facture, bench: bench)], bench: bench)
        let outcome = try #require(report?.outcomes.first)

        #expect(outcome.result == .trashed)
        #expect(outcome.method == .trashFromCloud)
        #expect(!FileManager.default.fileExists(atPath: facture.path))
        #expect(outcome.trashedTo.count == 1 && FileManager.default.fileExists(atPath: outcome.trashedTo[0]))
        // Rien n'est rendu tant que la corbeille du Mac n'est pas vidée.
        #expect(report?.expectedNow == 0)
    }

    @Test("Un livre en paquet, lu par le parcours, part en entier et sans fausse alerte")
    func trashesAPackageFromTheListing() async throws {
        let bench = try CloudBench()
        let book = bench.drive.appendingPathComponent("Livres/Roman.epub")
        try bench.file(book.appendingPathComponent("OEBPS/chapitre1.xhtml"), bytes: 20_000,
                       modified: Date(timeIntervalSinceNow: -86_400 * 30))
        try bench.file(book.appendingPathComponent("mimetype"), bytes: 20)
        let account = CloudAccount(id: "icloud", service: .iCloudDrive, account: nil, roots: [CloudRoot(url: bench.drive)])
        let inventory = CloudInventory.scan([account])
        let entry = try #require(inventory.files.first)
        #expect(inventory.files.count == 1 && entry.isPackage && entry.cloudSize == 20_020)

        let report = await run([entry.cleanupItem(account: account, guard: PathGuard(home: bench.home))], bench: bench)

        #expect(report?.outcomes.first?.result == .trashed)
        #expect(!FileManager.default.fileExists(atPath: book.path))
    }

    @Test("Modifié depuis l'analyse : laissé en place")
    func changedSinceScan() async throws {
        let bench = try CloudBench()
        let facture = try bench.file(bench.drive.appendingPathComponent("facture.pdf"),
                                     modified: Date(timeIntervalSinceNow: -86_400 * 400))
        let shown = item(facture, bench: bench)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: facture.path)

        let report = await run([shown], bench: bench)

        #expect(report?.outcomes.first?.result == .skipped(.changedSinceScan))
        #expect(FileManager.default.fileExists(atPath: facture.path))
    }

    @Test("Les données d'une application dans iCloud : refusées au dernier moment")
    func refusesAppData() async throws {
        let bench = try CloudBench()
        let data = try bench.file(bench.home.appendingPathComponent("Library/Mobile Documents/com~apple~mail/Data/x.plist"))
        var shown = item(data, bench: bench)
        // Même si l'élément arrivait sans sa protection, le moteur refuse.
        shown.protections = []
        shown.safety = .review

        let report = await run([shown], bench: bench)

        #expect(report?.outcomes.first?.result == .skipped(.refusedByGuard))
        #expect(FileManager.default.fileExists(atPath: data.path))
    }
}
