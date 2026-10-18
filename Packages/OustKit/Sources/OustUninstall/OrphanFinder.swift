import CoreServices
import Darwin
import Foundation
import OustCore
import OustSafety
import OustScan
import Security

// MARK: - Ce qu'on trouve

/// Un reste d'application dont l'application n'est plus sur ce Mac.
public struct OrphanLeftover: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let kind: LeftoverKind
    /// L'identifiant dont le reste porte le nom (`com.foo.app` pour `com.foo.app.plist`).
    public let identifier: String
    public var sizes: Sizes
    public let fileID: UInt64
    public let modificationDate: Date?
    /// La date la plus récente dans tout ce qu'il contient, une fois mesuré.
    public var latestModification: Date?
    /// Pourquoi on ne peut pas le retirer, s'il y a une raison.
    public var protection: ProtectionReason?

    public init(url: URL, kind: LeftoverKind, identifier: String, sizes: Sizes = .zero, fileID: UInt64 = 0,
                modificationDate: Date? = nil, latestModification: Date? = nil, protection: ProtectionReason? = nil) {
        self.url = url
        self.kind = kind
        self.identifier = identifier
        self.sizes = sizes
        self.fileID = fileID
        self.modificationDate = modificationDate
        self.latestModification = latestModification
        self.protection = protection
    }

    /// La règle qui porte l'explication (`rule.orphan.<genre>.what`…).
    public var ruleID: String { "orphan.\(kind.rawValue)" }
}

/// Les restes d'une même application disparue : un identifiant et sa famille
/// (`com.foo.app`, ses extensions `com.foo.app.share`, son groupe).
public struct OrphanGroup: Sendable, Hashable, Identifiable {
    public var id: String { identifier }
    /// La racine de la famille.
    public let identifier: String
    /// Le nom de l'application, quand un agent de lancement le garde dans le
    /// chemin de son programme. Sinon on n'en sait rien, et on ne l'invente pas.
    public let appName: String?
    /// L'application est encore dans la corbeille du Mac (Launch Services la
    /// connaît là) : ce qu'elle a écrit ces derniers jours vient d'elle.
    public let ownerInTrash: Bool
    public var leftovers: [OrphanLeftover]

    public init(identifier: String, appName: String? = nil, ownerInTrash: Bool = false, leftovers: [OrphanLeftover]) {
        self.identifier = identifier
        self.appName = appName
        self.ownerInTrash = ownerInTrash
        self.leftovers = leftovers
    }

    public var title: String { appName ?? identifier }

    /// Ce que rendrait tout ce qu'on peut cocher.
    public var freeable: Int64 {
        leftovers.filter { $0.protection == nil }.reduce(0) { $0 + $1.sizes.freeable }
    }

    public var isFullyProtected: Bool { leftovers.allSatisfy { $0.protection != nil } }
}

// MARK: - Où chercher les applications qui restent

/// Ce que la signature d'un paquet déclare : son équipe et ses groupes.
public struct SigningFacts: Sendable, Hashable {
    public var teamID: String?
    public var groups: [String]

    public init(teamID: String? = nil, groups: [String] = []) {
        self.teamID = teamID
        self.groups = groups
    }
}

extension Entitlements {
    /// L'équipe et les groupes d'une signature, lus ensemble (0,4 s pour 128
    /// applications le 18/10/2026 : rien n'est vérifié, seulement lu).
    public static func signingFacts(of url: URL) -> SigningFacts {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return SigningFacts()
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return SigningFacts() }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return SigningFacts(
            teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            groups: entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        )
    }
}

/// Tout ce qui peut revendiquer un reste, en plus des applications du désinstalleur.
///
/// La liste est longue parce qu'une application vit rarement à un seul endroit :
/// un jeu Steam dans `Application Support`, un assistant Logitech dans
/// `/Library/Application Support`, une application iPad enveloppée dans
/// `/Applications`, une application en développement dans `DerivedData`. Le
/// 18/10/2026, sur le Mac de Romain, oublier les deux derniers aurait proposé
/// le conteneur de GestImmio et celui de l'application iPad de son prompteur.
public struct OrphanSources: Sendable {
    /// Les dossiers d'applications (premier niveau et un sous-dossier).
    public var appRoots: [URL]
    /// Les dossiers de modules (préférences système, Quick Look, plug-ins audio…),
    /// lus au premier niveau.
    public var pluginRoots: [URL]
    /// Les dossiers où des applications s'installent hors d'Applications ; on y
    /// cherche des `.app` sur quatre niveaux.
    public var helperRoots: [URL]
    /// Les dossiers dont chaque entrée porte un identifiant (démons, outils privilégiés).
    public var labelRoots: [URL]
    /// Les copies d'une application que Launch Services connaît, où qu'elles soient.
    public var registeredApps: @Sendable (String) -> [URL]
    public var signature: @Sendable (URL) -> SigningFacts
    /// Les exécutables qui tournent en ce moment.
    public var runningExecutables: @Sendable () -> [String]
    /// Lire la fiche d'un conteneur sans l'Accès complet au disque peut faire
    /// surgir l'invite « accéder aux données d'autres apps » : sans lui, on ne
    /// la lit pas, et le conteneur est montré protégé.
    public var canReadContainers: Bool

