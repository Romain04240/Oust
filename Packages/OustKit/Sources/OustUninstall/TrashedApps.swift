import Darwin
import Foundation
import OustCore
import OustSafety
import OustScan

// MARK: - Les corbeilles du Mac

/// Où macOS range ce qu'on met à la corbeille : `~/.Trash` pour le disque de
/// démarrage, `<disque>/.Trashes/<uid>` pour chaque autre disque.
public enum MacTrash {

    /// Les corbeilles de l'utilisateur à surveiller : la sienne, et celle de
    /// chaque disque branché où il a déjà jeté quelque chose (macOS ne crée
    /// `.Trashes/<uid>` qu'à la première fois, et le dossier `.Trashes` lui-même
    /// ne se lit pas).
    public static func folders(home: URL, volumes: [URL] = otherVolumes()) -> [URL] {
        var folders = [home.appendingPathComponent(".Trash", isDirectory: true)]
        for volume in volumes {
            let trash = volume.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true)
            if isDirectory(trash) { folders.append(trash) }
        }
        return folders
    }

    /// Les disques locaux branchés, en écriture, hors disque de démarrage. Pas
    /// les disques réseau : un serveur perdu ferait attendre la lecture.
    public static func otherVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsLocal == true && values.volumeIsReadOnly == false
                && values.volumeIsRootFileSystem == false && url.path.hasPrefix("/Volumes/")
        }
    }

    /// Les paquets `.app` posés au premier niveau d'une corbeille, avec leur
    /// numéro de fichier : un paquet qui en remplace un autre du même nom
    /// (vidé puis rejeté) compte comme une arrivée. `nil` si on ne peut pas lire
    /// le dossier : sans l'Accès complet au disque, macOS refuse `~/.Trash`.
    public static func apps(in folder: URL) -> [String: UInt64]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        var found: [String: UInt64] = [:]
        for name in names where name.hasSuffix(".app") && !name.hasPrefix(".") {
            var info = stat()
            let path = folder.appendingPathComponent(name).path
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            found[name] = UInt64(info.st_ino)
        }
        return found
    }

    /// Le nom qu'avait le paquet avant la corbeille. Quand le nom y est déjà
    /// pris, le Finder ajoute l'heure (« Foo 14.32.07.app ») ou un numéro
    /// (« Foo 2.app ») : on les retire pour retrouver « Foo.app ».
    public static func originalName(of trashedName: String) -> String {
        let stem = trashedName.hasSuffix(".app") ? String(trashedName.dropLast(4)) : trashedName
        let patterns = [#/ \d{1,2}[.:\-]\d{2}[.:\-]\d{2}(?: [AaPp][Mm])?$/#, #/ \d{1,3}$/#]
        for pattern in patterns {
            if let match = stem.firstMatch(of: pattern), match.range.lowerBound > stem.startIndex {
                return String(stem[..<match.range.lowerBound]) + ".app"
            }
        }
        return stem + ".app"
    }

    public static func isInTrash(_ url: URL) -> Bool { Claims.inTrash(url) }

    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}

/// Un paquet `.app` qui vient d'arriver dans une corbeille du Mac.
public struct TrashArrival: Sendable, Hashable {
    public let url: URL
    public let fileID: UInt64
    public let date: Date

    public init(url: URL, fileID: UInt64, date: Date = Date()) {
        self.url = url
        self.fileID = fileID
        self.date = date
    }

    /// Le nom du paquet avant la corbeille (« Foo.app »).
    public var originalName: String { MacTrash.originalName(of: url.lastPathComponent) }

    /// Les noms qu'il a pu porter avant : celui d'avant la corbeille, et le sien
    /// tel quel (« Logic Pro 11.app » n'a pas reçu son « 11 » du Finder).
    var candidateNames: Set<String> {
        [originalName.lowercased(), url.lastPathComponent.lowercased()]
    }
}

// MARK: - La surveillance

