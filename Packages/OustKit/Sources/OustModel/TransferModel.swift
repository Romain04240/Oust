import Foundation
import Observation
import OustArchive
import OustClean
import OustLocalization

/// L'état d'un déplacement explicitement préparé et confirmé dans l'interface.
@MainActor
@Observable
public final class TransferModel {
  weak var app: AppModel?
  public enum Phase: Sendable, Equatable {
    case choosing, planning, ready, copying, revalidating, trashing, finished
  }
  public private(set) var phase: Phase = .choosing {
    didSet { if oldValue != phase { phaseStartedAt = .now } }
  }
  private var startedAt: ContinuousClock.Instant?
  private var phaseStartedAt: ContinuousClock.Instant = .now
  private var finishedDuration: Duration?
  public func elapsed() -> Duration { finishedDuration ?? startedAt?.duration(to: .now) ?? .zero }
  public func phaseElapsed() -> Duration { max(.zero, phaseStartedAt.duration(to: .now)) }
  public private(set) var sources: [URL] = []
  public private(set) var folder: URL?
  public private(set) var plan: TransferPlan?
  public private(set) var error: String?
  public private(set) var outcomes: [TransferOutcome] = []
  public private(set) var current: URL?
  public private(set) var progress = ArchiveProgress()
  private var cancellation = CleanupCancellation()
  private var task: Task<Void, Never>?
  private var revision = UUID()

  public init() {}
  public var isRunning: Bool { [.copying, .revalidating, .trashing].contains(phase) }
  public var canPrepare: Bool {
    app?.canMoveFiles == true && !sources.isEmpty && folder != nil && !isRunning && phase != .planning
  }

  /// Préremplit le parcours depuis un conseil ou l'Explorateur, sans préparer
  /// le plan ni autoriser la copie.
  public func present(sources urls: [URL]) {
    guard !isRunning else { return }
    sources = urls
    invalidate()
  }

  public func chooseSources(_ urls: [URL]) {
    guard !isRunning else { return }
    sources = urls
    invalidate()
  }

  public func chooseFolder(_ url: URL) {
    guard !isRunning else { return }
    folder = url
    invalidate()
  }

  private func invalidate() {
    task?.cancel()
    revision = UUID()
    plan = nil
    error = nil
    outcomes = []
    startedAt = nil
    finishedDuration = nil
    phase = .choosing
  }

  public func prepare() {
    guard canPrepare, let folder, let app else { return }
    let revision = UUID()
    self.revision = revision
    phase = .planning
    error = nil
    let transfer = VerifiedTransfer(engine: app.engine)
    let urls = sources
    task = Task {
      do {
        let plan = try await transfer.prepare(sources: urls, folder: folder)
        guard !Task.isCancelled, self.revision == revision else { return }
        self.plan = plan
        phase = .ready
      } catch {
        guard !Task.isCancelled, self.revision == revision else { return }
        self.error = Self.describe(error as? TransferError ?? .invalidSource)
        phase = .choosing
      }
    }
  }

  /// Appelé uniquement par le bouton de confirmation du plan affiché.
  public func startConfirmedPlan() {
    guard phase == .ready, let plan, let app, app.canMoveFiles else { return }
    progress = ArchiveProgress()
    cancellation = CleanupCancellation()
    startedAt = .now
    finishedDuration = nil
    phase = .copying
    outcomes = []
    current = nil
    let transfer = VerifiedTransfer(engine: app.engine)
    let progress = progress
    let cancellation = cancellation
    task = Task {
      for await event in transfer.run(plan, progress: progress, cancellation: cancellation) {
        switch event {
        case .copying(let url):
          phase = .copying
          current = url
        case .revalidating:
          phase = .revalidating
          current = nil
        case .trashing(let url):
          phase = .trashing
          current = url
        case .finished(let outcomes):
          finishedDuration = startedAt?.duration(to: .now)
          self.outcomes = outcomes
          phase = .finished
          current = nil
          await app.loadHistory()
          app.refreshVolumes()
        }
      }
    }
  }

  public func cancel() {
    progress.cancel()
    cancellation.cancel()
    // Le flux reste lu jusqu'au bilan : les copies conservées restent visibles.
  }

  public nonisolated static func describe(_ error: TransferError) -> String {
    switch error {
    case .destinationRefused(.notEnoughSpace(let needed, let available)):
      return L10n.string(
        error.localizationKey,
        ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
        ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
    case .destinationRefused(.fileTooLarge(let name)):
      return L10n.string(error.localizationKey, name)
    case .git(let blocker):
      if let argument = blocker.argument { return L10n.string(blocker.localizationKey, argument) }
      return L10n.string(blocker.localizationKey)
    case .copy(let failure):
      return ArchiveModel.describe(failure)
    default:
      return L10n.string(error.localizationKey)
    }
  }
}
