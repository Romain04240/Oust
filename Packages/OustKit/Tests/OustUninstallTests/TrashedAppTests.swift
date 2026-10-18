import Darwin
import Foundation
import Testing
@testable import OustUninstall
import OustClean
import OustCore
import OustSafety

/// Une application qu'on met à la corbeille du Mac, sur un faux Mac (`FakeMac`,
/// dans un dossier temporaire : RULES.md, règle 8). La corbeille aussi est
/// fausse : `maison/.Trash` du faux Mac.
@Suite("Les restes d'une application qu'on met à la corbeille du Mac")
struct TrashedAppTests {

    func macTrash(_ mac: FakeMac) throws -> URL {
        let url = mac.home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func sources(_ mac: FakeMac, registered: [String: [URL]] = [:], teams: [String: String] = [:],
                 running: [String] = []) -> OrphanSources {
        OrphanSources(
            appRoots: [mac.applications, mac.home.appendingPathComponent("Applications")],
            pluginRoots: [mac.root.appendingPathComponent("Modules")],
            helperRoots: [mac.library.appendingPathComponent("Application Support")],
            labelRoots: [mac.root.appendingPathComponent("LaunchDaemons")],
            registeredApps: { registered[$0] ?? [] },
            signature: { SigningFacts(teamID: teams[$0.lastPathComponent], groups: []) },
            runningExecutables: { running },
            canReadContainers: true
        )
    }

    /// Met l'application à la fausse corbeille, d'un `rename` comme le Finder.
    @discardableResult
    func trash(_ mac: FakeMac, _ name: String, as trashedName: String? = nil) throws -> URL {
        let destination = try macTrash(mac).appendingPathComponent(trashedName ?? name, isDirectory: true)
        try FileManager.default.moveItem(at: mac.applications.appendingPathComponent(name), to: destination)
        return destination
    }

    func examine(_ mac: FakeMac, _ url: URL, at date: Date = Date(), registered: [String: [URL]] = [:],
                 teams: [String: String] = [:], running: [String] = []) throws -> TrashedAppExamination {
        let arrival = TrashArrival(url: url, fileID: 1, date: date)
        let sources = sources(mac, registered: registered, teams: teams, running: running)
        let app = try #require(TrashedAppFinder.read(arrival, signature: sources.signature))
        return TrashedAppFinder.examine(app, arrival: arrival, home: mac.home, sources: sources)
    }

    /// Pourquoi rien n'est proposé, et le chemin en cause (les URL de dossiers
    /// diffèrent d'une barre finale ou d'un « /private » selon qui les a faites).
    func skip(_ examination: TrashedAppExamination) -> String {
        switch examination {
        case .offer: "proposé"
        case .skip(.replaced(let url)): "remplacée " + url.resolvingSymlinksInPath().path
        case .skip(.anotherCopy(let url)): "autre copie " + url.resolvingSymlinksInPath().path
        case .skip(let reason): "\(reason)"
        }
    }

    func offer(_ examination: TrashedAppExamination) throws -> TrashedApp {
        guard case .offer(let trashed) = examination else {
            Issue.record("Rien de proposé : \(examination)")
            throw CancellationError()
        }
        return trashed
    }

    func relative(_ mac: FakeMac, _ leftovers: [Leftover]) -> Set<String> {
        Set(leftovers.map { String($0.url.path.dropFirst(mac.library.path.count + 1)) })
    }

    func leftover(_ mac: FakeMac, _ trashed: TrashedApp, _ relative: String) -> Leftover? {
        trashed.leftovers.first { $0.url.path == mac.library.appendingPathComponent(relative).path }
    }

    /// Recule la date de modification d'un fichier ou d'un dossier, et de tout ce qu'il contient.
    func age(_ url: URL, to date: Date) throws {
        var paths = [url.path]
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let child as String in enumerator { paths.append(url.appendingPathComponent(child).path) }
        }
        for path in paths.reversed() {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }

    /// Ce que Foo laisse d'habitude dans la bibliothèque.
    func fooLeftovers(_ mac: FakeMac) throws {
        try mac.libraryItem("Application Support/com.exemple.foo", directory: true, bytes: 1_500_000)
        try mac.libraryItem("Application Support/Foo", directory: true)
        try mac.libraryItem("Caches/com.exemple.foo", directory: true)
        try mac.libraryItem("Preferences/com.exemple.foo.plist")
        try mac.libraryItem("Saved Application State/com.exemple.foo.savedState", directory: true)
        _ = try mac.container("Containers", name: "com.exemple.foo", identifier: "com.exemple.foo")
        try mac.launchAgent("com.exemple.foo.agent",
                            program: mac.applications.appendingPathComponent("Foo.app/Contents/MacOS/FooAgent").path)
    }

    // MARK: Surveillance

    @Test("Un paquet qui arrive dans la corbeille est signalé ; ce qui y était déjà, ou n'est pas une app, non")
    func watcherSeesArrivals() async throws {
        let mac = try FakeMac()
        let folder = try macTrash(mac)
        try mac.app("Foo.app", id: "com.exemple.foo")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Ancienne.app"),
                                                withIntermediateDirectories: true)

        let (stream, continuation) = AsyncStream.makeStream(of: TrashArrival.self)
        let watcher = TrashWatcher { continuation.yield($0) }
        let watched = watcher.watch([folder])
        #expect(watched.map(\.path) == [folder.standardizedFileURL.path])

        try mac.data("texte", to: folder.appendingPathComponent("note.txt"))
        let url = try trash(mac, "Foo.app")

        let arrival = await withTaskGroup(of: TrashArrival?.self) { group in
            group.addTask { await stream.first { _ in true } }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        watcher.stop()
        continuation.finish()

        let seen = try #require(arrival)
        #expect(seen.url.lastPathComponent == url.lastPathComponent)
        #expect(seen.originalName == "Foo.app")
        var info = stat()
        #expect(lstat(url.path, &info) == 0 && seen.fileID == UInt64(info.st_ino))
    }

    @Test("Une corbeille illisible ou absente n'est pas surveillée")
    func unreadableTrash() throws {
        let mac = try FakeMac()
        let watcher = TrashWatcher { _ in }
        #expect(watcher.watch([mac.root.appendingPathComponent("absente")]).isEmpty)
    }

    @Test("Le nom d'avant la corbeille, sans l'heure ni le numéro du Finder")
    func originalNames() {
        #expect(MacTrash.originalName(of: "Foo.app") == "Foo.app")
        #expect(MacTrash.originalName(of: "Foo 14.32.07.app") == "Foo.app")
        #expect(MacTrash.originalName(of: "Foo 2.32.07 PM.app") == "Foo.app")
        #expect(MacTrash.originalName(of: "Foo 2.app") == "Foo.app")
        #expect(MacTrash.originalName(of: "Studio 3T.app") == "Studio 3T.app")
        #expect(MacTrash.originalName(of: "2048.app") == "2048.app")
    }

    // MARK: Les restes

    @Test("De la corbeille aux restes : identifiant, nom, conteneur confirmé, agent, tout mesuré")
    func fromArrivalToLeftovers() async throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo")
        try mac.app("Bar.app", id: "com.autre.bar")
        try fooLeftovers(mac)
        // Ce qui n'est pas à Foo : une autre application, un conteneur dont la
        // fiche dit autre chose, un nom qui ressemble.
        try mac.libraryItem("Preferences/com.autre.bar.plist")
        _ = try mac.container("Containers", name: "com.exemple.foo.share", identifier: "com.exemple.autre")
        try mac.libraryItem("Application Support/Foo Pro", directory: true)

        let url = try trash(mac, "Foo.app")
        let trashed = await TrashedAppFinder.measured(try offer(try examine(mac, url)), recencyDays: 7)

        #expect(relative(mac, trashed.leftovers) == [
            "Application Support/com.exemple.foo", "Application Support/Foo", "Caches/com.exemple.foo",
            "Preferences/com.exemple.foo.plist", "Saved Application State/com.exemple.foo.savedState",
            "Containers/com.exemple.foo", "LaunchAgents/com.exemple.foo.agent.plist",
        ])
        #expect(trashed.leftovers.allSatisfy { $0.protection == nil })
        #expect(trashed.freeable >= 1_500_000)
        #expect(trashed.isWorthOffering)
        #expect(trashed.app.name == "Foo")
        #expect(trashed.originalName == "Foo.app")

        // Coché d'office : ce qui ne sert plus à rien sans elle ; pas ce qui ne
        // se reconstruit pas, ni ce qu'on n'a reconnu qu'à son nom.
        let preselected = Set(trashed.items.filter { trashed.preselectedIDs.contains($0.id) }
            .map { String($0.paths[0].path.dropFirst(mac.library.path.count + 1)) })
        #expect(preselected == ["Caches/com.exemple.foo", "Saved Application State/com.exemple.foo.savedState",
                                "LaunchAgents/com.exemple.foo.agent.plist"])
        #expect(trashed.items.allSatisfy { $0.method == .trash && $0.category == .applications })
    }

    @Test("Moins de 1 Mo de restes : on ne dérange pas")
    func belowThreshold() async throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo")
        try mac.libraryItem("Preferences/com.exemple.foo.plist")
        let trashed = await TrashedAppFinder.measured(try offer(try examine(mac, try trash(mac, "Foo.app"))),
                                                      recencyDays: 7)
        #expect(trashed.leftovers.count == 1)
        #expect(!trashed.isWorthOffering)
    }

    @Test("Une application proche encore installée protège ce qui ne se reconstruit pas")
    func relatedAppInstalled() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo")
        try mac.app("Foo Studio.app", id: "com.exemple.studio")
        try fooLeftovers(mac)

        let trashed = try offer(try examine(mac, try trash(mac, "Foo.app")))

        #expect(leftover(mac, trashed, "Application Support/com.exemple.foo")?.protection
                == .relatedAppInstalled(name: "Foo Studio"))
        #expect(leftover(mac, trashed, "Preferences/com.exemple.foo.plist")?.protection
                == .relatedAppInstalled(name: "Foo Studio"))
        #expect(leftover(mac, trashed, "Containers/com.exemple.foo")?.protection
                == .relatedAppInstalled(name: "Foo Studio"))
        // Un cache, un état de fenêtre, un agent : ils ne manqueront à personne.
        #expect(leftover(mac, trashed, "Caches/com.exemple.foo")?.protection == nil)
        #expect(leftover(mac, trashed, "Saved Application State/com.exemple.foo.savedState")?.protection == nil)
        #expect(leftover(mac, trashed, "LaunchAgents/com.exemple.foo.agent.plist")?.protection == nil)
    }

    @Test("La même équipe de signature compte comme une application proche")
    func sameTeam() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo")
        try mac.app("Autre.app", id: "org.ailleurs.autre")
        try fooLeftovers(mac)

        let trashed = try offer(try examine(mac, try trash(mac, "Foo.app"),
                                            teams: ["Foo.app": "ABCDE12345", "Autre.app": "ABCDE12345"]))

        #expect(leftover(mac, trashed, "Preferences/com.exemple.foo.plist")?.protection
                == .relatedAppInstalled(name: "Autre"))
    }

    @Test("Un assistant de l'application encore installé ailleurs protège ses affaires")
    func helperStillInstalled() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo", embedded: [("Library/LoginItems/Aide.app", "com.exemple.foo.aide", [:])])
        try fooLeftovers(mac)
        try mac.libraryItem("Preferences/com.exemple.foo.aide.plist")
        // Launch Services connaît l'assistant à un autre endroit, où il est encore.
        let helper = mac.root.appendingPathComponent("Ailleurs/Aide.app")
        try mac.write(["CFBundleIdentifier": "com.exemple.foo.aide"], to: helper.appendingPathComponent("Contents/Info.plist"))

        let trashed = try offer(try examine(mac, try trash(mac, "Foo.app"),
                                            registered: ["com.exemple.foo.aide": [helper]]))

        #expect(leftover(mac, trashed, "Preferences/com.exemple.foo.aide.plist")?.protection
                == .usedByAnotherApp(name: "Aide"))
        // L'assistant fait partie de la famille : le reste de Foo lui sert peut-être aussi.
        #expect(leftover(mac, trashed, "Preferences/com.exemple.foo.plist")?.protection
                == .usedByAnotherApp(name: "Aide"))
    }

    @Test("Modifié après la mise à la corbeille : quelqu'un s'en sert, protégé ; un fichier ouvert aussi")
    func writtenAfterTrash() async throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo")
        try fooLeftovers(mac)
        let trashedAt = Date().addingTimeInterval(-3_600)
        let before = trashedAt.addingTimeInterval(-86_400)
        for relative in ["Application Support/com.exemple.foo", "Application Support/Foo", "Caches/com.exemple.foo",
                         "Saved Application State/com.exemple.foo.savedState", "Containers/com.exemple.foo",
                         "LaunchAgents/com.exemple.foo.agent.plist"] {
            try age(mac.library.appendingPathComponent(relative), to: before)
        }
        // Les préférences ont changé il y a un instant, une heure après le départ de Foo.
        let open = mac.library.appendingPathComponent("Caches/com.exemple.foo/contenu.bin").path

        let found = try offer(try examine(mac, try trash(mac, "Foo.app"), at: trashedAt))
        let trashed = await TrashedAppFinder.measured(found, recencyDays: 7, openPaths: { _ in [open] },
                                                      holder: { _ in "Espion" })

        #expect(leftover(mac, trashed, "Preferences/com.exemple.foo.plist")?.protection == .recentlyWritten(days: 7))
        #expect(leftover(mac, trashed, "Caches/com.exemple.foo")?.protection == .activeProcess(name: "Espion"))
        // Écrit la veille de son départ : c'est l'application elle-même.
        #expect(leftover(mac, trashed, "Application Support/com.exemple.foo")?.protection == nil)
    }

    // MARK: Ce qui ne déclenche rien

    @Test("Une mise à jour : la version neuve a pris la place de l'ancienne")
    func update() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo")
        try fooLeftovers(mac)
        let old = try trash(mac, "Foo.app", as: "Foo 10.12.42.app")
        try mac.app("Foo.app", id: "com.exemple.foo")

        #expect(skip(try examine(mac, old)) == "remplacée " + mac.applications.appendingPathComponent("Foo.app").path)
    }

    @Test("Une mise à jour qui change de nom de paquet garde son identifiant : une autre copie")
    func renamedUpdate() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo")
        try fooLeftovers(mac)
        let old = try trash(mac, "Foo.app")
        let new = try mac.app("Foo 2.app", id: "com.exemple.foo")

        #expect(skip(try examine(mac, old)) == "autre copie " + new.path)
    }

    @Test("Une autre copie reste installée, dans Applications ou ailleurs selon Launch Services")
    func anotherCopy() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo")
        try fooLeftovers(mac)
        let home = mac.home.appendingPathComponent("Applications/Foo Copie.app")
        try mac.write(["CFBundleIdentifier": "com.exemple.foo", "CFBundleName": "Foo"],
                      to: home.appendingPathComponent("Contents/Info.plist"))
        let url = try trash(mac, "Foo.app")

        #expect(skip(try examine(mac, url)) == "autre copie " + home.path)

        try FileManager.default.removeItem(at: home)
        // Une copie de développement, connue de Launch Services seulement ; la
        // copie de la corbeille, qu'il connaît aussi, ne compte pas.
        let derived = mac.root.appendingPathComponent("DerivedData/Build/Products/Debug/Foo.app")
        try mac.write(["CFBundleIdentifier": "com.exemple.foo"], to: derived.appendingPathComponent("Contents/Info.plist"))
        #expect(skip(try examine(mac, url, registered: ["com.exemple.foo": [url, derived]])) == "autre copie " + derived.path)
        #expect(skip(try examine(mac, url, registered: ["com.exemple.foo": [url]])) == "proposé")
    }

    @Test("Encore ouverte depuis la corbeille, ou de celles qu'Oust! ne désinstalle jamais : rien")
    func runningOrExcluded() throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo")
        try mac.app("Coffre.app", id: "com.1password.coffre")
        try fooLeftovers(mac)
        let foo = try trash(mac, "Foo.app")
        let coffre = try trash(mac, "Coffre.app")

        #expect(try examine(mac, foo, running: [foo.appendingPathComponent("Contents/MacOS/Foo").path]) == .skip(.running))
        #expect(try examine(mac, coffre) == .skip(.excluded(.passwordManager)))
    }

    @Test("Ce que le désinstalleur d'Oust! vient de jeter n'est pas reproposé")
    func ownCleanup() throws {
        let mac = try FakeMac()
        let trash = try macTrash(mac)
        let item = CleanupItem(
            id: "uninstall|/Applications/Foo.app", title: "Foo", detail: nil,
            paths: [URL(fileURLWithPath: "/Applications/Foo.app")], category: .applications, owner: "Foo",
            ruleID: "uninstall.app", safety: .review, method: .trash, sizes: .zero, lastActivity: nil,
            rebuild: .download, fingerprint: Fingerprint(modificationDate: nil, fileID: nil)
        )
        let now = Date()
        let byName = CleanupOutcome(sessionID: UUID(), date: now, item: item, result: .trashed, bytes: 0)
        let byPlace = CleanupOutcome(sessionID: UUID(), date: now.addingTimeInterval(-86_400), item: item,
                                     result: .trashed, bytes: 0,
                                     trashedTo: [trash.appendingPathComponent("Foo 10.00.00.app").path])
        let arrival = TrashArrival(url: trash.appendingPathComponent("Foo 10.00.00.app"), fileID: 1, date: now)
        let other = TrashArrival(url: trash.appendingPathComponent("Bar.app"), fileID: 2, date: now)

        #expect(TrashedAppFinder.isOwnCleanup(arrival, outcomes: [byName]))
        #expect(TrashedAppFinder.isOwnCleanup(arrival, outcomes: [byPlace]))
        #expect(!TrashedAppFinder.isOwnCleanup(other, outcomes: [byName, byPlace]))
        let later = TrashArrival(url: arrival.url, fileID: 1, date: now.addingTimeInterval(3_600))
        #expect(!TrashedAppFinder.isOwnCleanup(later, outcomes: [byName]))
    }

    @Test("La revue mène à la corbeille du Mac par le moteur de nettoyage, qui revalide")
    func cleanupGoesToTheMacTrash() async throws {
        let mac = try FakeMac()
        try mac.app("Foo.app", id: "com.exemple.foo")
        try fooLeftovers(mac)
        let trashed = await TrashedAppFinder.measured(try offer(try examine(mac, try trash(mac, "Foo.app"))),
                                                      recencyDays: 7)
        let chosen = trashed.items.filter { trashed.preselectedIDs.contains($0.id) }

        var report: CleanupReport?
        for await event in mac.engine().run(chosen) {
            if case .finished(let final) = event { report = final }
        }

        let outcomes = try #require(report).outcomes
        #expect(outcomes.count == chosen.count)
        #expect(outcomes.allSatisfy { $0.result == .trashed })
        #expect(!FileManager.default.fileExists(atPath: mac.library.appendingPathComponent("Caches/com.exemple.foo").path))
        // Ce qui n'était pas coché est toujours là.
        #expect(FileManager.default.fileExists(atPath: mac.library.appendingPathComponent("Preferences/com.exemple.foo.plist").path))
    }
}