/// Surveille les corbeilles du Mac et signale chaque paquet `.app` qui y arrive.
///
/// Une source `DISPATCH_SOURCE_TYPE_VNODE` par dossier, plutôt que FSEvents : un
/// paquet mis à la corbeille y arrive d'un seul `rename`, que le noyau signale
/// aussitôt sur le dossier ; on relit alors son premier niveau et on compare.
/// Ce qui est déjà dans une corbeille au moment de commencer n'est pas une
/// arrivée. Rien n'est lu au-delà du premier niveau.
public final class TrashWatcher: @unchecked Sendable {
    // Tout l'état vit sur `queue` : c'est ce qui permet `@unchecked Sendable`.
    private let queue = DispatchQueue(label: "fr.meaillais.oust.trash-watcher", qos: .utility)
    private var watched: [String: Watched] = [:]
    private let onArrival: @Sendable (TrashArrival) -> Void

    private struct Watched {
        let source: any DispatchSourceFileSystemObject
        var known: [String: UInt64]
    }

    public init(onArrival: @escaping @Sendable (TrashArrival) -> Void) {
        self.onArrival = onArrival
    }

    deinit {
        for entry in watched.values { entry.source.cancel() }
    }

    /// Surveille exactement ces dossiers : les nouveaux commencent, ceux qui
    /// ne sont plus demandés s'arrêtent. Rend ceux qu'on surveille vraiment
    /// (un dossier illisible ne l'est pas).
    @discardableResult
    public func watch(_ folders: [URL]) -> [URL] {
        queue.sync {
            let wanted = Set(folders.map { $0.standardizedFileURL.path })
            for (path, entry) in watched where !wanted.contains(path) {
                entry.source.cancel()
                watched[path] = nil
            }
            for path in wanted.sorted() where watched[path] == nil { begin(path) }
            return watched.keys.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    public func stop() { watch([]) }

    private func begin(_ path: String) {
        guard let known = MacTrash.apps(in: URL(fileURLWithPath: path, isDirectory: true)) else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, let events = self.watched[path]?.source.data else { return }
            self.changed(path, events: events)
        }
        source.setCancelHandler { close(descriptor) }
        watched[path] = Watched(source: source, known: known)
        source.resume()
    }

    private func changed(_ path: String, events: DispatchSource.FileSystemEvent) {
        guard var entry = watched[path] else { return }
        // Le dossier lui-même a disparu ou changé de nom (un disque qu'on
        // éjecte) : on le rouvre s'il est encore là, sans rien signaler.
        if events.contains(.delete) || events.contains(.rename) {
            entry.source.cancel()
            watched[path] = nil
            begin(path)
            return
        }
        guard let now = MacTrash.apps(in: URL(fileURLWithPath: path, isDirectory: true)) else { return }
        let date = Date()
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        for (name, fileID) in now.sorted(by: { $0.key < $1.key }) where entry.known[name] != fileID {
            onArrival(TrashArrival(url: folder.appendingPathComponent(name, isDirectory: true), fileID: fileID, date: date))
        }
        entry.known = now
        watched[path] = entry
    }
}

// MARK: - Ce qu'on trouve

/// Une application qu'on vient de mettre à la corbeille du Mac, et ce qu'elle
/// a laissé dans `~/Library`.
public struct TrashedApp: Sendable, Hashable, Identifiable {
    public var id: String { app.url.path }
    /// Lue dans son paquet, dans la corbeille.
    public let app: InstalledApp
    public let trashedAt: Date
    /// Le nom du paquet avant la corbeille (« Foo.app »).
    public let originalName: String
    /// L'équipe de sa signature, lue tant que le paquet était là.
    public let teamID: String?
    public var leftovers: [Leftover]

    public init(app: InstalledApp, trashedAt: Date, originalName: String, teamID: String? = nil,
                leftovers: [Leftover] = []) {
        self.app = app
        self.trashedAt = trashedAt
        self.originalName = originalName
        self.teamID = teamID
        self.leftovers = leftovers
    }

    /// Ce que rendrait tout ce qu'on peut cocher.
    public var freeable: Int64 {
        leftovers.filter { $0.protection == nil }.reduce(0) { $0 + $1.sizes.freeable }
    }

