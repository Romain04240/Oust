import Darwin
import Foundation
import OustClean
import OustCore
import OustSafety
import Testing

@testable import OustArchive

private func transferEngine(
  _ desk: Desk, copier: ArchiveCopier = ArchiveCopier(),
  external: Bool = true, sameVolume: Bool = false, readOnly: Bool = false
) -> VerifiedTransfer {
  let folder = desk.external
  let destination = ArchiveDestination(
    volumeURL: folder, name: "external-test", fileSystem: "apfs",
    available: 1 << 40, isReadOnly: readOnly, isLocal: true,
    device: sameVolume ? ArchivePlan.device(of: folder)! : -1)
  return VerifiedTransfer(
    engine: desk.engine(), copier: copier, pathGuard: PathGuard(home: desk.home),
    processes: { ProcessSnapshot(processes: []) }, inspect: { _ in (destination, external) })
}

private func transferOutcomes(
  _ transfer: VerifiedTransfer, _ plan: TransferPlan,
  progress: ArchiveProgress = ArchiveProgress()
) async -> [TransferOutcome] {
  for await event in transfer.run(plan, progress: progress, cancellation: CleanupCancellation()) {
    if case .finished(let outcomes) = event { return outcomes }
  }
  return []
}

@Suite("Déplacement vérifié de fichiers et dossiers choisis")
struct TransferTests {
  @Test("Un fichier et un dossier sont vérifiés puis mis à la corbeille par OustClean")
  func fileAndFolder() async throws {
    let desk = try Desk()
    let file = try desk.file("film.mov", bytes: 1_000_000)
    let folder = try desk.sampleProject("dossier")
    let transfer = transferEngine(desk)
    let plan = try await transfer.prepare(sources: [file, folder], folder: desk.external)
    #expect(plan.sources.count == 2)
    #expect(plan.logicalBytes == 3_531_200)
    let outcomes = await transferOutcomes(transfer, plan)
    #expect(outcomes.count == 2)
    #expect(outcomes.allSatisfy { $0.completed })
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(outcomes.allSatisfy { $0.copy != nil && $0.partial == nil })
    let history = await HistoryStore(directory: desk.historyFolder).load()
    #expect(history.count == 2)
    #expect(history.allSatisfy { $0.result == .trashed && $0.bytes == 0 })
  }

  @Test("Une corruption conserve tous les originaux, y compris après une première copie réussie")
  func corruptBatch() async throws {
    let desk = try Desk()
    let first = try desk.file("a.bin", bytes: 1000)
    let second = try desk.file("z.bin", bytes: 1000)
    let copier = ArchiveCopier(tamper: { destination in
      if destination.lastPathComponent == "z.bin" {
        try? Data(repeating: 19, count: 1000).write(to: destination)
      }
    })
    let transfer = transferEngine(desk, copier: copier)
    let plan = try await transfer.prepare(sources: [first, second], folder: desk.external)
    let outcomes = await transferOutcomes(transfer, plan)
    #expect(outcomes.allSatisfy { !$0.completed })
    #expect(outcomes.first?.copy != nil)
    #expect(outcomes.last?.partial != nil)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
    #expect(FileManager.default.fileExists(atPath: outcomes.last!.partial!.path))
  }