    public init(appRoots: [URL] = [], pluginRoots: [URL] = [], helperRoots: [URL] = [], labelRoots: [URL] = [],
                registeredApps: @escaping @Sendable (String) -> [URL] = { _ in [] },
                signature: @escaping @Sendable (URL) -> SigningFacts = { _ in SigningFacts() },
                runningExecutables: @escaping @Sendable () -> [String] = { [] },
                canReadContainers: Bool) {
        self.appRoots = appRoots
        self.pluginRoots = pluginRoots
        self.helperRoots = helperRoots
        self.labelRoots = labelRoots
        self.registeredApps = registeredApps
        self.signature = signature
        self.runningExecutables = runningExecutables
        self.canReadContainers = canReadContainers
    }

    public static func standard(home: URL, canReadContainers: Bool) -> OrphanSources {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let system = URL(fileURLWithPath: "/Library", isDirectory: true)
        let plugins = [
            "PreferencePanes", "Screen Savers", "QuickLook", "Spotlight", "Internet Plug-Ins", "Input Methods",
            "Services", "Mail/Bundles", "Audio/Plug-Ins/Components", "Audio/Plug-Ins/HAL", "Audio/Plug-Ins/VST",
            "Audio/Plug-Ins/VST3", "Address Book Plug-Ins", "Contextual Menu Items", "ColorPickers", "PDF Services",
            "Extensions",
        ]
        return OrphanSources(
            appRoots: AppCatalog.standardRoots(home: home) + [URL(fileURLWithPath: "/System/Applications", isDirectory: true)],
            pluginRoots: plugins.flatMap { [system.appendingPathComponent($0), library.appendingPathComponent($0)] },
            helperRoots: [
                system.appendingPathComponent("Application Support"), library.appendingPathComponent("Application Support"),
                URL(fileURLWithPath: "/Users/Shared", isDirectory: true), home.appendingPathComponent("Games"),
            ],
            labelRoots: [
                system.appendingPathComponent("LaunchDaemons"), system.appendingPathComponent("LaunchAgents"),
                system.appendingPathComponent("PrivilegedHelperTools"),
            ],
            registeredApps: { id in
                (LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
            },
            signature: Entitlements.signingFacts(of:),
            runningExecutables: { ProcessSnapshot.current().processes.map(\.executablePath).filter { !$0.isEmpty } },
            canReadContainers: canReadContainers
        )
    }
}

// MARK: - La recherche

/// Trouve les restes des applications qui ne sont plus installées.
///
/// Un reste n'est proposé que si tout concorde : il porte un identifiant
/// d'application (pas un nom, pas un dossier de bibliothèque partagée), aucune
/// application ni aucun module présent ne le revendique, Launch Services ne
/// connaît aucune copie de l'application, et rien ne s'en sert. Au moindre
/// doute, il est montré protégé (un éditeur dont une autre application est
/// installée, une fiche de conteneur illisible), ou n'est pas montré du tout
/// (RULES.md, règle 3). Jamais coché d'office : un dossier d'une application
/// disparue peut garder des documents, des parties sauvegardées, des réglages
/// qu'on voudra retrouver en la réinstallant (règle 4).
public enum OrphanFinder {

    /// Ce que l'on cherche. Pas les caches : la règle « Caches d'applications »
    /// (Système) les propose déjà tous, installés ou non, et un même dossier
    /// coché à deux endroits serait compté deux fois (RULES.md, règle 9).
    public static let kinds: [LeftoverKind] = [
        .applicationSupport, .preferences, .container, .groupContainer, .savedState, .httpStorage, .webKit, .logs,
        .launchAgent,
    ]

    public static func orphans(home: URL, installed: [InstalledApp], sources: OrphanSources) -> [OrphanGroup] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var candidates = collect(in: library, canReadContainers: sources.canReadContainers)
        let agents = launchAgents(in: library)
        candidates += agents.orphans

        let folders = candidateFolders(in: library)
        var claims = Claims(candidateFolders: folders)
        claims.add(installed: installed, sources: sources)
        claims.addBundles(in: sources, installed: installed)
        claims.addLabels(in: sources.labelRoots)
        for agent in agents.live { claims.addLive(agent) }
        claims.addRunning(sources.runningExecutables())

        // Launch Services en dernier : une application lancée une fois, même
        // depuis `DerivedData` ou un disque externe, y est connue.
        let identifiers = Set(candidates.flatMap { [$0.identifier] + $0.associated })
        var trashed = Set<String>()
        for identifier in identifiers.sorted() {
            for url in sources.registeredApps(identifier) {
                if Claims.stillThere(url) {
                    claims.add(registered: url, identifier: identifier, signature: sources.signature)
                } else if Claims.inTrash(url) {
                    trashed.insert(identifier.lowercased())
                }
            }
        }

