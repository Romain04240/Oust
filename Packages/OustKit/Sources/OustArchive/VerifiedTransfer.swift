import Darwin
import Foundation
import OustClean
import OustCore
import OustSafety

public enum TransferError: Error, Sendable, Equatable {
  case noSources, invalidSource, overlappingSources, invalidDestination, externalRequired,
    destinationChanged
  case sourceChanged, protectedSource, trashUnavailable
  case git(ArchiveBlocker)
  case destinationRefused(DestinationRefusal)
  case copy(ArchiveError)
  case cancelled

  public var localizationKey: String {
    switch self {
    case .noSources: "transfer.error.noSources"
    case .invalidSource: "transfer.error.invalidSource"
    case .overlappingSources: "transfer.error.overlappingSources"
    case .invalidDestination: "transfer.error.invalidDestination"
    case .externalRequired: "transfer.error.externalRequired"
    case .destinationChanged: "transfer.error.destinationChanged"
    case .sourceChanged: "archive.error.sourceChanged"
    case .protectedSource: "transfer.error.protectedSource"
    case .trashUnavailable: "archive.error.trashUnavailable"
    case .git(let blocker): blocker.localizationKey
    case .destinationRefused(let error): error.localizationKey
    case .copy(let error): error.localizationKey
    case .cancelled: "archive.error.cancelled"
    }
  }
}

struct TransferStamp: Sendable, Equatable {
  let device: Int32
  let inode: UInt64
  let mode: mode_t
  let size: Int64
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
  let changedSeconds: Int
  let changedNanoseconds: Int
  let flags: UInt32

  init(_ info: stat) {
    device = info.st_dev
    inode = UInt64(info.st_ino)
    mode = info.st_mode
    size = Int64(info.st_size)
    modifiedSeconds = info.st_mtimespec.tv_sec
    modifiedNanoseconds = info.st_mtimespec.tv_nsec
    changedSeconds = info.st_ctimespec.tv_sec
    changedNanoseconds = info.st_ctimespec.tv_nsec
    flags = info.st_flags
  }
}

public struct TransferSource: Sendable, Identifiable {
  public var id: String { url.path }
  public let url: URL
  public let logicalBytes: Int64
  public let fileCount: Int
  let stamps: [String: TransferStamp]
}

/// Plan immuable : l'interface confirme exactement ces sources et ce dossier.
public struct TransferPlan: Sendable {
  public let sources: [TransferSource]
  public let folder: URL
  public let destination: ArchiveDestination
  public var logicalBytes: Int64 { sources.reduce(0) { $0 + $1.logicalBytes } }
  let folderStamp: TransferStamp
  let largest: (name: String, size: Int64)?
}

public struct TransferOutcome: Sendable, Identifiable {
  public var id: String { source.path }
  public let source: URL
  public let copy: URL?
  /// Gardé pour inspection ; jamais effacé automatiquement après un échec.
  public let partial: URL?
  public let result: OutcomeResult?
  public let error: TransferError?
  public var completed: Bool { result == .trashed }
}

public enum TransferEvent: Sendable {
  case copying(URL)
  case revalidating
  case trashing(URL)
  case finished([TransferOutcome])
}

/// Extension de l'archivage aux fichiers et dossiers choisis explicitement.
/// Toutes les copies doivent réussir avant de demander à OustClean de jeter
/// un original. Les tailles du plan désignent les octets à copier : elles ne
/// promettent aucun espace libéré avant vidage de la corbeille du Mac.
public struct VerifiedTransfer: Sendable {
  let engine: CleanupEngine
  let copier: ArchiveCopier
  let pathGuard: PathGuard
  let processes: @Sendable () -> ProcessSnapshot
  let inspect: @Sendable (URL) -> (ArchiveDestination, Bool)?

