import Darwin
import Foundation
import Testing
import OustClean
import OustCore
@testable import OustSafety
@testable import OustClouds

/// L'essai réel du 18/10/2026 : un compte Google Drive retiré de l'app était
/// montré comme vivant, et le Finder, au moment de supprimer, bloquait le
/// nettoyage sur une alerte. Un compte déconnecté reste listé, rien n'y part.
@Suite("Un compte du cloud déconnecté : listé, rien à cocher, écarté sans Finder")
struct CloudConnectionTests {

    @Test("L'app d'une extension : son identifiant commence celui de l'extension")
    func hostApp() {
        let provider = "com.google.drivefs.fpext"
        #expect(CloudConnectionCheck.isHostRunning(provider: provider, running: ["com.google.drivefs", "com.apple.finder"]))
        #expect(!CloudConnectionCheck.isHostRunning(provider: provider, running: ["com.apple.finder"]))
        // Un début de nom ne suffit pas : il faut tout un composant. Ni
        // l'extension elle-même, quand macOS la lance sans son app.
        #expect(!CloudConnectionCheck.isHostRunning(provider: provider, running: ["com.google.drive", provider]))
        #expect(!CloudConnectionCheck.isHostRunning(provider: provider, running: [""]))
    }

    @Test("Le File Provider d'un compte se lit dans l'attribut de son dossier")
    func providerAttribute() throws {
        #expect(CloudConnectionCheck.provider(fromDomainAttribute: "com.google.drivefs.fpext/gdrive-108259002140719301520")
                == "com.google.drivefs.fpext")
        #expect(CloudConnectionCheck.provider(fromDomainAttribute: "com.oplus.devicespace.extension/DeviceSpace")
                == "com.oplus.devicespace.extension")
        #expect(CloudConnectionCheck.provider(fromDomainAttribute: "sans-domaine") == nil)
        #expect(CloudConnectionCheck.provider(fromDomainAttribute: "/gdrive-1") == nil)

        // Seul macOS pose l'attribut : un dossier ordinaire n'en a pas, et ne
        // peut pas s'en donner un.
        let bench = try CloudBench()
        let account = bench.storage.appendingPathComponent("GoogleDrive-a@b.fr", isDirectory: true)
        try bench.folder(account)
        #expect(CloudConnectionCheck.providerID(of: account) == nil)
        let value = Array("com.google.drivefs.fpext/gdrive-1".utf8)
        #expect(setxattr(account.path, "com.apple.file-provider-domain-id", value, value.count, 0, XATTR_NOFOLLOW) != 0)
        #expect(CloudConnectionCheck.providerID(of: account) == nil)
    }

    @Test("Le compte d'un fichier : son dossier sous CloudStorage, rien pour iCloud Drive")
    func accountFolder() {
        let guardian = PathGuard(home: URL(fileURLWithPath: "/Home/test"))
        let file = URL(fileURLWithPath: "/Home/test/Library/CloudStorage/GoogleDrive-a@b.fr/Mon Drive/facture.pdf")
        #expect(guardian.fileProviderAccount(of: file)?.path == "/Home/test/Library/CloudStorage/GoogleDrive-a@b.fr")
        let drive = URL(fileURLWithPath: "/Home/test/Library/Mobile Documents/com~apple~CloudDocs/facture.pdf")
        #expect(guardian.fileProviderAccount(of: drive) == nil)
        #expect(guardian.fileProviderAccount(of: URL(fileURLWithPath: "/Home/test/Desktop/capture.png")) == nil)
        #expect(guardian.fileProviderAccount(of: URL(fileURLWithPath: "/Home/test/Library/CloudStorage")) == nil)
    }

    @Test("Hors d'un cloud, macOS n'identifie rien : dans le doute, refusé")
    func outsideAnyCloud() async throws {
        let bench = try CloudBench()
        let file = try bench.file(bench.root.appendingPathComponent("facture.pdf"))

        #expect(await CloudConnectionCheck.identify(file) == .disconnected)
        // Pas d'attribut sur le dossier du compte : pas de service connu.
        #expect(await CloudConnectionCheck.connection(of: file, accountRoot: bench.root, running: []) == .disconnected)
    }

    @Test("Chaque compte reçoit son état ; iCloud Drive n'a pas d'app à ouvrir")
    func accountsAreChecked() async {
        let drive = CloudAccount(id: "icloud", service: .iCloudDrive, account: nil,
                                 roots: [CloudRoot(url: URL(fileURLWithPath: "/h/Library/Mobile Documents/com~apple~CloudDocs"))])
        let google = CloudAccount(id: "g", service: .googleDrive, account: "a@b.fr",
                                  roots: [CloudRoot(url: URL(fileURLWithPath: "/h/Library/CloudStorage/GoogleDrive-a@b.fr"))])
        let checked = await CloudAccounts.connections(of: [drive, google], running: ["com.google.drivefs"]) { _, root, running in
            #expect(running == ["com.google.drivefs"])
            return root == nil ? .connected : .appClosed
        }

        #expect(checked.map(\.connection) == [.connected, .appClosed])
    }

    @Test("Les fichiers d'un compte déconnecté restent listés, mais verrouillés")
    func itemsAreLocked() {
        let guardian = PathGuard(home: URL(fileURLWithPath: "/Home/test"))
        let url = URL(fileURLWithPath: "/Home/test/Library/CloudStorage/GoogleDrive-a@b.fr/Mon Drive/facture.pdf")
        let file = CloudEntry(url: url, accountID: "g", folder: ["Mon Drive"], cloudSize: 1_300_000, localSize: 0,
                              freeable: 0, modified: nil, fileID: 1, isDataless: true)
        func account(_ connection: CloudConnection) -> CloudAccount {
            CloudAccount(id: "g", service: .googleDrive, account: "a@b.fr",
                         roots: [CloudRoot(url: url.deletingLastPathComponent().deletingLastPathComponent())],
                         connection: connection)
        }

        #expect(file.cleanupItem(account: account(.connected), guard: guardian).isSelectable)
        let closed = file.cleanupItem(account: account(.appClosed), guard: guardian)
        #expect(!closed.isSelectable && closed.protections == [.cloudAppClosed(name: "Google Drive")])
        let dead = file.cleanupItem(account: account(.disconnected), guard: guardian)
        #expect(!dead.isSelectable && dead.protections == [.cloudDisconnected])
    }
}