        let pathGuard = PathGuard(home: home)
        var kept: [Candidate] = []
        for var candidate in candidates {
            guard pathGuard.allows(candidate.url) else { continue }
            if candidate.associated.contains(where: { claims.owner(of: $0) != nil }) { continue }
            if let name = candidate.appName, claims.hasApplication(named: name) { continue }
            if claims.owner(of: candidate.identifier) != nil { continue }
            if let group = candidate.group, claims.groups.contains(group.lowercased()) { continue }
            if candidate.protection == nil {
                if let team = candidate.team, let owner = claims.teams[team] {
                    candidate.protection = .relatedAppInstalled(name: owner)
                } else if let owner = claims.publisher(of: candidate.identifier)
                            ?? claims.applicationNamed(inside: candidate.identifier) {
                    candidate.protection = .relatedAppInstalled(name: owner)
                }
            }
            candidate.ownerInTrash = trashed.contains(candidate.identifier.lowercased())
            kept.append(candidate)
        }
        return grouped(kept)
    }

    /// Mesure les restes, puis protège ce que quelque chose utilise encore : un
    /// fichier ouvert dedans, une modification récente. Une application
    /// disparue n'écrit plus ; si quelqu'un écrit, c'est qu'elle n'a pas
    /// disparu, ou que le dossier n'était pas le sien. Le 18/10/2026, sur le Mac
    /// de Romain, les préférences `com.discord.discord.ShipIt` (Discord est
    /// installé sous `com.hnc.Discord`) et `ai.openclaw.shared` (un outil en
    /// ligne de commande) avaient deux jours : vingt-quatre heures n'auraient
    /// pas suffi. Seule exception : l'application est dans la corbeille du Mac,
    /// et ce qu'elle a écrit avant d'y partir vient d'elle.
    public static func measured(
        _ groups: [OrphanGroup], canReadContainers: Bool, recencyDays: Int = 7, now: Date = Date(),
        openPaths: @Sendable (URL) -> Set<String> = { OpenFiles.paths(under: $0.path) },
        holder: @Sendable (URL) -> String? = { OpenFiles.holders(under: $0.path).first?.name }
    ) async -> [OrphanGroup] {
        let all = groups.flatMap(\.leftovers)
        // Sans l'Accès complet au disque, mesurer un conteneur, c'est le lire.
        let urls = all.filter { canReadContainers || !$0.kind.isContainer }.map(\.url)
        let measures = await Scanner.measure(urls)
        let library = commonLibrary(of: all.map(\.url))
        let open = library.map(openPaths) ?? []
        return groups.map { group in
            var group = group
            group.leftovers = group.leftovers.map { leftover in
                var leftover = leftover
                if let measure = measures[leftover.url] {
                    leftover.sizes = measure.sizes
                    leftover.latestModification = measure.latestModification
                    if measure.inaccessible, leftover.protection == nil { leftover.protection = .needsFullDiskAccess }
                }
                guard leftover.protection == nil else { return leftover }
                if open.contains(where: { PathNormalizer.isWithin($0, leftover.url.path) }) {
                    leftover.protection = .activeProcess(name: holder(leftover.url) ?? leftover.identifier)
                } else if !group.ownerInTrash,
                          let latest = [leftover.modificationDate, leftover.latestModification].compactMap({ $0 }).max(),
                          now.timeIntervalSince(latest) < Double(recencyDays) * 86_400 {
                    leftover.protection = .recentlyWritten(days: recencyDays)
                }
                return leftover
            }
            group.leftovers.sort { $0.sizes.allocated > $1.sizes.allocated }
            return group
        }
        .sorted { lhs, rhs in
            lhs.freeable != rhs.freeable ? lhs.freeable > rhs.freeable
                : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    // MARK: Candidats

    /// Un reste possible, avant qu'on vérifie que personne ne le revendique.
    struct Candidate: Sendable {
        var url: URL
        var kind: LeftoverKind
        /// L'identifiant d'application qu'il porte.
        var identifier: String
        var protection: ProtectionReason?
        /// Un conteneur de groupe : son nom complet et l'équipe qui le préfixe.
        var group: String?
        var team: String?
        /// Un agent : le nom de l'application disparue, et les identifiants qu'il
        /// déclare (`AssociatedBundleIdentifiers`), qui doivent être libres aussi.
        var appName: String?
        var associated: [String] = []
        /// Launch Services connaît l'application, dans une corbeille.
        var ownerInTrash = false
    }

    static func collect(in library: URL, canReadContainers: Bool) -> [Candidate] {
        var found: [Candidate] = []
        func add(_ url: URL, _ kind: LeftoverKind, _ identifier: String, protection: ProtectionReason? = nil,
                 group: String? = nil, team: String? = nil) {
            guard Identifier.isApplication(identifier), !isSymbolicLink(url) else { return }
            found.append(Candidate(url: url, kind: kind, identifier: identifier, protection: protection,
                                   group: group, team: team))
        }

        for (name, url) in entries(of: library.appendingPathComponent("Application Support")) {
            add(url, .applicationSupport, name)
        }
        let preferences = library.appendingPathComponent("Preferences")
        for (name, url) in entries(of: preferences) where name.hasSuffix(".plist") && isRegularFile(url) {
            add(url, .preferences, String(name.dropLast(".plist".count)))
        }
        for (name, url) in entries(of: preferences.appendingPathComponent("ByHost")) {
            if let identifier = byHostIdentifier(name), isRegularFile(url) { add(url, .preferences, identifier) }
        }
        for (name, url) in entries(of: library.appendingPathComponent("Saved Application State"))
        where name.hasSuffix(".savedState") {
            add(url, .savedState, String(name.dropLast(".savedState".count)))
        }
        for (name, url) in entries(of: library.appendingPathComponent("HTTPStorages")) {
            add(url, .httpStorage, name.hasSuffix(".binarycookies") ? String(name.dropLast(".binarycookies".count)) : name)
        }
        for (name, url) in entries(of: library.appendingPathComponent("WebKit")) where isDirectory(url) {
            add(url, .webKit, name)
        }
        for (name, url) in entries(of: library.appendingPathComponent("Logs")) {
            add(url, .logs, name.hasSuffix(".log") ? String(name.dropLast(".log".count)) : name)
        }

        // Les conteneurs : le nom du dossier ne suffit pas, containermanagerd doit
        // dire à qui il est. Illisible, il est montré, jamais proposé.
        for (name, url) in entries(of: library.appendingPathComponent("Containers")) where isDirectory(url) {
            guard Identifier.isApplication(name) else { continue }
            guard canReadContainers else { add(url, .container, name, protection: .needsFullDiskAccess); continue }
            switch LeftoverFinder.containerIdentifier(of: url) {
            case .some(let identifier) where identifier.lowercased() == name.lowercased(): add(url, .container, name)
            case .some: continue
            case .none: add(url, .container, name, protection: .needsFullDiskAccess)
            }
        }
        for (name, url) in entries(of: library.appendingPathComponent("Group Containers")) where isDirectory(url) {
            // « 2BUA8C4S2C.com.agilebits », « group.com.foo.shared » : ce qui suit
            // l'équipe et « group. » doit être un identifiant d'application ;
            // « UBF8T346G9.Office » n'en est pas un, on n'y touche pas.
            let parsed = Identifier.parseGroup(name)
            guard Identifier.isApplication(parsed.identifier) else { continue }
            guard canReadContainers else {
                add(url, .groupContainer, parsed.identifier, protection: .needsFullDiskAccess, group: name, team: parsed.team)
                continue
            }
            switch LeftoverFinder.containerIdentifier(of: url) {
            case .some(let identifier) where identifier.lowercased() == name.lowercased():
                add(url, .groupContainer, parsed.identifier, group: name, team: parsed.team)
            case .some: continue
            case .none:
                add(url, .groupContainer, parsed.identifier, protection: .needsFullDiskAccess, group: name, team: parsed.team)
            }
        }
        return found
    }

    /// Les dossiers de `Application Support` nommés d'après un identifiant
    /// (chemin normalisé → identifiant). Un paquet rangé dedans ne revendique que
    /// sa propre famille : « com.imobie.AnyTrans/AirBackupHelper.app » est un
    /// reste d'AnyTrans parmi les autres, pas la preuve qu'iMobie est encore là
    /// (le cas s'est présenté sur le Mac de Romain le 18/10/2026).
    static func candidateFolders(in library: URL) -> [String: String] {
        var folders: [String: String] = [:]
        for (name, url) in entries(of: library.appendingPathComponent("Application Support"))
        where Identifier.isApplication(name) {
            folders[PathNormalizer.normalize(url.path)] = name.lowercased()
        }
        return folders
    }

    // MARK: Agents de lancement

    struct AgentScan: Sendable {
        /// Les agents dont l'application a disparu.
        var orphans: [Candidate] = []
        /// Ceux dont le programme est toujours là : ils revendiquent leur
        /// identifiant et celui du paquet qu'ils lancent.
        var live: [LiveAgent] = []
    }

    struct LiveAgent: Sendable {
        var label: String
        var program: String
        var associated: [String]
    }

    /// Un agent est orphelin quand son programme vivait dans un paquet `.app` qui
    /// n'existe plus. Un programme hors d'un paquet (un outil Homebrew, un
    /// script), un paquet présent dont le programme manque (une mise à jour en
    /// cours), un disque externe débranché : on ne sait pas, on ne propose pas.
    static func launchAgents(in library: URL) -> AgentScan {
        var scan = AgentScan()
        for (name, url) in entries(of: library.appendingPathComponent("LaunchAgents"))
        where name.hasSuffix(".plist") && isRegularFile(url) {
            guard let plist = AppCatalog.plist(url) else { continue }
            let label = (plist["Label"] as? String) ?? String(name.dropLast(".plist".count))
            let associated = plist["AssociatedBundleIdentifiers"] as? [String]
                ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
            // Un agent déclaré par `SMAppService` vit dans le paquet de son application.
            guard plist["BundleProgram"] == nil else { continue }
            guard let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first,
                  program.hasPrefix("/") else { continue }
            if exists(program) {
                scan.live.append(LiveAgent(label: label, program: program, associated: associated))
                continue
            }
            guard !label.lowercased().contains("com.apple"),
                  let bundle = enclosingApp(of: program), !exists(bundle), !onMissingVolume(bundle) else { continue }
            let appName = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
            scan.orphans.append(Candidate(
                url: url, kind: .launchAgent, identifier: label, appName: appName, associated: associated
            ))
        }
        return scan
    }

    /// Le paquet `.app` le plus extérieur d'un chemin, s'il y en a un.
    static func enclosingApp(of path: String) -> String? {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            components.append(String(component))
            if component.hasSuffix(".app") { return "/" + components.joined(separator: "/") }
        }
        return nil
    }

    /// Sur `/Volumes/<disque>` alors que ce disque n'est pas branché.
    static func onMissingVolume(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !exists("/Volumes/\(parts[1])")
    }

    // MARK: Regroupement

    /// Une famille par racine : `com.foo.app`, puis tout ce qui commence par
    /// `com.foo.app.`. Les agents sans identifiant forment leur propre famille.
    static func grouped(_ candidates: [Candidate]) -> [OrphanGroup] {
        var roots: [(key: String, identifier: String, appName: String?, inTrash: Bool, members: [Candidate])] = []
        let ordered = candidates.sorted { $0.identifier.count != $1.identifier.count
            ? $0.identifier.count < $1.identifier.count : $0.url.path < $1.url.path }
        for candidate in ordered {
            let key = candidate.identifier.lowercased()
            if let index = roots.firstIndex(where: { key == $0.key || key.hasPrefix($0.key + ".") }) {
                roots[index].members.append(candidate)
                roots[index].inTrash = roots[index].inTrash || candidate.ownerInTrash
                if roots[index].appName == nil, let name = candidate.appName {
                    roots[index].appName = name
                }
            } else {
                roots.append((key, candidate.identifier, candidate.appName, candidate.ownerInTrash, [candidate]))
            }
        }
        return roots.map { root in
            OrphanGroup(identifier: root.identifier, appName: root.appName, ownerInTrash: root.inTrash,
                        leftovers: root.members.map { candidate in
                var info = stat()
                lstat(candidate.url.path, &info)
                return OrphanLeftover(
                    url: candidate.url, kind: candidate.kind, identifier: candidate.identifier,
                    fileID: UInt64(info.st_ino),
                    modificationDate: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                    protection: candidate.protection
                )
            })
        }
    }

    // MARK: Outils

    static func entries(of folder: URL) -> [(name: String, url: URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { ($0, folder.appendingPathComponent($0)) }
    }

    /// `<identifiant>.<identifiant matériel>.plist` : un UUID ou une adresse matérielle.
    static func byHostIdentifier(_ name: String) -> String? {
        guard name.hasSuffix(".plist") else { return nil }
        let stem = name.dropLast(".plist".count)
        guard let dot = stem.lastIndex(of: ".") else { return nil }
        let host = stem[stem.index(after: dot)...]
        guard (12...36).contains(host.count), host.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return String(stem[..<dot])
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Le `Library` commun des restes, pour un seul relevé des fichiers ouverts.
    static func commonLibrary(of urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        var library = first
        while library.lastPathComponent != "Library", library.path != "/" { library.deleteLastPathComponent() }
        return library.path == "/" ? nil : library
    }
}

extension LeftoverKind {
    var isContainer: Bool { self == .container || self == .groupContainer }

    /// Sans l'application, un reste ne se reconstruit pas tout seul : seule la
    /// corbeille du Mac le rend. Ce qui ne servait qu'à elle ne manque à personne.
    var orphanRebuild: RebuildCost {
        switch self {
        case .savedState, .logs, .httpStorage, .cookies, .launchAgent, .caches: .nothing
        case .applicationSupport, .preferences, .container, .groupContainer, .webKit, .applicationScripts: .irreversible
        }
    }
}

// MARK: - Ce qui revendique

/// Les identifiants revendiqués par ce qui est encore sur le Mac.
struct Claims: Sendable {
    /// Les dossiers à juger comme restes (voir `OrphanFinder.candidateFolders`).
    let candidateFolders: [String: String]
    /// Identifiant en minuscules → ce qui le revendique (pour l'afficher).
    private(set) var owners: [String: String] = [:]
    /// Chaque préfixe d'au moins trois composants d'un identifiant revendiqué :
    /// `com.foo.app` est revendiqué dès que `com.foo.app.helper` l'est.
    private(set) var ancestors: [String: String] = [:]
    private(set) var publishers: [String: String] = [:]
    private(set) var groups: Set<String> = []
    private(set) var teams: [String: String] = [:]
    /// Les noms d'applications présentes (pour les agents, qui ne donnent que ça).
    private(set) var names: [String: String] = [:]
    /// Les noms des applications elles-mêmes, réduits à leurs lettres et chiffres
    /// (« Discord » → « discord »), pour les reconnaître dans un identifiant.
    private(set) var applicationNames: [String: String] = [:]

    mutating func claim(_ identifier: String, by owner: String) {
        let lower = identifier.lowercased()
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts.contains(where: \.isEmpty) else { return }
        if owners[lower] == nil { owners[lower] = owner }
        if parts.count > 3 {
            for count in 3..<parts.count {
                let prefix = parts.prefix(count).joined(separator: ".")
                if ancestors[prefix] == nil { ancestors[prefix] = owner }
            }
        }
        let publisher = Identifier.publisher(lower)
        if publishers[publisher] == nil { publishers[publisher] = owner }
    }

    mutating func claimName(_ name: String, by owner: String) {
        let key = name.lowercased()
        guard !key.isEmpty, names[key] == nil else { return }
        names[key] = owner
    }

    mutating func claim(signature facts: SigningFacts, by owner: String) {
        for group in facts.groups { groups.insert(group.lowercased()) }
        if let team = facts.teamID, !team.isEmpty, teams[team] == nil { teams[team] = owner }
    }

    init(candidateFolders: [String: String] = [:]) {
        self.candidateFolders = candidateFolders
    }

    /// Qui revendique cet identifiant, lui ou un parent, ou un enfant.
    func owner(of identifier: String) -> String? {
        let lower = identifier.lowercased()
        if let owner = owners[lower] ?? ancestors[lower] { return owner }
        let parts = lower.split(separator: ".")
        guard parts.count > 3 else { return nil }
        for count in stride(from: parts.count - 1, through: 3, by: -1) {
            if let owner = owners[parts.prefix(count).joined(separator: ".")] { return owner }
        }
        return nil
    }

    /// Une application du même éditeur, s'il y en a une.
    func publisher(of identifier: String) -> String? { publishers[Identifier.publisher(identifier)] }

    func hasApplication(named name: String) -> Bool { names[name.lowercased()] != nil }

    /// Une application installée dont le nom est un composant de l'identifiant :
    /// `com.discord.discord.ShipIt` alors que Discord est installé sous
    /// `com.hnc.Discord`. Les mots trop courts ou trop génériques ne comptent pas.
    func applicationNamed(inside identifier: String) -> String? {
        for component in identifier.split(separator: ".").dropFirst() {
            let key = Self.reduced(String(component))
            if let owner = applicationNames[key] { return owner }
        }
        return nil
    }

    mutating func registerApplicationName(_ name: String) {
        let key = Self.reduced(name)
        guard key.count >= 4, !Self.genericNames.contains(key), applicationNames[key] == nil else { return }
        applicationNames[key] = name
    }

    static func reduced(_ text: String) -> String {
        String(text.lowercased().filter { ($0.isLetter || $0.isNumber) && $0.isASCII })
    }

    static let genericNames: Set<String> = [
        "macos", "desktop", "helper", "agent", "client", "service", "services", "shared", "updater", "update",
        "installer", "launcher", "extension", "widgets", "widget", "plugin", "main", "core", "shipit", "application",
    ]

    /// Un paquet rangé dans un dossier à juger comme reste ne revendique que la
    /// famille de ce dossier.
    func mayClaim(_ identifier: String, from bundle: URL) -> Bool {
        let path = PathNormalizer.normalize(bundle.path)
        for (folder, family) in candidateFolders where PathNormalizer.isWithin(path, folder) {
            return Identifier.sameFamily(identifier, family)
        }
        return true
    }

    // MARK: Sources

    mutating func add(installed: [InstalledApp], sources: OrphanSources) {
        for app in installed {
            for id in app.allIDs { claim(id, by: app.name) }
            for name in [app.name, app.url.deletingPathExtension().lastPathComponent] + app.names {
                claimName(name, by: app.name)
            }
            registerApplicationName(app.name)
            for group in app.applicationGroups { groups.insert(group.lowercased()) }
            // Apple comprise : Raccourcis déclare `group.is.workflow.my.app`, sans « com.apple ».
            claim(signature: sources.signature(app.url), by: app.name)
        }
    }

    /// Les paquets des dossiers d'applications que le désinstalleur n'a pas su
    /// lire (une application iPad enveloppée), les modules et les assistants
    /// installés ailleurs.
    mutating func addBundles(in sources: OrphanSources, installed: [InstalledApp]) {
        let known = Set(installed.map { PathNormalizer.normalize($0.url.resolvingSymlinksInPath().path) })
        let unread = AppCatalog.bundles(in: sources.appRoots).filter {
            !known.contains(PathNormalizer.normalize($0.resolvingSymlinksInPath().path))
        }
        for bundle in unread { registerApplicationName(bundle.deletingPathExtension().lastPathComponent) }
        var bundles = unread
        for root in sources.pluginRoots { bundles += OrphanFinder.entries(of: root).map(\.url) }
        // Cinq niveaux : `Application Support/Steam/steamapps/common/<jeu>/<jeu>.app`.
        for root in sources.helperRoots { bundles += Self.applications(under: root, depth: 5) }
        for bundle in bundles { add(bundle: bundle, signature: sources.signature) }
    }

    mutating func add(bundle: URL, signature: (URL) -> SigningFacts) {
        guard let identifier = Self.bundleIdentifier(of: bundle), mayClaim(identifier, from: bundle) else { return }
        let name = bundle.deletingPathExtension().lastPathComponent
        claim(identifier, by: name)
        claimName(name, by: name)
        guard bundle.pathExtension == "app" else { return }
        claim(signature: signature(bundle), by: name)
        // Les paquets embarqués d'Apple ne portent que des identifiants d'Apple,
        // qu'aucun candidat ne porte : inutile de les parcourir.
        guard !identifier.lowercased().hasPrefix("com.apple.") else { return }
        for embedded in AppCatalog.embeddedBundles(in: bundle.appendingPathComponent("Contents")) {
            if let id = embedded.identifier { claim(id, by: name) }
        }
    }

    mutating func add(registered url: URL, identifier: String, signature: (URL) -> SigningFacts) {
        guard mayClaim(identifier, from: url) else { return }
        claim(identifier, by: url.deletingPathExtension().lastPathComponent)
        registerApplicationName(url.deletingPathExtension().lastPathComponent)
        if OrphanFinder.exists(url.path) { add(bundle: url, signature: signature) }
    }

    mutating func addLabels(in roots: [URL]) {
        for root in roots {
            for (name, url) in OrphanFinder.entries(of: root) {
                guard name.hasSuffix(".plist") else {
                    // Un outil privilégié : son nom est son identifiant.
                    claim(name, by: name)
                    continue
                }
                let label = String(name.dropLast(".plist".count))
                let plist = AppCatalog.plist(url) ?? [:]
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                // Un démon dont le programme a disparu ne prouve rien ; les autres,
                // si : quelque chose de cet éditeur est installé pour tout le Mac.
                if let program, program.hasPrefix("/"), !OrphanFinder.exists(program) { continue }
                claim(label, by: label)
                if let program { addProgram(program) }
            }
        }
    }

    mutating func addLive(_ agent: OrphanFinder.LiveAgent) {
        claim(agent.label, by: agent.label)
        for id in agent.associated { claim(id, by: agent.label) }
        addProgram(agent.program)
    }

    mutating func addRunning(_ executables: [String]) {
        for executable in executables { addProgram(executable) }
    }

    /// Le paquet qui contient un programme le revendique.
    mutating func addProgram(_ program: String) {
        guard let bundle = OrphanFinder.enclosingApp(of: program) else { return }
        let url = URL(fileURLWithPath: bundle)
        guard let identifier = Self.bundleIdentifier(of: url) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        claim(identifier, by: name)
        claimName(name, by: name)
    }

    // MARK: Lecture des paquets

    /// L'identifiant d'un paquet : `Contents/Info.plist`, sinon celui d'une
    /// application iPad enveloppée (`Wrapper/<nom>.app/Info.plist`), sinon un
    /// paquet à plat.
    static func bundleIdentifier(of bundle: URL) -> String? {
        func read(_ url: URL) -> String? {
            (AppCatalog.plist(url)?["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let id = read(bundle.appendingPathComponent("Contents/Info.plist")) { return id }
        let wrapper = bundle.appendingPathComponent("Wrapper")
        for (name, url) in OrphanFinder.entries(of: wrapper) where name.hasSuffix(".app") {
            if let id = read(url.appendingPathComponent("Info.plist")) { return id }
        }
        return read(bundle.appendingPathComponent("Info.plist"))
    }

    /// Les `.app` sous un dossier, sans descendre dans un paquet ni plus bas
    /// que `depth` niveaux. Les dossiers d'Apple et les sauvegardes iOS, immenses
    /// et sans application, sont sautés.
    static func applications(under root: URL, depth: Int) -> [URL] {
        var found: [URL] = []
        var queue: [(URL, Int)] = [(root, 1)]
        var index = 0
        var visited = 0
        while index < queue.count, visited < 60_000 {
            let (folder, level) = queue[index]
            index += 1
            for (name, url) in OrphanFinder.entries(of: folder) {
                visited += 1
                guard OrphanFinder.isDirectory(url) else { continue }
                if name.lowercased().hasPrefix("com.apple") || name == "MobileSync" { continue }
                if name.hasSuffix(".app") {
                    found.append(url)
                } else if level < depth, !AppCatalog.isPackage(url) {
                    queue.append((url, level + 1))
                }
            }
        }
        return found
    }

    /// Une copie connue de Launch Services qui existe encore, ailleurs que dans
    /// une corbeille ; ou sur un disque externe débranché, qu'on ne peut pas
    /// vérifier.
    static func stillThere(_ url: URL) -> Bool {
        let path = url.path
        if inTrash(url) { return false }
        return OrphanFinder.exists(path) || OrphanFinder.onMissingVolume(path)
    }

    static func inTrash(_ url: URL) -> Bool {
        url.path.contains("/.Trash/") || url.path.contains("/.Trashes/")
    }
}

// MARK: - Identifiants

/// Ce qui ressemble à un identifiant d'application, et ce qui n'en a que l'air.
enum Identifier {

    /// Un identifiant d'application : un domaine inversé d'au moins trois
    /// composants, qui commence par un domaine de premier niveau, sans jeton
    /// aléatoire, ni Apple, ni bibliothèque partagée, ni ce qu'une autre
    /// section traite (navigateurs), ni ce qui entoure des secrets.
    ///
    /// Le 18/10/2026, sans ces filtres, `org.cups.PrintingPrefs`,
    /// `com.segment.storage.<jeton>`, `com.firebase.FIRInstallations` et vingt
    /// `Acme.GuidanceChecks.<UUID>` passaient pour des applications disparues.
    static func isApplication(_ identifier: String) -> Bool {
        guard identifier.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9_-]+){2,}/) != nil else { return false }
        let lower = identifier.lowercased()
        let parts = lower.split(separator: ".").map(String.init)
        guard let first = parts.first, isTopLevelDomain(first) else { return false }
        if lower.contains("com.apple") { return false }
        if parts.contains(where: isToken) { return false }
        if sharedNamespaces.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }) { return false }
        if Exclusions.passwordManagerIDs.contains(where: { lower.hasPrefix($0) })
            || Exclusions.vpnIDs.contains(where: { lower.hasPrefix($0) })
            || secretMarkers.contains(where: { lower.contains($0) }) || lower.contains("vpn") {
            return false
        }
        return true
    }

    /// L'un est l'autre, ou son parent : `com.foo.app` et `com.foo.app.share`.
    static func sameFamily(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.lowercased()
        let b = rhs.lowercased()
        return a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }

    /// L'éditeur : les deux premiers composants (`com.adobe`).
    static func publisher(_ identifier: String) -> String {
        identifier.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// `TEAMID.group.com.foo` → (`com.foo`, `TEAMID`).
    static func parseGroup(_ name: String) -> (identifier: String, team: String?) {
        var rest = Substring(name)
        var team: String?
        if let dot = rest.firstIndex(of: "."), rest.distance(from: rest.startIndex, to: dot) == 10,
           rest[..<dot].allSatisfy({ ($0.isUppercase || $0.isNumber) && $0.isASCII }) {
            team = String(rest[..<dot])
            rest = rest[rest.index(after: dot)...]
        }
        for prefix in ["group.", "groups."] where rest.lowercased().hasPrefix(prefix) {
            rest = rest.dropFirst(prefix.count)
        }
        return (String(rest), team)
    }

    static func isTopLevelDomain(_ component: String) -> Bool {
        (component.count == 2 && component.allSatisfy { $0.isLetter && $0.isASCII }) || genericDomains.contains(component)
    }

    /// Un UUID, une empreinte, un jeton : la marque d'une instance, pas d'une application.
    static func isToken(_ component: String) -> Bool {
        if component.count >= 16 && component.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return true }
        let letters = component.filter(\.isLetter)
        let digits = component.filter(\.isNumber)
        return component.count >= 20 && digits.count >= 3 && letters.contains(where: \.isUppercase)
            && letters.contains(where: \.isLowercase)
    }

    static let genericDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "int", "mil", "app", "dev", "info", "biz", "pro", "xyz", "tech",
        "studio", "design", "software", "company", "systems", "digital", "tools", "games", "cloud", "online",
        "site", "space", "works", "network", "solutions", "life", "live", "one", "page", "zone", "inc", "llc",
    ]