    /// Assez pour déranger (`TrashedAppFinder.offerThreshold`).
    public var isWorthOffering: Bool { freeable >= TrashedAppFinder.offerThreshold }

    /// Ce qui est coché d'office : ce qui ne sert plus à rien sans
    /// l'application, comme quand on la coche dans le désinstalleur. Ce qui ne
    /// se reconstruit pas attend la main de l'utilisateur (RULES.md, règle 4).
    public var preselectedIDs: Set<String> {
        Set(leftovers.filter(\.isPreselected).map { $0.cleanupItem(for: app).id })
    }

    /// Les restes comme éléments de la corbeille d'Oust!, ceux du désinstalleur :
    /// même identifiant, même classe, même méthode (la corbeille du Mac).
    public var items: [CleanupItem] { leftovers.map { $0.cleanupItem(for: app) } }
}

/// Pourquoi une application mise à la corbeille n'appelle aucune proposition.
public enum TrashedAppSkip: Sendable, Hashable {
    /// Pas un paquet d'application lisible, ou sans identifiant.
    case unreadable
    /// Ce qu'Oust! ne désinstalle jamais (Apple, mots de passe, VPN…).
    case excluded(AppExclusion)
    /// Une application du même nom est à sa place dans Applications : une
    /// mise à jour (la version neuve a pris la place de l'ancienne), ou une
    /// copie qu'on est en train d'y poser.
    case replaced(URL)
    /// Une autre copie de la même application reste sur le Mac.
    case anotherCopy(URL)
    /// Elle tourne encore depuis la corbeille.
    case running
}

public enum TrashedAppExamination: Sendable, Hashable {
    case offer(TrashedApp)
    case skip(TrashedAppSkip)
}

// MARK: - La recherche

/// La signature d'un paquet ne se lit qu'une fois par recherche : l'inventaire
/// des applications puis les revendications la demandent chacun, et celle
/// d'Xcode coûte plusieurs secondes.
final class SignatureCache: @unchecked Sendable {
    // `known` n'est lu et écrit que sous `lock`.
    private let lock = NSLock()
    private var known: [String: SigningFacts] = [:]
    private let read: @Sendable (URL) -> SigningFacts

    init(_ read: @escaping @Sendable (URL) -> SigningFacts) {
        self.read = read
    }

    func facts(of url: URL) -> SigningFacts {
        let key = url.standardizedFileURL.path
        if let facts = lock.withLock({ known[key] }) { return facts }
        let facts = read(url)
        lock.withLock { known[key] = facts }
        return facts
    }
}

/// Les restes d'une application qu'on vient de mettre à la corbeille du Mac.
///
/// La correspondance est celle du désinstalleur (`LeftoverFinder`) :
/// l'identifiant de l'application et de ses paquets embarqués, son nom quand
/// aucune autre ne le porte, ses conteneurs confirmés par `containermanagerd`.
/// Les garde-fous sont ceux des restes d'applications disparues
/// (`OrphanFinder`) : tout ce qui reste sur le Mac et revendique un
/// identifiant (une autre copie, un assistant, un démon, un processus, Launch
/// Services) le protège ; une application proche encore installée (même
/// éditeur, même équipe) protège ce qui ne se reconstruit pas ; un reste
/// modifié après la mise à la corbeille sert encore à quelqu'un. Et rien ne
/// part si l'application n'est pas vraiment partie : une mise à jour, une
/// autre copie installée, ou l'application ouverte depuis la corbeille.
public enum TrashedAppFinder {

    /// En deçà, on ne dérange pas : quelques préférences et un état de fenêtre.
    public static let offerThreshold: Int64 = 1_000_000

    /// Le temps que l'application qu'on vient de quitter finisse d'écrire
    /// (`cfprefsd` range les préférences juste après) : au-delà, une écriture
    /// vient de quelqu'un d'autre.
    public static let writeGrace: TimeInterval = 120