  public init(
    engine: CleanupEngine = CleanupEngine(), pathGuard: PathGuard = PathGuard(),
    processes: @escaping @Sendable () -> ProcessSnapshot = { .current() }
  ) {
    self.init(
      engine: engine, copier: ArchiveCopier(), pathGuard: pathGuard, processes: processes,
      inspect: Self.inspectDestination)
  }

  init(
    engine: CleanupEngine, copier: ArchiveCopier, pathGuard: PathGuard,
    processes: @escaping @Sendable () -> ProcessSnapshot,
    inspect: @escaping @Sendable (URL) -> (ArchiveDestination, Bool)?
  ) {
    self.engine = engine
    self.copier = copier
    self.pathGuard = pathGuard
    self.processes = processes
    self.inspect = inspect
  }

  static func inspectDestination(_ url: URL) -> (ArchiveDestination, Bool)? {
    guard let destination = ArchiveDestination.inspect(url),
      let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey])
    else { return nil }
    return (destination, values.volumeIsInternal == false && destination.isLocal)
  }

  /// Bloquant, sur le thread dédié de l'archivage ; aucune erreur de parcours
  /// n'est transformée en taille zéro ni en autorisation implicite.
  public func prepare(sources urls: [URL], folder: URL) async throws -> TransferPlan {
    guard engine.supports(.trash) else { throw TransferError.trashUnavailable }
    let result = await ProjectArchiver.onDedicatedThread {
      () -> Result<TransferPlan, TransferError> in
      do { return .success(try prepareNow(sources: urls, folder: folder)) } catch let error
        as TransferError
      { return .failure(error) } catch { return .failure(.invalidSource) }
    }
    let plan = try result.get()
    for source in plan.sources {
      if let blocker = await Self.gitBlocker(for: source) { throw TransferError.git(blocker) }
    }
    return plan
  }

  /// Les pointeurs Git ne se déplacent pas comme des données ordinaires : un
  /// worktree ou un sous-module isolé peut perdre son dépôt d'administration.
  /// On inspecte aussi les dépôts imbriqués d'une collection choisie entière.
  static func gitBlocker(for source: TransferSource) async -> ArchiveBlocker? {
    if source.url.resolvingSymlinksInPath().pathComponents.contains(".git") { return .systemPath }
    let markers = source.stamps.keys.filter { ($0 as NSString).lastPathComponent == ".git" }
      .sorted()
    for relative in markers {
      guard let marker = source.stamps[relative] else { return .unknownState }
      let dotGit = source.url.appendingPathComponent(relative)
      let repository = dotGit.deletingLastPathComponent()
      switch marker.mode & S_IFMT {
      case S_IFDIR:
        if let blocker = await gitRepositoryBlocker(repository) { return blocker }
      case S_IFREG:
        // Un sous-module peut accompagner son dépôt complet si son pointeur
        // relatif et sa destination restent ensemble dans la même copie.
        guard repository.path != source.url.path,
          let text = try? String(contentsOf: dotGit, encoding: .utf8),
          let first = text.split(whereSeparator: \.isNewline).first,
          first.hasPrefix("gitdir:")
        else { return .isWorktree }
        let path = first.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !(path as NSString).isAbsolutePath else { return .isWorktree }
        let root = source.url.resolvingSymlinksInPath().path
        let target = repository.appendingPathComponent(path).standardizedFileURL
          .resolvingSymlinksInPath()
        guard target.path != root, PathNormalizer.isWithin(target.path, root) else {
          return .isWorktree
        }
        let targetRelative = String(target.path.dropFirst(root.count + 1))
        guard let entry = source.stamps[targetRelative], entry.mode & S_IFMT == S_IFDIR,
          source.stamps[targetRelative + "/commondir"] == nil
        else { return .isWorktree }
        if let blocker = await gitRepositoryBlocker(repository, administration: target) {
          return blocker
        }
      default: return .isWorktree
      }
    }
    // Un dépôt nu n'a pas de marqueur .git ; ses worktrees externes dépendent
    // néanmoins de ses objets et références, qu'on ne doit pas déplacer seuls.
    for (relative, entry) in source.stamps where entry.mode & S_IFMT == S_IFDIR {
      guard !relative.split(separator: "/").contains(".git") else { continue }
      let prefix = relative.isEmpty ? "" : relative + "/"
      if (source.stamps[prefix + "HEAD"]?.mode ?? 0) & S_IFMT == S_IFREG,
        (source.stamps[prefix + "objects"]?.mode ?? 0) & S_IFMT == S_IFDIR,
        (source.stamps[prefix + "refs"]?.mode ?? 0) & S_IFMT == S_IFDIR
      {
        let repository = relative.isEmpty ? source.url : source.url.appendingPathComponent(relative)
        if let blocker = await gitRepositoryBlocker(repository) { return blocker }
      }
    }
    return nil
  }

  private static func gitRepositoryBlocker(_ repository: URL, administration: URL? = nil) async
    -> ArchiveBlocker?
  {
    // Un chemin absolu resterait lié à l’ancien emplacement même si la
    // copie et les références d’objets sont entièrement vérifiées.
    let configuration = await Command.run(
      "/usr/bin/git", ["-C", repository.path, "config", "--get", "core.worktree"],
      timeout: 20)
    guard configuration.succeeded || (configuration.status == 1 && !configuration.timedOut)
    else { return .unknownState }
    if configuration.succeeded,
      (configuration.output.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
        .isAbsolutePath
    {
      return .isWorktree
    }

    let worktrees = await GitInspector.worktrees(of: repository)
    guard let main = worktrees.first else { return .unknownState }
    let reportedMain = URL(fileURLWithPath: main.path).resolvingSymlinksInPath().path
    if reportedMain != repository.resolvingSymlinksInPath().path {
      // Git nomme le dossier d'administration pour le worktree principal d'un
      // sous-module. On l'accepte seulement après vérification du gitdir déjà
      // inclus dans la copie, et de la vraie racine de travail effective.
      guard let administration, reportedMain == administration.resolvingSymlinksInPath().path else {
        return .unknownState
      }
      let topLevel = await Command.run(
        "/usr/bin/git", ["-C", repository.path, "rev-parse", "--show-toplevel"], timeout: 20)
      guard topLevel.succeeded,
        URL(fileURLWithPath: topLevel.output.trimmingCharacters(in: .whitespacesAndNewlines))
          .resolvingSymlinksInPath().path == repository.resolvingSymlinksInPath().path
      else { return .unknownState }
    }
    let outside = worktrees.filter {
      !$0.isMain && !PathNormalizer.isWithin($0.path, repository.path)
    }
    return outside.isEmpty ? nil : .externalWorktrees(count: outside.count)
  }

  private func prepareNow(sources urls: [URL], folder: URL) throws -> TransferPlan {
    guard !urls.isEmpty else { throw TransferError.noSources }
    let urls = Array(Set(urls.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
    let resolved = urls.map { $0.resolvingSymlinksInPath().path }
    for (index, path) in resolved.enumerated() {
      guard
        !resolved.enumerated().contains(where: {
          $0.offset != index && (path == $0.element || path.hasPrefix($0.element + "/"))
        })
      else {
        throw TransferError.overlappingSources
      }
    }
    let folder = folder.resolvingSymlinksInPath().standardizedFileURL
    var folderInfo = stat()
    guard lstat(folder.path, &folderInfo) == 0, folderInfo.st_mode & S_IFMT == S_IFDIR,
      access(folder.path, W_OK | X_OK) == 0, let (destination, external) = inspect(folder)
    else {
      throw TransferError.invalidDestination
    }
    guard external else { throw TransferError.externalRequired }
    var sources: [TransferSource] = []
    var largest: (name: String, size: Int64)?
    let snapshot = processes()
    for url in urls {
      guard pathGuard.allows(url) else { throw TransferError.protectedSource }
      if snapshot.busy(under: url.path) != nil || snapshot.running(inside: url.path) != nil {
        throw TransferError.protectedSource
      }
      let stamps = try Self.snapshot(url)
      guard let root = stamps[""], [S_IFDIR, S_IFREG].contains(root.mode & S_IFMT) else {
        throw TransferError.invalidSource
      }
      let files = stamps.filter { $0.value.mode & S_IFMT == S_IFREG }
      for (path, file) in files where file.size > (largest?.size ?? -1) {
        largest = (path.isEmpty ? url.lastPathComponent : path, file.size)
      }
      sources.append(
        TransferSource(
          url: url, logicalBytes: files.values.reduce(0) { $0 + $1.size },
          fileCount: files.count, stamps: stamps))
    }
    let plan = TransferPlan(
      sources: sources, folder: folder, destination: destination,
      folderStamp: TransferStamp(folderInfo), largest: largest)
    try validateDestination(plan)
    return plan
  }

  private func validateDestination(_ plan: TransferPlan, requiredBytes: Int64? = nil) throws {
    var folder = stat()
    guard lstat(plan.folder.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR,
      folder.st_dev == plan.folderStamp.device, UInt64(folder.st_ino) == plan.folderStamp.inode,
      access(plan.folder.path, W_OK | X_OK) == 0,
      let (current, external) = inspect(plan.folder), external,
      current.device == plan.destination.device,
      current.volumeURL == plan.destination.volumeURL
    else { throw TransferError.destinationChanged }
    if let refusal = current.refusals(
      sourceDevices: Set(plan.sources.compactMap { $0.stamps[""]?.device }),
      logicalBytes: requiredBytes ?? plan.logicalBytes, largestFile: plan.largest
    ).first {
      throw TransferError.destinationRefused(refusal)
    }
  }

  static func snapshot(_ source: URL) throws -> [String: TransferStamp] {
    var root = stat()
    guard lstat(source.path, &root) == 0 else { throw TransferError.invalidSource }
    var stamps: [String: TransferStamp] = [:]
    var pending = [""]
    while let relative = pending.popLast() {
      let path = relative.isEmpty ? source.path : source.path + "/" + relative
      var info = stat()
      guard lstat(path, &info) == 0, info.st_dev == root.st_dev,
        info.st_flags & (UInt32(SF_DATALESS) | 0x0080_0000) == 0
      else { throw TransferError.invalidSource }
      let stamp = TransferStamp(info)
      switch info.st_mode & S_IFMT {
      case S_IFDIR:
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
          throw TransferError.invalidSource
        }
        pending += names.map { relative.isEmpty ? $0 : relative + "/" + $0 }
      case S_IFREG, S_IFLNK: break
      default: throw TransferError.invalidSource
      }
      stamps[relative] = stamp
    }
    for (relative, stamp) in stamps {
      var info = stat()
      let path = relative.isEmpty ? source.path : source.path + "/" + relative
      guard lstat(path, &info) == 0, TransferStamp(info) == stamp else {
        throw TransferError.sourceChanged
      }
    }
    return stamps
  }

  public func run(
    _ plan: TransferPlan, progress: ArchiveProgress,
    cancellation: CleanupCancellation
  ) -> AsyncStream<TransferEvent> {
    AsyncStream { continuation in
      let task = Task {
        let outcomes = await execute(plan, progress: progress, cancellation: cancellation) {
          continuation.yield($0)
        }
        continuation.yield(.finished(outcomes))
        continuation.finish()
      }
      continuation.onTermination = { _ in
        progress.cancel()
        cancellation.cancel()
        task.cancel()
      }
    }
  }

  private func execute(
    _ plan: TransferPlan, progress: ArchiveProgress, cancellation: CleanupCancellation,
    emit: @Sendable (TransferEvent) -> Void
  ) async -> [TransferOutcome] {
    var copies: [ArchiveCopy] = []
    let cancelled = { progress.isCancelled || cancellation.isCancelled || Task.isCancelled }
    do {
      guard engine.supports(.trash) else { throw TransferError.trashUnavailable }
      try validateDestination(plan)
      for source in plan.sources {
        if cancelled() { throw TransferError.cancelled }
        let snapshot = processes()
        guard snapshot.busy(under: source.url.path) == nil,
          snapshot.running(inside: source.url.path) == nil,
          pathGuard.allows(source.url)
        else { throw TransferError.protectedSource }
        if let blocker = await Self.gitBlocker(for: source) { throw TransferError.git(blocker) }
        emit(.copying(source.url))
        let remainingBytes = plan.logicalBytes - copies.reduce(0) { $0 + $1.bytes }
        let attempt = await ProjectArchiver.onDedicatedThread { [self] in
          do {
            guard try Self.snapshot(source.url) == source.stamps else {
              throw TransferError.sourceChanged
            }
            try validateDestination(plan, requiredBytes: remainingBytes)
            return Result<ArchiveCopier.Attempt, TransferError>.success(
              copier.copy(
                source.url, into: plan.folder,
                appleDouble: plan.destination.storesAppleDouble, progress: progress))
          } catch let error as TransferError { return .failure(error) } catch {
            return .failure(.sourceChanged)
          }
        }
        let tried = try attempt.get()
        switch tried.result {
        case .success(let copy): copies.append(copy)
        case .failure(let error):
          return plan.sources.map { item in
            TransferOutcome(
              source: item.url, copy: copies.first { $0.source == item.url }?.destination,
              partial: item.url == source.url ? tried.staging : nil, result: nil,
              error: .copy(error))
          }
        }
      }
      emit(.revalidating)
      for (source, copy) in zip(plan.sources, copies) {
        if cancelled() { throw TransferError.cancelled }
        if let blocker = await Self.gitBlocker(for: source) { throw TransferError.git(blocker) }
        let valid = await ProjectArchiver.onDedicatedThread {
          (try? Self.snapshot(source.url)) == source.stamps
            && ArchiveSeal.originalMatchesCopy(original: source.url, copy: copy.destination)
        }
        guard valid else { throw TransferError.sourceChanged }
      }
      try validateDestination(plan, requiredBytes: 0)
      if cancelled() { throw TransferError.cancelled }
    } catch {
      let reason = error as? TransferError ?? .sourceChanged
      return plan.sources.map { source in
        TransferOutcome(
          source: source.url, copy: copies.first { $0.source == source.url }?.destination,
          partial: nil, result: nil, error: reason)
      }
    }
    var outcomes: [TransferOutcome] = []
    let session = UUID()
    for (source, copy) in zip(plan.sources, copies) {
      if cancelled() {
        outcomes.append(
          TransferOutcome(
            source: source.url, copy: copy.destination, partial: nil, result: nil, error: .cancelled
          ))
        continue
      }
      if let blocker = await Self.gitBlocker(for: source) {
        outcomes.append(
          TransferOutcome(
            source: source.url, copy: copy.destination, partial: nil,
            result: nil, error: .git(blocker)))
        continue
      }
      emit(.trashing(source.url))
      let root = source.stamps[""]!
      let item = CleanupItem(
        id: "transfer|" + source.id, title: source.url.lastPathComponent,
        detail: source.url.path, paths: [source.url], category: .archives,
        owner: plan.destination.name, ruleID: "archive.transfer", safety: .review,
        method: .archive(copy: copy.destination.path), sizes: .zero, rebuild: .irreversible,
        fingerprint: Fingerprint(
          modificationDate: Date(timeIntervalSince1970: TimeInterval(root.modifiedSeconds)),
          fileID: root.inode), activityScope: source.url)
      var result: OutcomeResult?
      for await event in engine.run([item], session: session, cancellation: cancellation) {
        if case .itemFinished(let outcome) = event { result = outcome.result }
      }
      outcomes.append(
        TransferOutcome(
          source: source.url, copy: copy.destination, partial: nil, result: result, error: nil))
    }
    return outcomes
  }
}
