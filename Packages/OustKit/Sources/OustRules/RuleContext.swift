import AppKit
import Foundation
import OustCore
import OustSafety
import OustScan

/// Ce qu'un chercheur a le droit de connaître du monde.
///
/// Le dossier personnel est passé ici et jamais lu ailleurs : les tests
/// fabriquent un faux dossier personnel dans un dossier temporaire, et les
/// chercheurs n'y voient que du feu (RULES.md, règle 8).
public struct RuleContext: Sendable {
    public var home: URL
    public var projectRoots: [URL]
    public var processes: ProcessSnapshot
    public var now: Date
    /// Au-delà, un historique d'agent est proposé (Claude Code purge lui-même à 30 jours).
    public var historyRetentionDays: Int
    /// Un fichier des Téléchargements est « gros » au-delà de cette taille.
    public var largeDownloadBytes: Int64
    /// L'arborescence de l'analyse, attendue au besoin : les chercheurs qui
    /// parcourent des dossiers l'interrogent au lieu de relire le disque.
    public var tree: (@Sendable () async -> TreeNode?)?
    /// Un projet que personne n'a touché depuis tant de jours est proposé à la compression.
    public var compressionAgeDays: Int
    /// Hors du dossier personnel : `/Applications` (Xcode, installeurs de macOS)
    /// et `/Library` (JDK). Les tests les remplacent par des dossiers temporaires.
    public var applications: URL
    public var systemLibrary: URL
    /// `/Users/Shared`, où GOG Galaxy et le lanceur d'Epic rangent caches et jeux,
    /// et le dossier temporaire de l'utilisateur (`$TMPDIR`), où Blender travaille.
    public var sharedFolder: URL
    public var temporaryDirectory: URL
    /// Les outils qu'on interroge (`xcode-select`, `brew`, `docker`…).
    public var tools: ToolRunner
    /// Les applications ouvertes, par identifiant de bundle.
    public var runningApps: Set<String>
    /// Le nom affiché d'une application d'après son identifiant de bundle.
    public var applicationName: @Sendable (String) -> String?
    /// Un autre disque que celui de démarrage : les chercheurs qui ont un sens
    /// sur un disque (artefacts, logiciels créatifs, bibliothèques de jeux,
    /// installeurs, corbeille du disque, traces de macOS) le parcourent au lieu
    /// du dossier personnel.
    public var volume: VolumeScope?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectRoots: [URL]? = nil,
        processes: ProcessSnapshot = .current(),
        now: Date = Date(),
        historyRetentionDays: Int = 30,
        largeDownloadBytes: Int64 = 500_000_000,
        compressionAgeDays: Int = 180,
        applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        systemLibrary: URL = URL(fileURLWithPath: "/Library", isDirectory: true),
        sharedFolder: URL = URL(fileURLWithPath: "/Users/Shared", isDirectory: true),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        tools: ToolRunner = .system,
        runningApps: Set<String>? = nil,
        applicationName: (@Sendable (String) -> String?)? = nil,
        tree: (@Sendable () async -> TreeNode?)? = nil,
        volume: VolumeScope? = nil
    ) {
        self.home = home
        self.volume = volume
        // Sur un autre disque, les projets sont partout : le disque entier est
        // la racine des projets.
        self.projectRoots = projectRoots ?? volume.map { [$0.root] } ?? RuleContext.defaultProjectRoots(home: home)
        self.processes = processes
        self.now = now
        self.historyRetentionDays = historyRetentionDays
        self.largeDownloadBytes = largeDownloadBytes
        self.tree = tree
        self.compressionAgeDays = compressionAgeDays
        self.applications = applications
        self.systemLibrary = systemLibrary
        self.sharedFolder = sharedFolder
        self.temporaryDirectory = temporaryDirectory
        self.tools = tools
        self.runningApps = runningApps ?? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        self.applicationName = applicationName ?? { identifier in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    /// Les dossiers où l'on range habituellement ses projets.
    public static func defaultProjectRoots(home: URL) -> [URL] {
        let names = ["Developpement", "Développement", "Developer", "Development", "Projects", "Projets",
                     "Code", "code", "dev", "Dev", "GitHub", "Github", "src", "Repos", "repos", "Workspace", "www"]
        let fileManager = FileManager.default
        var seen = Set<String>()
        return names.compactMap { name in
            let url = home.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let key = url.resolvingSymlinksInPath().path.lowercased()
            return seen.insert(key).inserted ? url : nil
        }
    }

    func path(_ relative: String) -> URL {
        home.appendingPathComponent(relative)
    }

    /// Le projet de premier niveau qui contient ce chemin (« boutique »,
    /// « meteo »), s'il est sous une racine de projets.
    func topLevelProject(containing path: String) -> URL? {
        let path = PathNormalizer.normalize(path)
        for root in projectRoots {
            let base = PathNormalizer.normalize(root.standardizedFileURL.path)
            guard path.hasPrefix(base + "/") else { continue }
            let relative = path.dropFirst(base.count + 1)
            guard let first = relative.split(separator: "/").first else { continue }
            return root.appendingPathComponent(String(first))
        }
        return nil
    }

    /// Un processus travaille-t-il dans le projet qui contient ce chemin ?
    ///
    /// Le projet entier, pas seulement le sous-dossier du marqueur : le
    /// 18/10/2026, `adb` tournait à la racine d'un projet, et le dossier
    /// `apps/mobile/android/app/build` n'en paraissait pas moins libre.
    func busyProject(containing path: String) -> ActiveProcess? {
        processes.busy(under: topLevelProject(containing: path)?.path ?? path)
    }
}

/// Un élément trouvé, avant mesure.
struct Candidate: Sendable {
    var item: CleanupItem
    /// Faut-il le mesurer ? Non quand l'outil donne déjà sa taille (simctl).
    var needsMeasure: Bool = true
    /// En dessous, l'élément n'est pas montré : cent caches d'applications de
    /// quelques kilo-octets noieraient les dix qui pèsent.
    var minimumAllocated: Int64 = 0
}

/// Lance les outils que les chercheurs interrogent.
///
/// Les tests le remplacent par des réponses écrites d'avance : un test ne doit
/// dépendre ni de ce qui est installé sur la machine, ni de ce que Docker y fait.
public struct ToolRunner: Sendable {
    /// Le premier exécutable présent parmi les candidats.
    public var locate: @Sendable (_ candidates: [String]) -> String?
    public var run: @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]?,
                               _ timeout: TimeInterval) async -> CommandResult

    public init(locate: @escaping @Sendable (_ candidates: [String]) -> String?,
                run: @escaping @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]?,
                                          _ timeout: TimeInterval) async -> CommandResult) {
        self.locate = locate
        self.run = run
    }

    public static let system = ToolRunner(
        locate: { candidates in candidates.first { FileManager.default.isExecutableFile(atPath: $0) } },
        run: { executable, arguments, environment, timeout in
            await Command.run(executable, arguments, timeout: timeout, environment: environment)
        }
    )

    /// Aucun outil : ce que voit un test qui ne s'intéresse pas aux outils.
    public static let none = ToolRunner(locate: { _ in nil }, run: { _, _, _, _ in .notRun })
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Le contenu d'un dossier, sans les fichiers cachés du Finder.
    func children(of url: URL) -> [URL] {
        ((try? contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                   options: [])) ?? [])
            .filter { $0.lastPathComponent != ".DS_Store" }
    }
}

extension URL {
    var isSymbolicLink: Bool {
        (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    var modificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Le chemin avec `~` à la place du dossier personnel, pour l'affichage.
    func abbreviated(home: URL) -> String {
        let base = home.path
        return path.hasPrefix(base) ? "~" + path.dropFirst(base.count) : path
    }
}