@Suite("Déconnecté depuis l'analyse : écarté au dernier moment, sans passer par le Finder")
struct CloudConnectionEngineTests {

    func run(_ connection: CloudConnection, bench: CloudBench, file: URL) async throws -> (CleanupOutcome, Bool) {
        var info = stat()
        lstat(file.path, &info)
        let entry = CloudEntry(url: file, accountID: "g", folder: ["Mon Drive"], cloudSize: Int64(info.st_size),
                               localSize: Int64(info.st_blocks) * 512, freeable: Int64(info.st_blocks) * 512,
                               modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                               fileID: UInt64(info.st_ino), isDataless: false)
        // Montré relié : c'est entre l'analyse et le nettoyage que tout change.
        let item = entry.cleanupItem(account: nil, guard: PathGuard(home: bench.home))
        let asked = Asked()
        let engine = CleanupEngine(trasher: FolderTrasher(folder: bench.trash), history: nil,
                                   pathGuard: PathGuard(home: bench.home), processes: { ProcessSnapshot(processes: []) },
                                   capacity: { _ in nil }, deleteSnapshots: { _ in false },
                                   runningApps: { ["com.apple.finder"] },
                                   cloudConnection: { url, root, running in
                                       asked.record(url: url, root: root, running: running)
                                       return connection
                                   })
        var report: CleanupReport?
        for await event in engine.run([item]) {
            if case .finished(let final) = event { report = final }
        }
        let outcome = try #require(report?.outcomes.first)
        #expect(asked.calls == [Asked.Call(url: file, root: bench.storage.appendingPathComponent("GoogleDrive-a@b.fr"),
                                           running: ["com.apple.finder"])])
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: bench.trash.path))?.isEmpty == false
        return (outcome, trashed)
    }

    @Test("L'app du service fermée : laissé en place, la corbeille jamais appelée")
    func appClosed() async throws {
        let bench = try CloudBench()
        let file = try bench.file(bench.storage.appendingPathComponent("GoogleDrive-a@b.fr/Mon Drive/facture.pdf"))

        let (outcome, trashed) = try await run(.appClosed, bench: bench, file: file)

        #expect(outcome.result == .skipped(.nowProtected(.cloudDisconnected)))
        #expect(!trashed && FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Le compte n'est plus relié : laissé en place, la corbeille jamais appelée")
    func disconnected() async throws {
        let bench = try CloudBench()
        let file = try bench.file(bench.storage.appendingPathComponent("GoogleDrive-a@b.fr/Mon Drive/facture.pdf"))

        let (outcome, trashed) = try await run(.disconnected, bench: bench, file: file)

        #expect(outcome.result == .skipped(.nowProtected(.cloudDisconnected)))
        #expect(!trashed && FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Relié : il part, comme avant")
    func connected() async throws {
        let bench = try CloudBench()
        let file = try bench.file(bench.storage.appendingPathComponent("GoogleDrive-a@b.fr/Mon Drive/facture.pdf"))

        let (outcome, trashed) = try await run(.connected, bench: bench, file: file)

        #expect(outcome.result == .trashed)
        #expect(trashed && !FileManager.default.fileExists(atPath: file.path))
    }
}

/// Ce que le moteur a demandé, d'une tâche à l'autre.
private final class Asked: @unchecked Sendable {
    struct Call: Equatable {
        let url: URL
        let root: URL?
        let running: Set<String>
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] { lock.withLock { recorded } }

    func record(url: URL, root: URL?, running: Set<String>) {
        lock.withLock { recorded.append(Call(url: url, root: root, running: running)) }
    }
}

@Suite("Chercher un fichier du cloud par son nom ou son dossier")
struct CloudSearchTests {
    let files = [
        CloudEntry(url: URL(fileURLWithPath: "/c/Business/Comptes/Facture 2019.pdf"), accountID: "icloud",
                   folder: ["Business", "Comptes"], cloudSize: 1_200_000, localSize: 0, freeable: 0,
                   modified: nil, fileID: 1, isDataless: true),
        CloudEntry(url: URL(fileURLWithPath: "/c/Téléchargements/Oust test corbeille.txt"), accountID: "icloud",
                   folder: ["Téléchargements"], cloudSize: 1_200_000, localSize: 0, freeable: 0,
                   modified: nil, fileID: 2, isDataless: true),
    ]

    func found(_ query: String) -> [String] {
        let search = CloudSearch(files)
        guard let filter = search.filter(query) else { return files.map(\.name) }
        return files.filter(filter).map(\.name)
    }

    @Test("Par le nom, par le dossier, sans casse ni accents, chaque mot")
    func matches() {
        #expect(found("oust test") == ["Oust test corbeille.txt"])
        #expect(found("telechargements") == ["Oust test corbeille.txt"])
        #expect(found("comptes facture") == ["Facture 2019.pdf"])
        #expect(found("facture 2020").isEmpty)
    }

    @Test("Une recherche vide ne filtre rien")
    func emptyQuery() {
        #expect(CloudSearch(files).filter("  ") == nil)
    }
}
