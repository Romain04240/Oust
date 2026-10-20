import Darwin
import Foundation
import Testing
@testable import OustArchive
import OustClean
import OustCore
import OustSafety

/// Des projets, un « disque externe », une corbeille et un journal, tous dans
/// un dossier temporaire à soi (RULES.md, règle 8).
///
/// Le disque externe est un simple dossier du même volume : les tests n'en ont
/// qu'un. Le refus du même volume se teste à part, sur `refusals`.
final class Desk {
    let root: URL
    var projects: URL { root.appendingPathComponent("Developpement") }
    var external: URL { root.appendingPathComponent("Disque externe") }
    var trash: URL { root.appendingPathComponent("_corbeille") }
    var historyFolder: URL { root.appendingPathComponent("_historique") }
    var home: URL { root.appendingPathComponent("maison") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-archive-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    }

    deinit {
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator { chmod(url.path, 0o755) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 8_192, byte: UInt8 = 7) throws -> URL {
        let url = projects.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(byte)) }).write(to: url)
        return url
    }

    /// Un projet ordinaire : sources, un binaire, un lien, un attribut étendu,
    /// un fichier en lecture seule.
    func sampleProject(_ name: String) throws -> URL {
        try file("\(name)/README.md", bytes: 1_200)
        try file("\(name)/Sources/App/main.swift", bytes: 30_000, byte: 3)
        try file("\(name)/Ressources/donnees.bin", bytes: 2_500_000, byte: 9)
        let project = projects.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("lien").path,
                                                   withDestinationPath: "README.md")
        let readme = project.appendingPathComponent("README.md").path
        _ = setxattr(readme, "fr.meaillais.oust.test", "étiquette", "étiquette".utf8.count, 0, XATTR_NOFOLLOW)
        chmod(project.appendingPathComponent("Sources/App/main.swift").path, 0o444)
        return project
    }

    /// Recule toutes les dates d'un dossier, du plus profond au plus haut.
    func age(_ url: URL, days: Double) {
        let date = Date().addingTimeInterval(-days * 86_400)
        var times = [timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0),
                     timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]
        var paths: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator { paths.append(url.path + "/" + relative) }
        }
        for path in paths.reversed() + [url.path] { lutimes(path, &times) }
    }

    func destination(fileSystem: String = "apfs") -> ArchiveDestination {
        ArchiveDestination(volumeURL: external, name: "Disque externe", fileSystem: fileSystem, available: 1 << 40,
                           isReadOnly: false, isLocal: true, device: -1)
    }

    func candidate(_ project: URL) -> ProjectCandidate {
        var info = stat()
        lstat(project.path, &info)
        return ProjectCandidate(url: project, lastModified: nil, sizes: Sizes(private: 2_600_000), fileCount: 4,
                                fileID: UInt64(info.st_ino))
    }

    func engine(processes: [ActiveProcess] = []) -> CleanupEngine {
        let snapshot = ProcessSnapshot(processes: processes)
        return CleanupEngine(trasher: FolderTrasher(folder: trash), history: HistoryStore(directory: historyFolder),
                             pathGuard: PathGuard(home: home), processes: { snapshot }, capacity: { _ in nil },
                             deleteSnapshots: { _ in false })
    }

    func archiver(copier: ArchiveCopier = ArchiveCopier(), processes: [ActiveProcess] = []) -> ProjectArchiver {
        let snapshot = ProcessSnapshot(processes: processes)
        return ProjectArchiver(engine: engine(processes: processes), history: HistoryStore(directory: historyFolder),
                               copier: copier, processes: { snapshot }, describe: { $0.localizationKey })
    }

    func run(_ archiver: ProjectArchiver, _ projects: [ProjectCandidate],
             fileSystem: String = "apfs", progress: ArchiveProgress = ArchiveProgress()) async -> [ArchiveOutcome] {
        var outcomes: [ArchiveOutcome] = []
        for await event in archiver.run(projects, to: destination(fileSystem: fileSystem), folderName: "Archives Oust",
                                        progress: progress) {
            if case .finished(let all) = event { outcomes = all }
        }
        return outcomes
    }

    /// Ce qui reste dans le dossier d'archives, dossiers de préparation compris.
    func archiveFolderContents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: external.appendingPathComponent("Archives Oust").path)) ?? [])
            .sorted()
    }
}

@Suite("L'archivage copie, vérifie, et seulement ensuite jette l'original")
struct ArchiveTests {