    /// Lit le paquet arrivé dans la corbeille, tout de suite : vidée entre-temps,
    /// la corbeille ne laisserait plus rien à lire.
    public static func read(_ arrival: TrashArrival, signature: (URL) -> SigningFacts) -> InstalledApp? {
        guard let app = AppCatalog.read(arrival.url, entitlements: { signature($0).groups }, lastUsed: { _ in nil })
        else { return nil }
        // « Foo 14.32.07 » est le nom que le Finder lui a donné dans la corbeille,
        // pas un nom sous lequel elle range ses affaires : on reprend « Foo ».
        let trashedStem = arrival.url.deletingPathExtension().lastPathComponent
        let originalStem = String(arrival.originalName.dropLast(".app".count))
        guard trashedStem != originalStem else { return app }
        var names = app.names.filter { $0 != trashedStem }
        if !names.contains(originalStem) { names.insert(originalStem, at: 0) }
        return InstalledApp(url: app.url, name: app.name, bundleID: app.bundleID, version: app.version,
                            embeddedIDs: app.embeddedIDs, applicationGroups: app.applicationGroups, names: names,
                            isAppStore: app.isAppStore, fileID: app.fileID, modificationDate: app.modificationDate,
                            lastUsed: app.lastUsed, sizes: app.sizes, exclusion: app.exclusion)
    }

    /// Décide s'il y a quelque chose à proposer, et quoi. Sans mesure : voir
    /// `measured`. L'équipe se lit dans le paquet s'il est encore là ; vidée,
    /// la corbeille ne la dit plus, d'où `team`, lu à l'arrivée.
    public static func examine(_ trashed: InstalledApp, arrival: TrashArrival, home: URL, team: String? = nil,
                               sources: OrphanSources) -> TrashedAppExamination {
        guard let bundleID = trashed.bundleID else { return .skip(.unreadable) }
        let cache = SignatureCache(sources.signature)
        var sources = sources
        sources.signature = { cache.facts(of: $0) }
        if let exclusion = trashed.exclusion { return .skip(.excluded(exclusion)) }
        let originalName = arrival.originalName
        let names = arrival.candidateNames

        // Une mise à jour, ou une copie qu'on pose : le même nom à sa place.
        let appRoots = sources.appRoots.filter { !$0.path.hasPrefix("/System/") }
        let bundles = AppCatalog.bundles(in: appRoots)
        if let same = bundles.first(where: { names.contains($0.lastPathComponent.lowercased()) }) {
            return .skip(.replaced(same))
        }
        let installed = AppCatalog.installedApps(in: appRoots, entitlements: { sources.signature($0).groups },
                                                 lastUsed: { _ in nil })
        let id = bundleID.lowercased()
        if let copy = installed.first(where: { $0.bundleID?.lowercased() == id }) { return .skip(.anotherCopy(copy.url)) }
        // Launch Services connaît aussi les copies d'ailleurs : `DerivedData`,
        // un disque externe, même débranché.
        for url in sources.registeredApps(bundleID) where Claims.stillThere(url) {
            return .skip(.anotherCopy(url))
        }
        let running = sources.runningExecutables()
        if running.contains(where: { PathNormalizer.isWithin($0, trashed.url.path) }) { return .skip(.running) }

        // Les noms sûrs se jugent avec les applications installées : un nom que
        // deux applications portent ne désigne plus aucune des deux.
        let unique = AppCatalog.withUniqueNames(installed + [trashed])
        let app = unique.first { $0.id == trashed.id } ?? trashed
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var leftovers = LeftoverFinder.leftovers(of: app, among: installed, home: home)
        leftovers += launchAgents(of: app, names: names, in: library, home: home,
                                  excluding: Set(leftovers.map(\.url.path)))

        // Ce qui reste sur le Mac et revendique encore quelque chose. Un paquet
        // rangé dans l'un de nos restes ne revendique rien : il part avec eux
        // (l'assistant d'Application Support), sauf s'il tourne.
        let ours = Dictionary(leftovers.filter { $0.kind == .applicationSupport }
            .map { (PathNormalizer.normalize($0.url.path), "") }, uniquingKeysWith: { first, _ in first })
        var claims = Claims(candidateFolders: ours)
        claims.add(installed: installed, sources: sources)
        claims.addBundles(in: sources, installed: installed)
        claims.addLabels(in: sources.labelRoots)
        // Un agent dont le programme est dans le paquet jeté ne revendique rien :
        // c'est l'un des restes.
        for agent in OrphanFinder.launchAgents(in: library).live
        where !PathNormalizer.isWithin(agent.program, trashed.url.path) {
            claims.addLive(agent)
        }
        claims.addRunning(running)
        for identifier in app.allIDs {
            for url in sources.registeredApps(identifier) where Claims.stillThere(url) {
                claims.add(registered: url, identifier: identifier, signature: sources.signature)
            }
        }
        let team = team ?? sources.signature(trashed.url).teamID

        leftovers = leftovers.map { leftover in
            var leftover = leftover
            guard leftover.contextualProtection == nil else { return leftover }
            let identifier = Self.identifier(of: leftover, in: app)
            if let owner = claims.owner(of: identifier) {
                leftover.protection = .usedByAnotherApp(name: owner)
            } else if leftover.kind == .groupContainer, claims.groups.contains(leftover.url.lastPathComponent.lowercased()) {
                leftover.protection = .usedByAnotherApp(name: leftover.url.lastPathComponent)
            } else if leftover.match == .name, let owner = claims.names[leftover.url.lastPathComponent.lowercased()] {
                leftover.protection = .usedByAnotherApp(name: owner)
            } else if leftover.kind.orphanRebuild == .irreversible {
                // Une application proche encore là : ce qui ne se reconstruit pas
                // lui sert peut-être (une suite, un même éditeur). Un cache, un
                // journal, un état de fenêtre ne manqueront à personne.
                let related = team.flatMap { claims.teams[$0] } ?? claims.publisher(of: identifier)
                    ?? claims.applicationNamed(inside: identifier)
                if let related { leftover.protection = .relatedAppInstalled(name: related) }
            }
            return leftover
        }
        return .offer(TrashedApp(app: app, trashedAt: arrival.date, originalName: originalName, teamID: team,
                                 leftovers: leftovers))
    }