    /// Des bibliothèques que des applications installées partagent (rapports de
    /// plantage, mesure d'audience, mises à jour, moteurs web), des outils sans
    /// application (CUPS, Swift, Python, l'émulateur Android), et ce que la
    /// section Navigateurs traite, mots de passe compris (SPEC §8). Oust! lui-même
    /// n'est jamais un reste.
    static let sharedNamespaces = [
        "com.crashlytics", "io.fabric", "com.firebase", "com.google.firebase", "com.segment", "com.mixpanel",
        "com.amplitude", "io.sentry", "com.getsentry", "com.bugsnag", "com.plausiblelabs", "net.hockeyapp",
        "com.hockeyapp", "com.microsoft.appcenter", "com.appsflyer", "com.braze", "com.instabug",
        "org.sparkle-project", "com.github.electron", "com.electron", "org.chromium", "org.webkit", "org.swift",
        "org.llvm", "org.cups", "org.python", "org.openjdk", "com.oracle.java", "net.java", "com.android",
        "io.flutter", "org.gpgtools",
        // Raccourcis d'Apple garde le nom de Workflow, qu'Apple a racheté.
        "is.workflow",
        "com.google.chrome", "com.brave.browser", "com.microsoft.edgemac", "com.vivaldi", "com.operasoftware",
        "org.mozilla", "company.thebrowser", "app.zen-browser", "org.torproject",
        "fr.meaillais.oust",
    ]

    /// Ce qui entoure des secrets, quel que soit l'éditeur (comme pour les caches).
    static let secretMarkers = [
        "1password", "agilebits", "bitwarden", "lastpass", "dashlane", "keepass", "enpass", "keeper", "nordpass",
        "roboform", "strongbox", "protonpass", "proton.pass", "keychain", "authenticator", "passbolt", "password",
    ]
}

// MARK: - Vers la corbeille

extension OrphanLeftover {
    /// Un reste orphelin comme élément de la corbeille d'Oust!. Toujours « à
    /// examiner », jamais coché d'office, toujours à la corbeille du Mac.
    public func cleanupItem(in group: OrphanGroup) -> CleanupItem {
        CleanupItem(
            id: "orphan|\(url.path)", title: url.lastPathComponent, detail: url.deletingLastPathComponent().path,
            paths: [url], category: .appLeftovers, owner: group.title, ruleID: ruleID, safety: .review,
            protections: protection.map { [$0] } ?? [], method: .trash, sizes: sizes,
            lastActivity: latestModification ?? modificationDate, rebuild: kind.orphanRebuild,
            fingerprint: Fingerprint(modificationDate: modificationDate, fileID: fileID)
        )
    }
}
