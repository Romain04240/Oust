import AppKit
import Foundation
import OustClean
import OustCore
import OustModel
import OustRules
import OustSafety
import OustVolume

/// Ce que l'interface des agents connaît du monde.
///
/// Tout passe par ici, comme pour `RuleContext` : les tests fabriquent un faux
/// dossier personnel, une fausse corbeille et un faux journal dans un dossier
/// temporaire (RULES.md, règle 8), et la CLI n'y voit que du feu.
public struct AgentEnvironment: Sendable {
    public var home: URL
    /// Les dossiers de projets réglés dans Oust!.
    public var projectRoots: [URL]
    public var historyRetentionDays: Int
    public var compressionAgeDays: Int
    /// La garde de récence de l'app, pour dire ce qu'elle cocherait d'office.
    public var recencyDays: Int
    /// `nil` : la valeur de `RuleContext`, qu'on ne recopie pas ici.
    public var largeDownloadBytes: Int64?
    public var applications: URL?
    public var systemLibrary: URL?
    public var applicationName: (@Sendable (String) -> String?)?
    public var tools: ToolRunner
    public var runningApps: @Sendable () -> Set<String>
    /// La table des processus, telle quelle.
    public var processes: @Sendable () -> ProcessSnapshot
    /// Le processus qui appelle `oust` et ceux qui l'ont lancé (voir `Requester`).
    public var requester: @Sendable () -> Set<Int32>
    /// Le nom de l'agent qui a lancé `oust`, inscrit au journal (voir `Requester`).
    public var agentName: @Sendable () -> String?
    /// Le journal d'Oust!, le même que celui de l'app.
    public var history: HistoryStore
    /// Où vivent les aperçus ; `nil` : à côté du journal.
    public var stateDirectory: URL?
    public var trasher: any Trasher
    public var capacity: @Sendable (URL) -> Capacity?
    public var now: @Sendable () -> Date
    /// Ce contre quoi un `--path` relatif se résout.
    public var workingDirectory: URL
    /// Combien de temps un aperçu permet de nettoyer.
    public var previewLifetime: TimeInterval

    public init(
        home: URL,
        projectRoots: [URL],
        historyRetentionDays: Int = 30,
        compressionAgeDays: Int = 180,
        recencyDays: Int = 7,
        largeDownloadBytes: Int64? = nil,
        applications: URL? = nil,
        systemLibrary: URL? = nil,
        applicationName: (@Sendable (String) -> String?)? = nil,
        tools: ToolRunner = .system,
        runningApps: @escaping @Sendable () -> Set<String> = AgentEnvironment.openApplications,
        processes: @escaping @Sendable () -> ProcessSnapshot = { .current() },
        requester: @escaping @Sendable () -> Set<Int32> = { Requester.lineage() },
        agentName: @escaping @Sendable () -> String? = { Requester.agentName() },
        history: HistoryStore,
        stateDirectory: URL? = nil,
        trasher: any Trasher = FinderTrasher(),
        capacity: @escaping @Sendable (URL) -> Capacity? = { VolumeService.capacity(of: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        previewLifetime: TimeInterval = 30 * 60
    ) {
        self.home = home
        self.projectRoots = projectRoots
        self.historyRetentionDays = historyRetentionDays
        self.compressionAgeDays = compressionAgeDays
        self.recencyDays = recencyDays
        self.largeDownloadBytes = largeDownloadBytes
        self.applications = applications
        self.systemLibrary = systemLibrary
        self.applicationName = applicationName
        self.tools = tools
        self.runningApps = runningApps
        self.processes = processes
        self.requester = requester
        self.agentName = agentName
        self.history = history
        self.stateDirectory = stateDirectory
        self.trasher = trasher
        self.capacity = capacity
        self.now = now
        self.workingDirectory = workingDirectory
        self.previewLifetime = previewLifetime
    }

    /// Le Mac tel qu'il est, avec les réglages d'Oust! : les mêmes dossiers de
    /// projets, la même rétention, le même journal que l'app.
    public static func standard() -> AgentEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let preferences = Preferences.load(home: home, defaults: appDefaults())
        return AgentEnvironment(
            home: home,
            projectRoots: preferences.projectRoots,
            historyRetentionDays: preferences.historyRetentionDays,
            // Comme l'app (`AppModel.analyze`) : le réglage est en mois.
            compressionAgeDays: preferences.compressionAgeMonths * 30,
            recencyDays: preferences.recencyDays,
            history: .standard()
        )
    }

    public static let openApplications: @Sendable () -> Set<String> = {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Les préférences de l'app, et non celles d'un domaine « oust » à part.
    ///
    /// Embarquée dans Oust.app (`Contents/MacOS`), la CLI *est* `fr.meaillais.oust`
    /// aux yeux de Foundation, qui refuse alors une suite de ce nom.
    static func appDefaults() -> UserDefaults {
        let identifier = "fr.meaillais.oust"
        if Bundle.main.bundleIdentifier == identifier { return .standard }
        return UserDefaults(suiteName: identifier) ?? .standard
    }

    /// Le contexte des chercheurs, avec la table des processus vue par l'agent.
    func ruleContext(roots: [URL], processes snapshot: ProcessSnapshot) -> RuleContext {
        var context = RuleContext(
            home: home,
            projectRoots: roots,
            processes: snapshot,
            now: now(),
            historyRetentionDays: historyRetentionDays,
            compressionAgeDays: compressionAgeDays,
            tools: tools,
            runningApps: runningApps(),
            applicationName: applicationName
        )
        if let largeDownloadBytes { context.largeDownloadBytes = largeDownloadBytes }
        if let applications { context.applications = applications }
        if let systemLibrary { context.systemLibrary = systemLibrary }
        return context
    }

    /// La table des processus, sans le dossier courant de celui qui demande.
    func agentProcesses() -> ProcessSnapshot {
        Requester.snapshot(processes(), excluding: requester())
    }
}