    /// Mesure les restes, puis protège ce dont quelque chose se sert encore :
    /// un fichier ouvert dedans, une écriture après la mise à la corbeille.
    /// Avant, les écritures sont celles de l'application : elle vient de servir,
    /// et c'est bien elle qu'on retire (`OrphanFinder.measured` fait de même
    /// pour une application encore dans la corbeille).
    public static func measured(
        _ trashed: TrashedApp, recencyDays: Int,
        openPaths: @Sendable (URL) -> Set<String> = { OpenFiles.paths(under: $0.path) },
        holder: @Sendable (URL) -> String? = { OpenFiles.holders(under: $0.path).first?.name }
    ) async -> TrashedApp {
        var trashed = trashed
        let measures = await Scanner.measure(trashed.leftovers.map(\.url))
        let library = OrphanFinder.commonLibrary(of: trashed.leftovers.map(\.url))
        let open = library.map(openPaths) ?? []
        let limit = trashed.trashedAt.addingTimeInterval(writeGrace)
        trashed.leftovers = trashed.leftovers.map { leftover in
            var leftover = leftover
            let measure = measures[leftover.url]
            if let measure {
                leftover.sizes = measure.sizes
                if measure.inaccessible, leftover.protection == nil { leftover.protection = .needsFullDiskAccess }
            }
            guard leftover.contextualProtection == nil else { return leftover }
            if open.contains(where: { PathNormalizer.isWithin($0, leftover.url.path) }) {
                leftover.protection = .activeProcess(name: holder(leftover.url) ?? trashed.app.name)
            } else if let latest = [leftover.modificationDate, measure?.latestModification].compactMap({ $0 }).max(),
                      latest > limit {
                leftover.protection = .recentlyWritten(days: recencyDays)
            }
            return leftover
        }
        trashed.leftovers = LeftoverFinder.recheckingPreferenceVeto(trashed.leftovers)
            .sorted { $0.sizes.allocated > $1.sizes.allocated }
        return trashed
    }

