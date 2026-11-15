import Darwin
import Foundation
import Testing
@testable import OustUninstall
import OustClean
import OustCore
import OustSafety

/// Les restes d'applications qui ne sont plus là, sur un faux Mac
/// (`FakeMac`, dans un dossier temporaire : RULES.md, règle 8).
@Suite("Les restes d'applications disparues, et rien d'autre")
struct OrphanTests {

    /// Des sources réduites au faux Mac : ses applications, et ce que le test y ajoute.
    func sources(_ mac: FakeMac, registered: [String: [URL]] = [:], teams: [String: String] = [:],
                 running: [String] = [], canReadContainers: Bool = true) -> OrphanSources {
        OrphanSources(
            appRoots: [mac.applications],
            pluginRoots: [mac.root.appendingPathComponent("Modules")],
            helperRoots: [mac.library.appendingPathComponent("Application Support"),
                          mac.root.appendingPathComponent("Partagé")],
            labelRoots: [mac.root.appendingPathComponent("LaunchDaemons")],
            registeredApps: { registered[$0] ?? [] },
            signature: { SigningFacts(teamID: teams[$0.lastPathComponent], groups: []) },
            runningExecutables: { running },
            canReadContainers: canReadContainers
        )
    }

    func orphans(_ mac: FakeMac, groups: [String: [String]] = [:], registered: [String: [URL]] = [:],
                 teams: [String: String] = [:], running: [String] = [],
                 canReadContainers: Bool = true) -> [OrphanGroup] {
        OrphanFinder.orphans(home: mac.home, installed: mac.installed(groups: groups),
                             sources: sources(mac, registered: registered, teams: teams, running: running,
                                              canReadContainers: canReadContainers))
    }

    func relative(_ mac: FakeMac, _ groups: [OrphanGroup]) -> Set<String> {
        Set(groups.flatMap(\.leftovers).map { String($0.url.path.dropFirst(mac.library.path.count + 1)) })
    }

    /// Un paquet hors du dossier Applications du faux Mac.
    @discardableResult
    func bundle(_ mac: FakeMac, _ relative: String, id: String, flat: Bool = false) throws -> URL {
        let url = mac.root.appendingPathComponent(relative)
        try mac.write(["CFBundleIdentifier": id], to: url.appendingPathComponent(flat ? "Info.plist" : "Contents/Info.plist"))
        return url
    }

    @Test("Tout ce qu'une application disparue a laissé, regroupé, et rien de celle qui reste")
    func vanishedApp() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.foo.app", embedded: [("PlugIns/Partage.appex", "com.foo.app.share", [:])])

        // Ce que Bar a laissé en partant.
        try mac.libraryItem("Application Support/com.bar.app", directory: true)
        try mac.libraryItem("Preferences/com.bar.app.plist")
        try mac.libraryItem("Preferences/ByHost/com.bar.app.0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.plist")
        try mac.libraryItem("Saved Application State/com.bar.app.savedState", directory: true)
        try mac.libraryItem("HTTPStorages/com.bar.app", directory: true)
        try mac.libraryItem("HTTPStorages/com.bar.app.binarycookies")
        try mac.libraryItem("WebKit/com.bar.app", directory: true)
        try mac.libraryItem("Logs/com.bar.app", directory: true)
        _ = try mac.container("Containers", name: "com.bar.app", identifier: "com.bar.app")
        _ = try mac.container("Containers", name: "com.bar.app.widgets", identifier: "com.bar.app.widgets")
        _ = try mac.container("Group Containers", name: "ABCDE12345.com.bar.app.shared",
                              identifier: "ABCDE12345.com.bar.app.shared")
        // Son cache : déjà proposé par « Caches d'applications », pas deux fois.
        try mac.libraryItem("Caches/com.bar.app", directory: true)

        // Ce qui appartient à Foo, toujours installée.
        try mac.libraryItem("Application Support/com.foo.app", directory: true)
        try mac.libraryItem("Preferences/com.foo.app.plist")
        _ = try mac.container("Containers", name: "com.foo.app.share", identifier: "com.foo.app.share")
        _ = try mac.container("Group Containers", name: "group.com.foo.shared", identifier: "group.com.foo.shared")

