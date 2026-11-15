import Darwin
import Foundation
import Testing
@testable import OustUninstall
import OustClean
import OustCore
import OustSafety

/// Un faux Mac dans un dossier temporaire : des applications, un dossier
/// personnel et sa bibliothèque. Rien ne touche aux vraies (RULES.md, règle 8).
final class FakeMac {
    let root: URL
    var applications: URL { root.appendingPathComponent("Applications") }
    var home: URL { root.appendingPathComponent("maison") }
    var library: URL { home.appendingPathComponent("Library") }
    var trash: URL { root.appendingPathComponent("_corbeille") }
    var historyFolder: URL { root.appendingPathComponent("_historique") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-uninstall-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Un paquet `.app` minimal : un Info.plist, un exécutable, et ce qu'on y embarque.
    @discardableResult
    func app(_ relative: String, id: String?, name: String? = nil,
             embedded: [(path: String, id: String, info: [String: Any])] = []) throws -> URL {
        let url = applications.appendingPathComponent(relative)
        var info: [String: Any] = ["CFBundleName": name ?? url.deletingPathExtension().lastPathComponent,
                                   "CFBundleShortVersionString": "1.0"]
        if let id { info["CFBundleIdentifier"] = id }
        try write(info, to: url.appendingPathComponent("Contents/Info.plist"))
        try data("binaire", to: url.appendingPathComponent("Contents/MacOS/\(url.deletingPathExtension().lastPathComponent)"))
        for bundle in embedded {
            var nested = bundle.info
            nested["CFBundleIdentifier"] = bundle.id
            try write(nested, to: url.appendingPathComponent("Contents/\(bundle.path)/Contents/Info.plist"))
        }
        return url
    }

    @discardableResult
    func libraryItem(_ relative: String, directory: Bool = false, bytes: Int = 4_096) throws -> URL {
        let url = library.appendingPathComponent(relative)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url.appendingPathComponent("contenu.bin"))
        } else {
            try data(String(repeating: "x", count: bytes), to: url)
        }
        return url
    }

    func container(_ folder: String, name: String, identifier: String?) throws -> URL {
        let url = try libraryItem("\(folder)/\(name)", directory: true)
        if let identifier {
            try write(["MCMMetadataIdentifier": identifier],
                      to: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        }
        return url
    }

    func launchAgent(_ name: String, program: String) throws {
        try write(["Label": name, "ProgramArguments": [program, "--background"]],
                  to: library.appendingPathComponent("LaunchAgents/\(name).plist"))
    }

    func write(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func data(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func installed(groups: [String: [String]] = [:]) -> [InstalledApp] {
        AppCatalog.installedApps(in: [applications], entitlements: { groups[$0.lastPathComponent] ?? [] },
                                 lastUsed: { _ in nil })
    }

    func engine(processes: [ActiveProcess] = []) -> CleanupEngine {
        let snapshot = ProcessSnapshot(processes: processes)
        return CleanupEngine(trasher: FolderTrasher(folder: trash), history: HistoryStore(directory: historyFolder),
                             pathGuard: PathGuard(home: home), processes: { snapshot }, capacity: { _ in nil },
                             deleteSnapshots: { _ in false }, allowsPathBasedRemoval: true)
    }
}

@Suite("Le désinstalleur ne prend que ce qui appartient à l'application")
struct UninstallTests {

    @Test("Seules les dates connues strictement antérieures au seuil sont retenues")
    func unusedAppsRequireAKnownDateBeforeTheCutoff() throws {
        let mac = try FakeMac()
        let cutoff = Date(timeIntervalSince1970: 1_750_000_000)
        let dates: [String: Date] = [
            "Ancienne.app": cutoff.addingTimeInterval(-1),
            "Limite.app": cutoff,
            "Récente.app": cutoff.addingTimeInterval(1),
        ]
        for name in ["Ancienne", "Limite", "Récente", "Inconnue"] {
            try mac.app("\(name).app", id: "test.oust.\(name)")
        }
        let apps = AppCatalog.installedApps(in: [mac.applications], entitlements: { _ in [] },
                                           lastUsed: { dates[$0.lastPathComponent] })
        #expect(apps.count == 4)
        #expect(apps.filter { $0.wasLastOpened(before: cutoff) }.map(\.url.lastPathComponent) == ["Ancienne.app"])
    }

    @Test("Les applications de premier niveau et d'un sous-dossier, pas leurs assistants")
    func bundles() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.foo.app", embedded: [("Helpers/Assistant.app", "com.foo.app.helper", [:])])
        try mac.app("Suite Bar/Bar.app", id: "com.bar.app")
        try mac.app("Utilitaires/Profond/Cache.app", id: "com.deep.app")

        let names = AppCatalog.bundles(in: [mac.applications]).map(\.lastPathComponent)

        #expect(names == ["Bar.app", "Foo.app"])
        let foo = try #require(mac.installed().first { $0.bundleID == "com.foo.app" })
        #expect(foo.embeddedIDs == ["com.foo.app.helper"])
        #expect(foo.isUninstallable)
    }

    @Test("Apple, mots de passe, VPN, extension système, sans identifiant : jamais")
    func exclusions() throws {
        let mac = try FakeMac()
        try mac.app("Pages.app", id: "com.apple.iWork.Pages")
        try mac.app("1Password.app", id: "com.1password.1password")
        try mac.app("Coffre.app", id: "fr.exemple.coffre", embedded: [
            ("PlugIns/Remplir.appex", "fr.exemple.coffre.autofill",
             ["NSExtension": ["NSExtensionPointIdentifier": "com.apple.authentication-services-credential-provider-ui"]]),
        ])
        try mac.app("Tunnel.app", id: "fr.exemple.tunnel", embedded: [
            ("PlugIns/Paquets.appex", "fr.exemple.tunnel.packet",
             ["NSExtension": ["NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"]]),
        ])
        try mac.app("NordVPN.app", id: "fr.exemple.nord")
        try mac.app("Gardien.app", id: "fr.exemple.gardien", embedded: [
            ("Library/SystemExtensions/fr.exemple.gardien.es.systemextension", "fr.exemple.gardien.es", [:]),
        ])
        try mac.app("Anonyme.app", id: nil)
        try mac.app("OmniOutliner.app", id: "com.omnigroup.OmniOutliner5")

        let reasons = Dictionary(uniqueKeysWithValues: mac.installed().map { ($0.url.lastPathComponent, $0.exclusion) })

        #expect(reasons["Pages.app"] == .apple)
        #expect(reasons["1Password.app"] == .passwordManager)
        #expect(reasons["Coffre.app"] == .passwordManager)
        #expect(reasons["Tunnel.app"] == .vpn)
        #expect(reasons["NordVPN.app"] == .vpn)
        #expect(reasons["Gardien.app"] == .systemExtension)
        #expect(reasons["Anonyme.app"] == .unidentified)
        #expect(reasons["OmniOutliner.app"] == .some(nil))
        // Une application exclue ne propose aucun reste.
        let pages = try #require(mac.installed().first { $0.bundleID == "com.apple.iWork.Pages" })
        try mac.libraryItem("Caches/com.apple.iWork.Pages", directory: true)
        #expect(LeftoverFinder.leftovers(of: pages, among: mac.installed(), home: mac.home).isEmpty)
    }

    @Test("Correspondance stricte : identifiant, nom unique, conteneur, groupe, agent")
    func strictLeftovers() throws {
        let mac = try FakeMac()
        let bundle = try mac.app("Foo.app", id: "com.foo.app",
                                 embedded: [("PlugIns/Partage.appex", "com.foo.app.share", [:])])
        try mac.app("Voisin.app", id: "com.voisin.app")

        // Ce qui appartient à Foo.
        try mac.libraryItem("Application Support/com.foo.app", directory: true)
        try mac.libraryItem("Application Support/Foo", directory: true)
        try mac.libraryItem("Caches/com.foo.app", directory: true)
        try mac.libraryItem("Preferences/com.foo.app.plist")
        try mac.libraryItem("Preferences/com.foo.app.share.plist")
        try mac.libraryItem("Preferences/ByHost/com.foo.app.0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.plist")
        try mac.libraryItem("Saved Application State/com.foo.app.savedState", directory: true)
        try mac.libraryItem("HTTPStorages/com.foo.app", directory: true)
        _ = try mac.container("Containers", name: "com.foo.app", identifier: "com.foo.app")
        _ = try mac.container("Group Containers", name: "TEAM.group.foo", identifier: "TEAM.group.foo")
        try mac.launchAgent("com.foo.updater", program: bundle.appendingPathComponent("Contents/MacOS/Foo").path)

        // Ce qui lui ressemble sans lui appartenir.
        try mac.libraryItem("Application Support/com.foo.app.backup", directory: true)
        try mac.libraryItem("Application Support/Foo Pro", directory: true)
        try mac.libraryItem("Caches/com.foo", directory: true)
        try mac.libraryItem("Preferences/com.foo.app.plist.bak")
        try mac.libraryItem("Preferences/ByHost/com.foo.app.pas-un-identifiant.plist")
        _ = try mac.container("Containers", name: "com.foo.app.share", identifier: "com.autre.app")
        try mac.launchAgent("com.voisin.agent", program: "/usr/local/bin/voisin")
        try mac.libraryItem("Caches/com.voisin.app", directory: true)

        let apps = mac.installed(groups: ["Foo.app": ["TEAM.group.foo"]])
        let foo = try #require(apps.first { $0.bundleID == "com.foo.app" })
        let found = LeftoverFinder.leftovers(of: foo, among: apps, home: mac.home)
        let relative = Set(found.map { String($0.url.path.dropFirst(mac.library.path.count + 1)) })

        #expect(relative == [
            "Application Support/com.foo.app", "Application Support/Foo", "Caches/com.foo.app",
            "Preferences/com.foo.app.plist", "Preferences/com.foo.app.share.plist",
            "Preferences/ByHost/com.foo.app.0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.plist",
            "Saved Application State/com.foo.app.savedState", "HTTPStorages/com.foo.app",
            "Containers/com.foo.app", "Group Containers/TEAM.group.foo", "LaunchAgents/com.foo.updater.plist",
        ])
        let byName = try #require(found.first { $0.url.lastPathComponent == "Foo" })
        #expect(byName.match == .name)
        #expect(byName.safety == .review)
        #expect(!byName.isPreselected)
        // Le régénérable est coché d'office, le personnel jamais (RULES.md, règle 4).
        let preselected = Set(found.filter(\.isPreselected).map(\.kind))
        #expect(preselected == [.caches, .savedState, .httpStorage, .launchAgent])
    }

    @Test("Un second exemplaire, un groupe partagé : protégés, pas proposés")
    func sharedWithAnotherApp() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.foo.app")
        try mac.app("Ancien/Foo.app", id: "com.foo.app")
        try mac.app("Bar.app", id: "com.bar.app")
        try mac.libraryItem("Caches/com.foo.app", directory: true)
        _ = try mac.container("Group Containers", name: "TEAM.suite", identifier: "TEAM.suite")

        let apps = mac.installed(groups: ["Foo.app": ["TEAM.suite"], "Bar.app": ["TEAM.suite"]])
        // `contentsOfDirectory` rend `/private/var/…`, le dossier temporaire `/var/…`.
        let foo = try #require(apps.first {
            $0.url.resolvingSymlinksInPath().path == mac.applications.appendingPathComponent("Foo.app").path
        })
        let found = LeftoverFinder.leftovers(of: foo, among: apps, home: mac.home)

        #expect(found.count == 2)
        #expect(found.allSatisfy { if case .usedByAnotherApp = $0.protection { true } else { false } })
        #expect(found.allSatisfy { !$0.isPreselected })
        #expect(found.allSatisfy { !$0.cleanupItem(for: foo).isSelectable })
    }

    @Test("Un nom porté par deux applications ne désigne plus personne")
    func ambiguousNames() throws {
        let mac = try FakeMac()
        try mac.app("Notes.app", id: "fr.un.notes")
        try mac.app("Autres/Notes.app", id: "fr.deux.notes")
        try mac.libraryItem("Application Support/Notes", directory: true)

        let apps = mac.installed()
        for app in apps {
            #expect(app.names.isEmpty)
            #expect(LeftoverFinder.leftovers(of: app, among: apps, home: mac.home).isEmpty)
        }
    }

    @Test("Un conteneur dont l'appartenance est illisible est montré, pas touché")
    func unreadableContainer() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.foo.app")
        _ = try mac.container("Containers", name: "com.foo.app", identifier: nil)

        let apps = mac.installed()
        let found = LeftoverFinder.leftovers(of: apps[0], among: apps, home: mac.home)

        #expect(found.count == 1)
        #expect(found.first?.protection == .needsFullDiskAccess)
    }

    @Test("Désinstaller : l'application et ses restes vont à la corbeille du Mac, au journal")
    func uninstallEndToEnd() async throws {
        let mac = try FakeMac()
        let bundle = try mac.app("Foo.app", id: "com.foo.app")
        let cache = try mac.libraryItem("Caches/com.foo.app", directory: true)
        let apps = mac.installed()
        let foo = apps[0]
        let leftovers = await LeftoverFinder.measured(LeftoverFinder.leftovers(of: foo, among: apps, home: mac.home))
        let items = [foo.cleanupItem()] + leftovers.map { $0.cleanupItem(for: foo) }

        var report: CleanupReport?
        for await event in mac.engine().run(items) {
            if case .finished(let final) = event { report = final }
        }

        #expect(report?.outcomes.map(\.result) == [.trashed, .trashed])
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        let history = await HistoryStore(directory: mac.historyFolder).load()
        #expect(Set(history.map(\.category)) == [.applications])
        #expect(history.allSatisfy { $0.trashedTo.count == 1 })
    }

    @Test("Une application ouverte n'est pas désinstallée, ses restes non plus")
    func runningAppIsKept() async throws {
        let mac = try FakeMac()
        let bundle = try mac.app("Foo.app", id: "com.foo.app")
        let cache = try mac.libraryItem("Caches/com.foo.app", directory: true)
        let apps = mac.installed()
        let foo = apps[0]
        let leftovers = LeftoverFinder.leftovers(of: foo, among: apps, home: mac.home)
        let items = [foo.cleanupItem()] + leftovers.map { $0.cleanupItem(for: foo) }
        let running = ActiveProcess(pid: 77, name: "Foo", workingDirectory: "",
                                    executablePath: bundle.appendingPathComponent("Contents/MacOS/Foo").path)

        var report: CleanupReport?
        for await event in mac.engine(processes: [running]).run(items) {
            if case .finished(let final) = event { report = final }
        }

        #expect(report?.outcomes.map(\.result) == [
            .skipped(.nowProtected(.appRunning(name: "Foo"))), .skipped(.nowProtected(.appRunning(name: "Foo"))),
        ])
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }
}