    /// Un paquet que le nettoyage d'Oust! vient de poser dans la corbeille du
    /// Mac (le désinstalleur, ou un agent par `oust`) : ce qu'on a laissé dans
    /// la bibliothèque l'a été exprès, on ne le repropose pas.
    public static func isOwnCleanup(_ arrival: TrashArrival, outcomes: [CleanupOutcome]) -> Bool {
        let path = PathNormalizer.normalize(arrival.url.path)
        let names = arrival.candidateNames
        return outcomes.contains { outcome in
            if outcome.trashedTo.contains(where: { PathNormalizer.normalize($0) == path }) { return true }
            return outcome.category == .applications && abs(outcome.date.timeIntervalSince(arrival.date)) < 600
                && outcome.paths.contains { names.contains(URL(fileURLWithPath: $0).lastPathComponent.lowercased()) }
        }
    }

    // MARK: Détails

    /// L'identifiant qu'un reste porte : le plus long des identifiants de
    /// l'application qui préfixe son nom (`com.foo.app.helper.plist` est à
    /// l'assistant), le groupe d'un conteneur de groupe, sinon l'application.
    static func identifier(of leftover: Leftover, in app: InstalledApp) -> String {
        let name = leftover.url.lastPathComponent.lowercased()
        switch leftover.match {
        case .bundleID, .containerMetadata:
            let matching = app.allIDs.filter { id in
                let lower = id.lowercased()
                return name == lower || name.hasPrefix(lower + ".")
            }
            return matching.max { $0.count < $1.count } ?? app.bundleID ?? app.id
        case .applicationGroup:
            return Identifier.parseGroup(leftover.url.lastPathComponent).identifier
        case .launchAgentProgram, .name:
            return app.bundleID ?? app.id
        }
    }

    /// Les agents de lancement de l'application. Leur programme pointait dans
    /// son paquet, à l'endroit d'où il vient de partir : on les reconnaît à ce
    /// programme disparu, dans un paquet du même nom, ou à leur étiquette.
    static func launchAgents(of app: InstalledApp, names: Set<String>, in library: URL, home: URL,
                             excluding known: Set<String>) -> [Leftover] {
        let pathGuard = PathGuard(home: home)
        let ids = Set(app.allIDs.map { $0.lowercased() })
        var found: [Leftover] = []
        for (name, url) in OrphanFinder.entries(of: library.appendingPathComponent("LaunchAgents"))
        where name.hasSuffix(".plist") && !known.contains(url.path) && OrphanFinder.isRegularFile(url) {
            guard let plist = AppCatalog.plist(url), plist["BundleProgram"] == nil,
                  let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first,
                  program.hasPrefix("/"), !OrphanFinder.exists(program),
                  let bundle = OrphanFinder.enclosingApp(of: program), !OrphanFinder.exists(bundle),
                  !OrphanFinder.onMissingVolume(bundle) else { continue }
            let label = ((plist["Label"] as? String) ?? String(name.dropLast(".plist".count))).lowercased()
            let associated = (plist["AssociatedBundleIdentifiers"] as? [String]
                ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []).map { $0.lowercased() }
            let sameBundle = names.contains(URL(fileURLWithPath: bundle).lastPathComponent.lowercased())
            let sameLabel = ids.contains { label == $0 || label.hasPrefix($0 + ".") }
            guard sameBundle || sameLabel || associated.contains(where: ids.contains), pathGuard.allows(url) else { continue }
            var info = stat()
            lstat(url.path, &info)
            var leftover = Leftover(
                url: url, kind: .launchAgent, match: .launchAgentProgram, fileID: UInt64(info.st_ino),
                modificationDate: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            )
            leftover.preferenceHome = home
            found.append(leftover)
        }
        return found
    }
}