    @Test("Copié à l'identique, vérifié, puis l'original à la corbeille du Mac et au journal")
    func archiveEndToEnd() async throws {
        let desk = try Desk()
        let project = try desk.sampleProject("vieux-projet")

        let outcomes = await desk.run(desk.archiver(), [desk.candidate(project)])
        let outcome = try #require(outcomes.first)
        let copy = try #require(outcome.copy)

        #expect(outcome.completed)
        #expect(!FileManager.default.fileExists(atPath: project.path))
        #expect(copy.lastPathComponent == "vieux-projet")
        #expect(desk.archiveFolderContents() == ["vieux-projet"])
        // Le contenu, le lien, l'attribut étendu et les droits ont suivi.
        let trashed = try #require(try FileManager.default.contentsOfDirectory(at: desk.trash, includingPropertiesForKeys: nil).first)
        #expect(ArchiveSeal.originalMatchesCopy(original: trashed, copy: copy))
        #expect(FileManager.default.contentsEqual(atPath: trashed.appendingPathComponent("Ressources/donnees.bin").path,
                                                  andPath: copy.appendingPathComponent("Ressources/donnees.bin").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("lien").path) == "README.md")
        var buffer = [UInt8](repeating: 0, count: 64)
        let length = getxattr(copy.appendingPathComponent("README.md").path, "fr.meaillais.oust.test", &buffer, 64, 0, 0)
        #expect(String(decoding: buffer.prefix(max(0, length)), as: UTF8.self) == "étiquette")
        let mode = try FileManager.default.attributesOfItem(atPath: copy.appendingPathComponent("Sources/App/main.swift").path)[.posixPermissions] as? Int
        #expect(mode == 0o444)

        let history = await HistoryStore(directory: desk.historyFolder).load()
        #expect(history.count == 1)
        #expect(history.first?.result == .trashed)
        #expect(history.first?.method == .archive(copy: copy.path))
        #expect(history.first?.category == .archives)
    }

    @Test("Une copie qui ne relit pas pareil : rien n'est jeté, la copie inachevée est retirée")
    func corruptedCopy() async throws {
        let desk = try Desk()
        let project = try desk.sampleProject("projet")
        let copier = ArchiveCopier(tamper: { url in
            guard url.lastPathComponent == "donnees.bin", let handle = try? FileHandle(forWritingTo: url) else { return }
            try? handle.seek(toOffset: 1_000)
            try? handle.write(contentsOf: Data([0xFF]))
            try? handle.close()
        })

        let outcomes = await desk.run(desk.archiver(copier: copier), [desk.candidate(project)])
        let outcome = try #require(outcomes.first)

        #expect(outcome.error == .verificationFailed(path: "Ressources/donnees.bin"))
        #expect(outcome.copy == nil)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("Ressources/donnees.bin").path))
        #expect(desk.archiveFolderContents().isEmpty)
        let history = await HistoryStore(directory: desk.historyFolder).load()
        #expect(history.first?.result == .failed(message: "archive.error.verificationFailed"))
    }

    @Test("Un original modifié pendant la copie n'est pas archivé")
    func sourceChangedDuringCopy() async throws {
        let desk = try Desk()
        let project = try desk.sampleProject("projet")
        let readme = project.appendingPathComponent("README.md")
        let copier = ArchiveCopier(tamper: { url in
            guard url.lastPathComponent == "README.md" else { return }
            try? Data("réécrit pendant la copie, plus long qu'avant".utf8).write(to: readme)
        })

        let outcome = try #require(await desk.run(desk.archiver(copier: copier), [desk.candidate(project)]).first)

        #expect(outcome.error == .sourceChanged(path: "README.md"))
        #expect(FileManager.default.fileExists(atPath: readme.path))
        #expect(desk.archiveFolderContents().isEmpty)
    }

    @Test("Modifié entre la copie et la corbeille : l'original reste, la copie aussi")
    func changedBeforeTrash() async throws {
        let desk = try Desk()
        let project = try desk.sampleProject("projet")
        let folder = desk.external.appendingPathComponent("Archives Oust")
        let attempt = ArchiveCopier().copy(project, into: folder, appleDouble: false, progress: ArchiveProgress())
        let copy = try attempt.result.get()
        try desk.file("projet/nouveau.txt", bytes: 10)

        #expect(!ArchiveSeal.originalMatchesCopy(original: project, copy: copy.destination))
        var info = stat()
        lstat(project.path, &info)
        let item = CleanupItem(title: "projet", paths: [project], category: .archives, owner: "Disque externe",
                               ruleID: "archive.project", safety: .review,
                               method: .archive(copy: copy.destination.path), rebuild: .irreversible,
                               fingerprint: Fingerprint(modificationDate: nil, fileID: UInt64(info.st_ino)))
        var report: CleanupReport?
        for await event in desk.engine().run([item]) {
            if case .finished(let final) = event { report = final }
        }

        #expect(report?.outcomes.first?.result == .skipped(.changedSinceScan))
        #expect(FileManager.default.fileExists(atPath: project.path))
        #expect(FileManager.default.fileExists(atPath: copy.destination.path))
    }

    @Test("Un tube nommé ne s'archive pas : on s'arrête, l'original reste")
    func unsupportedFile() async throws {
        let desk = try Desk()
        let project = try desk.sampleProject("projet")
        #expect(mkfifo(project.appendingPathComponent("tube").path, 0o600) == 0)

        let outcome = try #require(await desk.run(desk.archiver(), [desk.candidate(project)]).first)

        #expect(outcome.error == .unsupportedFile(path: "tube"))
        #expect(FileManager.default.fileExists(atPath: project.path))
        #expect(desk.archiveFolderContents().isEmpty)
    }

    @Test("Une archive existante n'est jamais écrasée")
    func neverOverwrites() async throws {
        let desk = try Desk()
        let existing = desk.external.appendingPathComponent("Archives Oust/projet/garder.txt")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("à garder".utf8).write(to: existing)
        let project = try desk.sampleProject("projet")

        let outcome = try #require(await desk.run(desk.archiver(), [desk.candidate(project)]).first)

        #expect(outcome.copy?.lastPathComponent == "projet 2")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "à garder")
    }

    @Test("Un projet où quelqu'un travaille n'est pas copié")
    func busyProject() async throws {
        let desk = try Desk()
        let project = try desk.sampleProject("projet")
        let agent = ActiveProcess(pid: 4, name: "claude", workingDirectory: project.appendingPathComponent("Sources").path)

        let outcome = try #require(await desk.run(desk.archiver(processes: [agent]), [desk.candidate(project)]).first)

        #expect(outcome.result == .skipped(.nowProtected(.activeProcess(name: "claude"))))
        #expect(desk.archiveFolderContents().isEmpty)
    }

    @Test("Le disque qu'on veut libérer est refusé jusqu'au dernier moment")
    func sameVolumeRefusedByArchiver() async throws {
        let desk = try Desk()
        let project = try desk.sampleProject("projet")
        var info = stat()
        lstat(project.path, &info)
        let sameDisk = ArchiveDestination(volumeURL: desk.external, name: "Même disque", fileSystem: "apfs",
                                          available: 1 << 40, isReadOnly: false, isLocal: true, device: info.st_dev)

        var outcomes: [ArchiveOutcome] = []
        for await event in desk.archiver().run([desk.candidate(project)], to: sameDisk, folderName: "Archives Oust") {
            if case .finished(let all) = event { outcomes = all }
        }

        #expect(outcomes.first?.result == .skipped(.refusedByGuard))
        #expect(FileManager.default.fileExists(atPath: project.path))
        #expect(desk.archiveFolderContents().isEmpty)
    }

    @Test("Annulé avant de commencer : rien n'est copié")
    func cancelled() async throws {
        let desk = try Desk()
        let project = try desk.sampleProject("projet")
        let progress = ArchiveProgress()
        progress.cancel()

        let outcome = try #require(await desk.run(desk.archiver(), [desk.candidate(project)], progress: progress).first)

        #expect(outcome.result == .skipped(.cancelled))
        #expect(FileManager.default.fileExists(atPath: project.path))
    }

    @Test("Seuls les projets inactifs sont proposés, et pas ceux qu'on ne peut pas déplacer")
    func candidates() async throws {
        let desk = try Desk()
        let old = try desk.sampleProject("ancien")
        let busy = try desk.sampleProject("occupe")
        _ = try desk.sampleProject("recent")
        try desk.file("worktree/.git", bytes: 40)
        desk.age(old, days: 400)
        desk.age(busy, days: 400)
        desk.age(desk.projects.appendingPathComponent("worktree"), days: 400)
        let agent = ActiveProcess(pid: 4, name: "codex", workingDirectory: busy.path)

        let found = await ProjectCandidates.find(in: [desk.projects], inactiveSince: Date().addingTimeInterval(-180 * 86_400),
                                                 home: desk.home, processes: ProcessSnapshot(processes: [agent]))
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["ancien", "occupe", "worktree"])
        #expect(byName["ancien"]?.isArchivable == true)
        #expect(byName["ancien"]?.sizes.allocated ?? 0 > 2_500_000)
        #expect(byName["occupe"]?.blocker == .activeProcess(name: "codex"))
        #expect(byName["worktree"]?.blocker == .isWorktree)
    }

    @Test("Des projets imbriqués et une racine projet sont reconnus sans doublons")
    func nestedProjects() async throws {
        let desk = try Desk()
        let old = try desk.sampleProject("client/ancien")
        try desk.file("client/ancien/package.json", bytes: 20)
        desk.age(old, days: 400)
        let found = await ProjectCandidates.find(in: [desk.projects, old], inactiveSince: Date().addingTimeInterval(-180 * 86_400),
            home: desk.home, processes: ProcessSnapshot(processes: []))
        #expect(found.map { $0.url.resolvingSymlinksInPath().path } == [old.resolvingSymlinksInPath().path])
    }

    @Test("Un cache récent ne réveille pas un projet dont les sources sont anciennes")
    func generatedActivity() async throws {
        let desk = try Desk()
        let old = try desk.sampleProject("ancien")
        try desk.file("ancien/package.json", bytes: 20)
        desk.age(old, days: 400)
        try desk.file("ancien/node_modules/dependance/index.js", bytes: 100)
        let found = await ProjectCandidates.find(in: [desk.projects], inactiveSince: Date().addingTimeInterval(-180 * 86_400),
            home: desk.home, processes: ProcessSnapshot(processes: []))
        #expect(found.count == 1)
        #expect(found.first?.lastModified ?? .distantFuture < Date().addingTimeInterval(-180 * 86_400))
        #expect(found.first?.fileCount == 6)
    }

    @Test("Un point dans le nom du dossier ne transforme pas le projet en paquet")
    func dottedFolder() async throws {
        let desk = try Desk()
        let project = try desk.sampleProject("site.fr")
        try desk.file("site.fr/package.json", bytes: 20)
        desk.age(project, days: 400)
        let found = await ProjectCandidates.find(in: [desk.projects], inactiveSince: Date().addingTimeInterval(-180 * 86_400),
            home: desk.home, processes: ProcessSnapshot(processes: []))
        #expect(found.map(\.name) == ["site.fr"])
    }

    @Test("Une source modifiée récemment reste active même si les caches sont anciens")
    func sourceActivity() async throws {
        let desk = try Desk()
        let project = try desk.sampleProject("actif")
        desk.age(project, days: 400)
        try desk.file("actif/nouveau.swift", bytes: 100)
        let found = await ProjectCandidates.find(in: [desk.projects], inactiveSince: Date().addingTimeInterval(-180 * 86_400),
            home: desk.home, processes: ProcessSnapshot(processes: []))
        #expect(found.isEmpty)
    }

    @Test("Le volume d'arrivée : APFS conseillé, exFAT signalé, et les refus")
    func destinationChecks() throws {
        let desk = try Desk()
        #expect(desk.destination().advice == .recommended)
        #expect(desk.destination(fileSystem: "exfat").advice == .warning(.exfat))
        #expect(desk.destination(fileSystem: "exfat").storesAppleDouble)
        #expect(desk.destination(fileSystem: "msdos").advice == .warning(.fat))

        let fat = ArchiveDestination(volumeURL: desk.external, name: "CLE", fileSystem: "msdos", available: 10_000_000_000,
                                     isReadOnly: true, isLocal: true, device: 3)
        let refusals = fat.refusals(sourceDevices: [3], logicalBytes: 12_000_000_000,
                                    largestFile: ("film.mkv", 5_000_000_000))
        #expect(refusals.contains(.readOnly))
        #expect(refusals.contains(.sameVolume))
        #expect(refusals.contains(.notEnoughSpace(needed: 12_240_000_000, available: 10_000_000_000)))
        #expect(refusals.contains(.fileTooLarge(name: "film.mkv")))
        #expect(desk.destination().refusals(sourceDevices: [3], logicalBytes: 1_000, largestFile: nil).isEmpty)
    }

    @Test("Seul un dossier de préparation peut être retiré par l'archivage")
    func stagingDiscard() throws {
        let desk = try Desk()
        let ordinary = desk.external.appendingPathComponent("projet")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        let staging = desk.external.appendingPathComponent(ArchiveStaging.name(for: "projet"))
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("lecture-seule"), withIntermediateDirectories: true)
        chmod(staging.appendingPathComponent("lecture-seule").path, 0o555)
        let guardForTests = PathGuard(home: desk.home)

        #expect(!ArchiveStaging.discard(ordinary, pathGuard: guardForTests))
        #expect(FileManager.default.fileExists(atPath: ordinary.path))
        #expect(ArchiveStaging.discard(staging, pathGuard: guardForTests))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("Le plan mesure la taille logique et le plus gros fichier")
    func plan() throws {
        let desk = try Desk()
        let project = try desk.sampleProject("projet")
        let plan = try #require(ArchivePlan.measure(project))
        #expect(plan.logicalBytes == 1_200 + 30_000 + 2_500_000)
        #expect(plan.largestFile == "donnees.bin")
    }
}