  @Test("La source modifiée depuis le plan n'est pas déplacée")
  func changedSincePlan() async throws {
    let desk = try Desk()
    let source = try desk.file("fichier", bytes: 100)
    let transfer = transferEngine(desk)
    let plan = try await transfer.prepare(sources: [source], folder: desk.external)
    try Data("modifié".utf8).write(to: source)
    let outcomes = await transferOutcomes(transfer, plan)
    #expect(outcomes.first?.error == .sourceChanged)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("Un original modifié pendant la copie reste sur place")
  func changedDuringCopy() async throws {
    let desk = try Desk()
    let source = try desk.file("fichier", bytes: 100)
    let copier = ArchiveCopier(tamper: { _ in try? Data("modifié".utf8).write(to: source) })
    let transfer = transferEngine(desk, copier: copier)
    let plan = try await transfer.prepare(sources: [source], folder: desk.external)
    let outcomes = await transferOutcomes(transfer, plan)
    #expect(outcomes.first?.completed == false)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("Le même volume, un volume interne et un volume en lecture seule sont refusés")
  func refusedDestinations() async throws {
    let desk = try Desk()
    let source = try desk.file("fichier", bytes: 100)
    await #expect(throws: TransferError.destinationRefused(.sameVolume)) {
      try await transferEngine(desk, sameVolume: true).prepare(
        sources: [source], folder: desk.external)
    }
    await #expect(throws: TransferError.externalRequired) {
      try await transferEngine(desk, external: false).prepare(
        sources: [source], folder: desk.external)
    }
    await #expect(throws: TransferError.destinationRefused(.readOnly)) {
      try await transferEngine(desk, readOnly: true).prepare(
        sources: [source], folder: desk.external)
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("La destination remplacée depuis la confirmation est refusée")
  func replacedDestination() async throws {
    let desk = try Desk()
    let source = try desk.file("fichier", bytes: 100)
    let transfer = transferEngine(desk)
    let plan = try await transfer.prepare(sources: [source], folder: desk.external)
    try FileManager.default.moveItem(
      at: desk.external, to: desk.root.appendingPathComponent("ancien"))
    try FileManager.default.createDirectory(at: desk.external, withIntermediateDirectories: true)
    let outcomes = await transferOutcomes(transfer, plan)
    #expect(outcomes.first?.error == .destinationChanged)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("Annuler avant et pendant la copie conserve l'original et rend un bilan")
  func cancelled() async throws {
    let desk = try Desk()
    let source = try desk.file("fichier", bytes: 100)
    let before = ArchiveProgress()
    before.cancel()
    let transfer = transferEngine(desk)
    let plan = try await transfer.prepare(sources: [source], folder: desk.external)
    #expect(await transferOutcomes(transfer, plan, progress: before).first?.error == .cancelled)
    let during = ArchiveProgress()
    let cancelCopier = ArchiveCopier(tamper: { _ in during.cancel() })
    let cancelTransfer = transferEngine(desk, copier: cancelCopier)
    let outcomes = await transferOutcomes(cancelTransfer, plan, progress: during)
    #expect(outcomes.first?.error == .copy(.cancelled))
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("Les sources imbriquées sont refusées et une destination existante n'est jamais écrasée")
  func overlapAndExisting() async throws {
    let desk = try Desk()
    let folder = try desk.sampleProject("dossier")
    let transfer = transferEngine(desk)
    await #expect(throws: TransferError.overlappingSources) {
      try await transfer.prepare(
        sources: [folder, folder.appendingPathComponent("README.md")], folder: desk.external)
    }
    let existing = desk.external.appendingPathComponent("dossier")
    try Data("à conserver".utf8).write(to: existing)
    let plan = try await transfer.prepare(sources: [folder], folder: desk.external)
    let outcomes = await transferOutcomes(transfer, plan)
    #expect(outcomes.first?.completed == true)
    #expect(outcomes.first?.copy?.lastPathComponent == "dossier 2")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "à conserver")
  }

  @Test("Le dernier contrôle détecte une corruption de même taille et même date")
  func finalSealHashesContent() throws {
    let desk = try Desk()
    let source = try desk.file("fichier", bytes: 100)
    let attempt = ArchiveCopier().copy(
      source, into: desk.external, appleDouble: false, progress: ArchiveProgress())
    let copy = try attempt.result.get()
    #expect(ArchiveSeal.originalMatchesCopy(original: source, copy: copy.destination))
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    try Data(repeating: 42, count: 100).write(to: source)
    try FileManager.default.setAttributes(
      [.modificationDate: attributes[.modificationDate]!], ofItemAtPath: source.path)
    #expect(!ArchiveSeal.originalMatchesCopy(original: source, copy: copy.destination))
    #expect(FileManager.default.fileExists(atPath: source.path))
  }
  @Test("La fourche de ressources est vérifiée avant la corbeille")
  func resourceForkVerified() throws {
    let desk = try Desk()
    let source = try desk.file("ressource", bytes: 100)
    let resource = Data("ressource personnelle".utf8)
    let written = resource.withUnsafeBytes { raw in
      setxattr(source.path, XATTR_RESOURCEFORK_NAME, raw.baseAddress, raw.count, 0, 0)
    }
    #expect(written == 0)
    let attempt = ArchiveCopier().copy(
      source, into: desk.external, appleDouble: false, progress: ArchiveProgress())
    let copy = try attempt.result.get()
    #expect(ArchiveSeal.originalMatchesCopy(original: source, copy: copy.destination))
    let changed = Data("ressource corrompue".utf8)
    let modified = changed.withUnsafeBytes { raw in
      setxattr(copy.destination.path, XATTR_RESOURCEFORK_NAME, raw.baseAddress, raw.count, 0, 0)
    }
    #expect(modified == 0)
    #expect(!ArchiveSeal.originalMatchesCopy(original: source, copy: copy.destination))
  }

  @Test("Sur un volume à compagnons AppleDouble, le fichier reste dans son enveloppe")
  func appleDoubleEnvelope() throws {
    let desk = try Desk()
    let source = try desk.file("fichier", bytes: 100)
    let attempt = ArchiveCopier().copy(
      source, into: desk.external, appleDouble: true, progress: ArchiveProgress())
    let copy = try attempt.result.get()
    #expect(copy.destination.deletingLastPathComponent().lastPathComponent == "fichier")
    #expect(copy.destination.lastPathComponent == "fichier")
    #expect(ArchiveSeal.originalMatchesCopy(original: source, copy: copy.destination))
  }

}

/// Aucune configuration Git personnelle ni transport réseau n'entre dans ces
/// fixtures : les dépôts et leurs worktrees restent sous le temporaire du test.
private func fixtureGit(in folder: URL, _ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.currentDirectoryURL = folder
  process.arguments =
    [
      "-c", "user.name=Oust fixture", "-c", "user.email=fixture@localhost",
      "-c", "init.templateDir=", "-c", "core.hooksPath=/dev/null",
    ] + arguments
  process.environment = [
    "PATH": "/usr/bin:/bin", "HOME": folder.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_ALLOW_PROTOCOL": "file", "LC_ALL": "C",
  ]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  try #require(process.terminationStatus == 0)
}

private func fixtureRepository(_ desk: Desk, name: String) throws -> URL {
  let repository = desk.projects.appendingPathComponent(name)
  try fixtureGit(in: desk.projects, ["init", "--initial-branch=main", repository.path])
  try Data("source initiale".utf8).write(to: repository.appendingPathComponent("README.md"))
  try fixtureGit(in: repository, ["add", "README.md"])
  try fixtureGit(in: repository, ["commit", "-m", "fixture"])
  return repository
}

@Suite("Le déplacement conserve les références entre dépôts Git")
struct TransferGitTests {
  @Test("Worktree, dépôt lié, métadonnées isolées et collection imbriquée sont protégés")
  func linkedRepositoriesAreProtected() async throws {
    let desk = try Desk()
    let repository = try fixtureRepository(desk, name: "principal")
    let worktree = desk.root.appendingPathComponent("worktree-externe")
    try fixtureGit(in: repository, ["worktree", "add", "-b", "fixture-worktree", worktree.path])
    let transfer = transferEngine(desk)
    await #expect(throws: TransferError.git(.isWorktree)) {
      try await transfer.prepare(sources: [worktree], folder: desk.external)
    }
    await #expect(throws: TransferError.git(.externalWorktrees(count: 1))) {
      try await transfer.prepare(sources: [repository], folder: desk.external)
    }
    await #expect(throws: TransferError.git(.systemPath)) {
      try await transfer.prepare(
        sources: [repository.appendingPathComponent(".git")], folder: desk.external)
    }
    await #expect(throws: TransferError.git(.externalWorktrees(count: 1))) {
      try await transfer.prepare(sources: [desk.projects], folder: desk.external)
    }
    #expect(FileManager.default.fileExists(atPath: repository.path))
    #expect(FileManager.default.fileExists(atPath: worktree.path))
  }

  @Test("Un sous-module isolé est protégé ; son dépôt parent complet reste copiable")
  func submoduleRequiresWholeParent() async throws {
    let desk = try Desk()
    let dependency = try fixtureRepository(desk, name: "dependance")
    let repository = try fixtureRepository(desk, name: "parent")
    try fixtureGit(
      in: repository,
      [
        "-c", "protocol.file.allow=always", "submodule", "add", dependency.path,
        "Modules/dependance",
      ])
    let submodule = repository.appendingPathComponent("Modules/dependance")
    let transfer = transferEngine(desk)
    await #expect(throws: TransferError.git(.isWorktree)) {
      try await transfer.prepare(sources: [submodule], folder: desk.external)
    }
    // Le sous-module et les ajouts non commités sont intégralement copiés.
    let plan = try await transfer.prepare(sources: [repository], folder: desk.external)
    let outcomes = await transferOutcomes(transfer, plan)
    #expect(outcomes.first?.completed == true)
    #expect(!FileManager.default.fileExists(atPath: repository.path))
    let copy = try #require(outcomes.first?.copy)
    try fixtureGit(
      in: copy.appendingPathComponent("Modules/dependance"), ["rev-parse", "--is-inside-work-tree"])
  }

  @Test("Un worktree apparu pendant la copie empêche la corbeille")
  func worktreeCreatedDuringCopy() async throws {
    let desk = try Desk()
    let repository = try fixtureRepository(desk, name: "parent")
    let worktree = desk.root.appendingPathComponent("worktree-tardif")
    let copier = ArchiveCopier(tamper: { file in
      if file.lastPathComponent == "README.md" {
        try? fixtureGit(
          in: repository, ["worktree", "add", "-b", "fixture-tardive", worktree.path])
      }
    })
    let transfer = transferEngine(desk, copier: copier)
    let plan = try await transfer.prepare(sources: [repository], folder: desk.external)
    let outcomes = await transferOutcomes(transfer, plan)
    #expect(outcomes.first?.completed == false)
    #expect(outcomes.first?.error != nil)
    #expect(FileManager.default.fileExists(atPath: repository.path))
    #expect(FileManager.default.fileExists(atPath: worktree.path))
    #expect(await VerifiedTransfer.gitBlocker(for: plan.sources[0]) == .externalWorktrees(count: 1))
  }

  @Test("Un dépôt Git illisible protège son original")
  func brokenRepositoryIsProtected() async throws {
    let desk = try Desk()
    let repository = desk.projects.appendingPathComponent("incomplet")
    try FileManager.default.createDirectory(
      at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
    await #expect(throws: TransferError.git(.unknownState)) {
      try await transferEngine(desk).prepare(sources: [repository], folder: desk.external)
    }
    #expect(FileManager.default.fileExists(atPath: repository.path))
  }

  @Test("Un dépôt nu avec worktree externe ne peut pas être déplacé seul")
  func bareRepositoryWithWorktreeIsProtected() async throws {
    let desk = try Desk()
    let original = try fixtureRepository(desk, name: "original")
    let bare = desk.projects.appendingPathComponent("depot-nu")
    try fixtureGit(in: desk.projects, ["clone", "--bare", original.path, bare.path])
    let worktree = desk.root.appendingPathComponent("worktree-du-nu")
    try fixtureGit(in: bare, ["worktree", "add", "-b", "fixture-bare", worktree.path])
    await #expect(throws: TransferError.git(.externalWorktrees(count: 1))) {
      try await transferEngine(desk).prepare(sources: [bare], folder: desk.external)
    }
    #expect(FileManager.default.fileExists(atPath: bare.path))
    #expect(FileManager.default.fileExists(atPath: worktree.path))
  }
  @Test("Un dépôt ordinaire dont core.worktree conserve l’adresse absolue reste protégé")
  func absoluteWorktreeInOrdinaryRepositoryIsProtected() async throws {
    let desk = try Desk()
    let repository = try fixtureRepository(desk, name: "configuration-absolue")
    try fixtureGit(in: repository, ["config", "core.worktree", repository.path])
    await #expect(throws: TransferError.git(.isWorktree)) {
      try await transferEngine(desk).prepare(sources: [repository], folder: desk.external)
    }
    #expect(FileManager.default.fileExists(atPath: repository.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: desk.external.path).isEmpty)

    let perWorktree = try fixtureRepository(desk, name: "configuration-par-worktree")
    try fixtureGit(in: perWorktree, ["config", "extensions.worktreeConfig", "true"])
    try fixtureGit(in: perWorktree, ["config", "--worktree", "core.worktree", perWorktree.path])
    await #expect(throws: TransferError.git(.isWorktree)) {
      try await transferEngine(desk).prepare(sources: [perWorktree], folder: desk.external)
    }
    #expect(FileManager.default.fileExists(atPath: perWorktree.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: desk.external.path).isEmpty)
  }

  @Test("Un sous-module à racine effective extérieure reste protégé malgré son gitdir interne")
  func submoduleWithExternalEffectiveRootIsProtected() async throws {
    let desk = try Desk()
    let dependency = try fixtureRepository(desk, name: "dependance")
    let repository = try fixtureRepository(desk, name: "parent")
    try fixtureGit(
      in: repository,
      [
        "-c", "protocol.file.allow=always", "submodule", "add", dependency.path,
        "Modules/dependance",
      ])
    let submodule = repository.appendingPathComponent("Modules/dependance")
    try fixtureGit(in: submodule, ["config", "core.worktree", "../../../../../dependance"])
    await #expect(throws: TransferError.git(.unknownState)) {
      try await transferEngine(desk).prepare(sources: [repository], folder: desk.external)
    }
    #expect(FileManager.default.fileExists(atPath: repository.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: desk.external.path).isEmpty)
  }

}