        let found = orphans(mac, groups: ["Foo.app": ["group.com.foo.shared"]])

        #expect(found.map(\.identifier) == ["com.bar.app"])
        #expect(relative(mac, found) == [
            "Application Support/com.bar.app", "Preferences/com.bar.app.plist",
            "Preferences/ByHost/com.bar.app.0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.plist",
            "Saved Application State/com.bar.app.savedState", "HTTPStorages/com.bar.app",
            "HTTPStorages/com.bar.app.binarycookies", "WebKit/com.bar.app", "Logs/com.bar.app",
            "Containers/com.bar.app", "Containers/com.bar.app.widgets", "Group Containers/ABCDE12345.com.bar.app.shared",
        ])
        let group = try #require(found.first)
        let items = group.leftovers.map { $0.cleanupItem(in: group) }
        // Les journaux restent visibles avec les autres restes et protégés.
        let log = try #require(items.first { $0.paths.first?.deletingLastPathComponent().lastPathComponent == "Logs" })
        #expect(log.safety == .protected && log.protections.contains(.unknownState) && !log.isSelectable)
        #expect(items.allSatisfy { $0.method == .trash && $0.category == .appLeftovers })
        #expect(items.allSatisfy { !PreselectionPolicy().preselects($0) })
        #expect(items.filter { $0.id != log.id }.allSatisfy { $0.safety == .review && $0.isSelectable })
    }

    @Test("Un nom, un jeton, une bibliothèque partagée, Apple, des secrets : jamais")
    func notApplicationIdentifiers() throws {
        let mac = try FakeMac()
        try mac.libraryItem("Application Support/Bar", directory: true)
        try mac.libraryItem("Application Support/com.bar", directory: true)
        try mac.libraryItem("Preferences/org.cups.PrintingPrefs.plist")
        try mac.libraryItem("Preferences/com.segment.storage.ewjp2RGpYO4hHSErQ3lBOOjnR0YqolJo.plist")
        try mac.libraryItem("Preferences/com.bar.checks.0D00530D-F4FD-4801-8EA7-1321DAE79397.plist")
        try mac.libraryItem("Preferences/Acme.GuidanceChecks.app.plist")
        try mac.libraryItem("Preferences/group.com.bar.app.plist")
        try mac.libraryItem("Preferences/com.apple.Bar.plist")
        try mac.libraryItem("Preferences/com.firebase.FIRInstallations.plist")
        try mac.libraryItem("Application Support/com.crashlytics.data", directory: true)
        try mac.libraryItem("Application Support/com.1password.helper", directory: true)
        try mac.libraryItem("Application Support/com.bar.vpnclient", directory: true)
        try mac.libraryItem("Application Support/com.operasoftware.Opera", directory: true)
        try mac.libraryItem("Application Support/fr.meaillais.oust.revue", directory: true)
        _ = try mac.container("Group Containers", name: "UBF8T346G9.Office", identifier: "UBF8T346G9.Office")
        _ = try mac.container("Group Containers", name: "group.is.workflow.my.app", identifier: "group.is.workflow.my.app")
        _ = try mac.container("Group Containers", name: "74J34U3R6X.com.apple.iWork", identifier: "74J34U3R6X.com.apple.iWork")
        // Un lien symbolique n'est pas un reste : la corbeille n'emporterait que le lien.
        try FileManager.default.createDirectory(at: mac.library.appendingPathComponent("WebKit"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: mac.library.appendingPathComponent("WebKit/com.bar.app"),
                                                   withDestinationURL: mac.root)

        #expect(orphans(mac).isEmpty)
    }

    @Test("Une famille installée revendique, un éditeur installé protège")
    func claimedAndPublisher() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.foo.app")
        try mac.libraryItem("Preferences/com.foo.app.helper.plist")       // la famille de Foo
        try mac.libraryItem("Application Support/com.foo.other", directory: true)  // le même éditeur
        _ = try mac.container("Group Containers", name: "ABCDE12345.com.zzz.shared",
                              identifier: "ABCDE12345.com.zzz.shared")    // la même équipe

        let found = orphans(mac, teams: ["Foo.app": "ABCDE12345"])

        #expect(relative(mac, found) == ["Application Support/com.foo.other", "Group Containers/ABCDE12345.com.zzz.shared"])
        for leftover in found.flatMap(\.leftovers) {
            #expect(leftover.protection == .relatedAppInstalled(name: "Foo"))
        }
        #expect(found.allSatisfy { $0.isFullyProtected })
        let group = try #require(found.first)
        #expect(group.leftovers.allSatisfy { !$0.cleanupItem(in: group).isSelectable })
    }

    @Test("Le nom d'une application installée dans l'identifiant protège")
    func applicationNameInIdentifier() throws {
        let mac = try FakeMac()
        // Discord s'installe sous `com.hnc.Discord`, son outil de mise à jour écrit
        // dans `com.discord.discord.ShipIt` (Mac de Romain, 18/10/2026).
        try mac.app("Discord.app", id: "com.hnc.Discord")
        try mac.libraryItem("Preferences/ByHost/com.discord.discord.ShipIt.77E16911-5964-57FF-8A84-969695B90B9F.plist")
        // Un mot générique n'en dit pas autant.
        try mac.app("Helper.app", id: "fr.outil.helper")
        try mac.libraryItem("Preferences/com.autre.helper.plist")

        let found = orphans(mac)
        let byID = Dictionary(uniqueKeysWithValues: found.flatMap(\.leftovers).map { ($0.identifier, $0.protection) })

        #expect(byID["com.discord.discord.ShipIt"] == .some(.relatedAppInstalled(name: "Discord")))
        #expect(byID["com.autre.helper"] == .some(nil))
    }

    @Test("Launch Services, une app iPad, un module, un jeu Steam, un processus : encore là")
    func installedElsewhere() throws {
        let mac = try FakeMac()
        // Une application en développement, que seul Launch Services connaît.
        let dev = try bundle(mac, "Developpement/Build/Dev.app", id: "com.dev.app")
        try mac.libraryItem("Preferences/com.dev.app.plist")
        // Une copie à la corbeille du Mac ne compte pas : on l'a jetée.
        let trashed = try bundle(mac, ".Trash/Jetee.app", id: "com.jetee.app")
        try mac.libraryItem("Preferences/com.jetee.app.plist")
        // Une application iPad enveloppée, sans `Contents/Info.plist`.
        try bundle(mac, "Applications/Jeu iPad.app/Wrapper/JeuIPad.app", id: "com.ipad.game", flat: true)
        _ = try mac.container("Containers", name: "com.ipad.game", identifier: "com.ipad.game")
        // Un module de préférences système.
        try bundle(mac, "Modules/Reglage.prefPane", id: "com.pane.reglage")
        try mac.libraryItem("Preferences/com.pane.reglage.plist")
        // Un jeu installé par Steam, cinq niveaux plus bas.
        try bundle(mac, "maison/Library/Application Support/Steam/steamapps/common/Jeu/Jeu.app", id: "com.studio.jeu")
        try mac.libraryItem("Preferences/com.studio.jeu.plist")
        // Un outil qui tourne depuis un disque d'installation.
        let running = try bundle(mac, "Volume/Outil.app", id: "com.outil.app")
        try mac.libraryItem("Application Support/com.outil.app", directory: true)
        // Un démon installé pour tout le Mac, dont le programme est là.
        let program = try bundle(mac, "Partagé/Demon.app", id: "com.demon.app")
            .appendingPathComponent("Contents/MacOS/demon")
        try mac.data("binaire", to: program)
        try mac.write(["Label": "com.demon.helper", "ProgramArguments": [program.path]],
                      to: mac.root.appendingPathComponent("LaunchDaemons/com.demon.helper.plist"))
        try mac.libraryItem("Preferences/com.demon.helper.plist")

        let found = orphans(mac, registered: ["com.dev.app": [dev], "com.jetee.app": [trashed]],
                            running: [running.appendingPathComponent("Contents/MacOS/Outil").path])

        #expect(relative(mac, found) == ["Preferences/com.jetee.app.plist"])
    }

    @Test("Un assistant rangé dans le dossier d'une application disparue ne la sauve pas")
    func helperInsideLeftover() throws {
        let mac = try FakeMac()
        let helper = try bundle(mac, "maison/Library/Application Support/com.imo.anytrans/Assistant.app", id: "com.imo.helper")
        try mac.libraryItem("Preferences/com.imo.anytrans.plist")
        try mac.libraryItem("Preferences/com.imo.helper.plist")

        let found = orphans(mac, registered: ["com.imo.helper": [helper]])

        #expect(relative(mac, found) == [
            "Application Support/com.imo.anytrans", "Preferences/com.imo.anytrans.plist", "Preferences/com.imo.helper.plist",
        ])
        #expect(found.flatMap(\.leftovers).allSatisfy { $0.protection == nil })

        // Mais s'il tourne, quelque chose s'en sert : l'éditeur est encore là.
        let busy = orphans(mac, running: [helper.appendingPathComponent("Contents/MacOS/Assistant").path])
        #expect(relative(mac, busy) == ["Application Support/com.imo.anytrans", "Preferences/com.imo.anytrans.plist"])
        #expect(busy.flatMap(\.leftovers).allSatisfy { $0.protection == .relatedAppInstalled(name: "Assistant") })
    }

    @Test("Un conteneur : sa fiche décide ; illisible ou sans Accès complet, il est protégé")
    func containers() throws {
        let mac = try FakeMac()
        _ = try mac.container("Containers", name: "com.bar.app", identifier: "com.autre.app")
        _ = try mac.container("Containers", name: "com.baz.app", identifier: nil)

        let found = orphans(mac)
        #expect(relative(mac, found) == ["Containers/com.baz.app"])
        #expect(found.first?.leftovers.first?.protection == .needsFullDiskAccess)

        // Sans l'Accès complet, la fiche n'est même pas lue.
        let unread = orphans(mac, canReadContainers: false)
        #expect(relative(mac, unread) == ["Containers/com.bar.app", "Containers/com.baz.app"])
        #expect(unread.flatMap(\.leftovers).allSatisfy { $0.protection == .needsFullDiskAccess })
    }

    @Test("Un agent n'est orphelin que si le paquet de son programme a disparu")
    func launchAgents() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.foo.app")
        let gone = mac.root.appendingPathComponent("Applications/Disparue.app/Contents/MacOS/assistant").path
        try mac.launchAgent("com.disparue.updater", program: gone)
        try mac.libraryItem("Preferences/com.disparue.updater.plist")
        // Le programme est là : un agent vivant, qui revendique son identifiant.
        let live = try bundle(mac, "Partagé/Vivant.app", id: "com.vivant.app")
        try mac.data("binaire", to: live.appendingPathComponent("Contents/MacOS/vivant"))
        try mac.launchAgent("com.vivant.agent", program: live.appendingPathComponent("Contents/MacOS/vivant").path)
        try mac.libraryItem("Preferences/com.vivant.agent.plist")
        // Un outil hors d'un paquet, un paquet présent sans son programme, une
        // application déplacée (même nom), un agent de `SMAppService` : on ne sait pas.
        try mac.launchAgent("com.outil.service", program: mac.root.appendingPathComponent("bin/outil").path)
        try bundle(mac, "Partagé/Present.app", id: "com.present.app")
        try mac.launchAgent("com.present.agent",
                            program: mac.root.appendingPathComponent("Partagé/Present.app/Contents/MacOS/x").path)
        try mac.launchAgent("com.deplacee.agent",
                            program: mac.root.appendingPathComponent("Ancien/Foo.app/Contents/MacOS/Foo").path)
        try mac.write(["Label": "com.moderne.agent", "BundleProgram": "Contents/MacOS/agent"],
                      to: mac.library.appendingPathComponent("LaunchAgents/com.moderne.agent.plist"))

        let found = orphans(mac)

        #expect(relative(mac, found) == ["LaunchAgents/com.disparue.updater.plist", "Preferences/com.disparue.updater.plist"])
        let group = try #require(found.first)
        #expect(found.count == 1)
        #expect(group.title == "Disparue")
        let agent = try #require(group.leftovers.first { $0.kind == .launchAgent })
        #expect(agent.cleanupItem(in: group).ruleID == "orphan.launchAgent")
        #expect(agent.cleanupItem(in: group).method == .trash)
    }

    @Test("Mesurés : un fichier ouvert ou une écriture de moins de 24 heures protègent")
    func measuredProtections() async throws {
        let mac = try FakeMac()
        let old = Date().addingTimeInterval(-10 * 86_400)
        let open = try mac.libraryItem("Application Support/com.ouvert.app", directory: true)
        try mac.libraryItem("Preferences/com.recent.app.plist")
        let quiet = try mac.libraryItem("Application Support/com.calme.app", directory: true)
        for url in [open, quiet] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.appendingPathComponent("contenu.bin").path)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }

        let found = orphans(mac)
        let openFile = open.appendingPathComponent("contenu.bin").path
        let measured = await OrphanFinder.measured(found, canReadContainers: true,
                                                   openPaths: { _ in [openFile] }, holder: { _ in "Ouvreur" })
        let byID = Dictionary(uniqueKeysWithValues: measured.flatMap(\.leftovers).map { ($0.identifier, $0) })

        #expect(byID["com.ouvert.app"]?.protection == .activeProcess(name: "Ouvreur"))
        #expect(byID["com.recent.app"]?.protection == .recentlyWritten(days: 7))
        #expect(byID["com.calme.app"]?.protection == nil)
        #expect((byID["com.calme.app"]?.sizes.allocated ?? 0) > 0)
    }

    @Test("L'application est dans la corbeille du Mac : ce qu'elle vient d'écrire est à elle")
    func ownerInTrash() async throws {
        let mac = try FakeMac()
        let trashed = try bundle(mac, "maison/.Trash/Jetee.app", id: "com.jetee.app")
        try mac.libraryItem("Preferences/com.jetee.app.plist")
        try mac.libraryItem("Application Support/com.jetee.app", directory: true)

        let found = orphans(mac, registered: ["com.jetee.app": [trashed]])
        #expect(found.map(\.ownerInTrash) == [true])
        let measured = await OrphanFinder.measured(found, canReadContainers: true,
                                                   openPaths: { _ in [] }, holder: { _ in nil })
        #expect(measured.flatMap(\.leftovers).allSatisfy { $0.protection == nil })

        // Sans elle, une écriture d'aujourd'hui protège.
        let alone = await OrphanFinder.measured(orphans(mac), canReadContainers: true,
                                                openPaths: { _ in [] }, holder: { _ in nil })
        #expect(alone.flatMap(\.leftovers).allSatisfy { $0.protection == .recentlyWritten(days: 7) })
    }

    @Test("Retirés : à la corbeille du Mac, au journal, sous « Restes d'applications »")
    func endToEnd() async throws {
        let mac = try FakeMac()
        let folder = try mac.libraryItem("Application Support/com.bar.app", directory: true)
        let preferences = try mac.libraryItem("Preferences/com.bar.app.plist")
        let group = try #require(orphans(mac).first)
        let items = group.leftovers.map { $0.cleanupItem(in: group) }

        var report: CleanupReport?
        for await event in mac.engine().run(items) {
            if case .finished(let final) = event { report = final }
        }

        #expect(report?.outcomes.map(\.result) == [.trashed, .trashed])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: preferences.path))
        let history = await HistoryStore(directory: mac.historyFolder).load()
        #expect(Set(history.map(\.category)) == [.appLeftovers])
    }
}
