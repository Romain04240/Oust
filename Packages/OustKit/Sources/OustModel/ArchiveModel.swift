import Foundation
import Observation
import OustArchive
import OustCore
import OustLocalization
import OustSafety

/// L'archivage des projets inactifs vers un disque externe.
@MainActor
@Observable
public final class ArchiveModel {
    weak var app: AppModel?

    public enum Running: Equatable, Sendable {
        case idle
        case running
        case finished
    }

    public private(set) var search: AppModel.Phase = .idle
    public private(set) var candidates: [ProjectCandidate] = []
    /// Les projets cochés. Jamais d'office : un projet n'est pas régénérable
    /// (RULES.md, règle 4).
    public var chosen: Set<String> = [] {
        didSet { schedulePlan() }
    }

    public private(set) var destination: ArchiveDestination?
    /// Ce qu'il faudra écrire pour les projets cochés, et le plus gros fichier.
    public private(set) var plannedBytes: Int64 = 0
    public private(set) var largestFile: (name: String, size: Int64)?
    public private(set) var planning = false
    private var planTask: Task<Void, Never>?

    public private(set) var running: Running = .idle
    public private(set) var progress = ArchiveProgress()
    public private(set) var currentID: String?
    public private(set) var currentStep: ArchiveStep?
    public private(set) var outcomes: [ArchiveOutcome] = []
    private var runTask: Task<Void, Never>?

    init() {}

    // MARK: Recherche

    public var inactiveMonths: Int {
        get { app?.preferences.archiveInactiveMonths ?? 6 }
        set { app?.preferences.archiveInactiveMonths = newValue }
    }

    public func find() async {
        guard !search.isRunning, let app else { return }
        search = .running
        let cutoff = Calendar.current.date(byAdding: .month, value: -inactiveMonths, to: Date()) ?? Date()
        let found = await ProjectCandidates.find(in: app.preferences.projectRoots, inactiveSince: cutoff, home: app.home)
        candidates = found
        chosen = chosen.filter { id in found.contains { $0.id == id && $0.isArchivable } }
        search = .done(Date())
    }

    public func toggle(_ candidate: ProjectCandidate) {
        guard candidate.isArchivable, running != .running else { return }
        if chosen.contains(candidate.id) { chosen.remove(candidate.id) } else { chosen.insert(candidate.id) }
    }

    public var chosenCandidates: [ProjectCandidate] { candidates.filter { chosen.contains($0.id) } }
    public var chosenBytes: Int64 { chosenCandidates.reduce(0) { $0 + $1.sizes.freeable } }

    // MARK: Destination

    /// Les volumes qui peuvent recevoir une archive : tout sauf le disque de démarrage.
    public var volumes: [VolumeDescriptor] {
        app?.volumes.filter { !$0.isBoot } ?? []
    }

    public func choose(volume url: URL) {
        destination = ArchiveDestination.inspect(url)
        schedulePlan()
    }

    /// Les raisons de refuser la destination pour les projets cochés.
    public var refusals: [DestinationRefusal] {
        guard let destination else { return [] }
        let devices = Set(chosenCandidates.compactMap { ArchivePlan.device(of: $0.url) })
        return destination.refusals(sourceDevices: devices, logicalBytes: plannedBytes, largestFile: largestFile)
    }

    public var canStart: Bool {
        destination != nil && !chosen.isEmpty && !planning && refusals.isEmpty && running != .running
    }

    private func schedulePlan() {
        planTask?.cancel()
        let projects = chosenCandidates.map(\.url)
        guard !projects.isEmpty else {
            plannedBytes = 0
            largestFile = nil
            planning = false
            return
        }
        planning = true
        planTask = Task {
            let plans = await Task.detached(priority: .userInitiated) { projects.compactMap(ArchivePlan.measure) }.value
            guard !Task.isCancelled else { return }
            plannedBytes = plans.reduce(0) { $0 + $1.logicalBytes }
            largestFile = plans.max { $0.largestFileSize < $1.largestFileSize }
                .flatMap { plan in plan.largestFile.map { ($0, plan.largestFileSize) } }
            planning = false
        }
    }

    // MARK: Archivage

    public func start() {
        guard canStart, let destination, let app else { return }
        let projects = chosenCandidates
        let progress = ArchiveProgress()
        self.progress = progress
        outcomes = []
        running = .running
        let archiver = ProjectArchiver(engine: app.engine, history: app.history, describe: Self.describe)
        let folderName = L10n.string("archive.folder_name")
        runTask = Task {
            for await event in archiver.run(projects, to: destination, folderName: folderName, progress: progress) {
                switch event {
                case .began:
                    break
                case .projectBegan(let id, let step):
                    currentID = id
                    currentStep = step
                case .projectFinished(let outcome):
                    outcomes.append(outcome)
                    if outcome.completed {
                        chosen.remove(outcome.id)
                        candidates.removeAll { $0.id == outcome.id }
                    }
                case .finished:
                    currentID = nil
                    currentStep = nil
                    running = .finished
                    await app.loadHistory()
                    app.refreshVolumes()
                    if let url = self.destination?.volumeURL { self.destination = ArchiveDestination.inspect(url) }
                }
            }
        }
    }

    public func cancel() {
        progress.cancel()
        runTask?.cancel()
    }

    public func dismissReport() {
        running = .idle
        outcomes = []
    }

    public var archivedBytes: Int64 { outcomes.filter(\.completed).reduce(0) { $0 + $1.bytes } }

    /// Le message d'un échec, tel qu'il entre au journal et s'affiche : la
    /// raison, puis le fichier en cause quand il y en a un.
    public nonisolated static func describe(_ error: ArchiveError) -> String {
        let reason = L10n.string(error.localizationKey)
        guard let path = error.path, !path.isEmpty else { return reason }
        return reason + " — " + path
    }
}
