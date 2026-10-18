import Darwin
import Foundation
import OustCore
import OustSafety
import zlib

/// Les projets que personne n'a touchés depuis des mois, à compresser sur place
/// avec la compression transparente d'APFS : les fichiers restent là, lisibles
/// comme avant, et occupent moins.
///
/// « À examiner » : le contenu ne change pas (chaque fichier compressé est relu et
/// comparé avant de remplacer l'original), mais chaque fichier est réécrit. Time
/// Machine les sauvegardera tous à nouveau, et tant qu'un snapshot local garde
/// les anciens blocs, rien n'est rendu. L'utilisateur choisit en connaissance de
/// cause.
struct CompressionFinder {
    let context: RuleContext

    func find() async -> [Candidate] {
        // Ni téléchargement iCloud, ni date d'accès réécrite : lire pour estimer
        // ne doit rien changer (comme le parcours, SPEC §3.1).
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_PROCESS, IOPOL_ATIME_UPDATES_OFF)
        let cutoff = context.now.addingTimeInterval(-Double(context.compressionAgeDays) * 86_400)
        let fileManager = FileManager.default
        var candidates: [Candidate] = []
        for root in context.projectRoots {
            for project in fileManager.children(of: root)
            where fileManager.isDirectory(project) && !project.isSymbolicLink && !project.lastPathComponent.hasPrefix(".") {
                guard context.processes.busy(under: project.path) == nil,
                      let survey = CompressionSurvey.survey(project, cutoff: cutoff) else { continue }
                let estimate = survey.estimatedSavings()
                guard estimate >= CompressionSurvey.minimumProjectSavings else { continue }
                candidates.append(Candidate(item: CleanupItem(
                    id: "compress|\(project.path)", title: project.lastPathComponent,
                    detail: project.abbreviated(home: context.home), paths: [project],
                    category: .compressibleProjects, owner: root.lastPathComponent, ruleID: "compress.project",
                    safety: .review, notes: [.estimated], method: .compressInPlace,
                    sizes: Sizes(private: estimate), lastActivity: survey.latestModification,
                    rebuild: .nothing, activityScope: project
                ), needsMeasure: false))
            }
        }
        return candidates
    }
}

/// Ce qu'un projet gagnerait à être compressé, estimé sans rien écrire.
///
/// Les règles de l'estimation sont celles qu'on a mesurées sur un volume APFS
/// de test le 18/10/2026 : un fichier compressé garde au moins un bloc de
/// 4 Kio (les petits fichiers ne rendent rien), et le reste suit la taille
/// compressée, arrondie au bloc. L'échantillon compressé pour de bon donne le
/// taux ; on retire encore 10 % pour ne pas promettre plus qu'on ne rendra
/// (RULES.md, règle 9). Le chiffre réel est mesuré fichier par fichier au
/// moment de compresser, et c'est lui qui entre à l'historique.
struct CompressionSurvey: Sendable {
    struct File: Sendable {
        let url: URL
        let size: Int64
        let allocated: Int64
        let fileExtension: String
    }

    var files: [File] = []
    var latestModification: Date?

    /// Ce que la compression laisse tel quel : les mêmes règles que `Compressor`
    /// (`CompressionPolicy`), sinon l'estimation compterait ce qui ne sera pas compressé.
    static let minimumFileAllocated = CompressionPolicy.minimumFileAllocated
    static let maximumFileSize = CompressionPolicy.maximumFileSize
    static let block: Int64 = 4_096
    static let chunk = 65_536
    /// Ce qu'on compresse vraiment pour estimer, par projet.
    static let sampleBudget = 16 * 1_048_576
    /// Un projet qui rendrait moins n'est pas proposé.
    static let minimumProjectSavings: Int64 = 10_000_000

    /// Parcourt le projet ; `nil` si quelque chose y a bougé depuis `cutoff`.
    static func survey(_ project: URL, cutoff: Date) -> CompressionSurvey? {
        var survey = CompressionSurvey()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: project, includingPropertiesForKeys: keys, options: []) else {
            return nil
        }
        let me = getuid()
        let device = FileFacts.of(project.path)?.device
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if let modified = values.contentModificationDate {
                // Un seul fichier récent, et le projet n'est pas endormi.
                if modified > cutoff { return nil }
                if modified > (survey.latestModification ?? .distantPast) { survey.latestModification = modified }
            }
            if values.isDirectory == true {
                if CompressionPolicy.skipsFolder(named: url.lastPathComponent) || FileFacts.of(url.path)?.device != device {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let fileExtension = url.pathExtension.lowercased()
            guard !CompressionPolicy.skipsFile(named: url.lastPathComponent), let facts = FileFacts.of(url.path),
                  isEligible(facts, owner: me), !FileFacts.hasResourceFork(url.path),
                  !FileFacts.mayShareBlocks(url.path) else { continue }
            survey.files.append(File(url: url, size: facts.size, allocated: facts.allocated, fileExtension: fileExtension))
        }
        // Un fichier qu'un processus garde ouvert ne sera pas compressé : il ne compte pas.
        // Cherché une fois le projet reconnu endormi, la table des fichiers ouverts coûte cher.
        let open = OpenFiles.paths(under: project.path)
        if !open.isEmpty { survey.files.removeAll { open.contains(PathNormalizer.normalize($0.url.path)) } }
        return survey
    }

    /// Ce que la compression ne touche pas : déjà compressé, verrouillé, resté
    /// dans le nuage, lié ailleurs (lien physique), à un autre utilisateur, trop
    /// petit pour rendre quoi que ce soit, trop gros pour la mémoire.
    static func isEligible(_ facts: FileFacts, owner: uid_t) -> Bool {
        facts.isRegularFile && !facts.isCompressed && !facts.isLocked && !facts.isDataless && facts.linkCount == 1
            && facts.owner == owner && facts.allocated >= minimumFileAllocated && facts.size > 0
            && facts.size <= maximumFileSize
    }

    /// Le gain estimé, prudent.
    func estimatedSavings() -> Int64 {
        var ratios: [String: (input: Int64, output: Int64)] = [:]
        var overall: (input: Int64, output: Int64) = (0, 0)
        var budget = Self.sampleBudget
        // Les plus gros d'abord : ce sont eux qui font le chiffre.
        for file in files.sorted(by: { $0.allocated > $1.allocated }) where budget > 0 {
            guard let sample = Self.sample(file.url, length: min(Self.chunk, Int(file.size))) else { continue }
            let compressed = Int64(Self.deflatedSize(sample))
            budget -= sample.count
            ratios[file.fileExtension, default: (0, 0)].input += Int64(sample.count)
            ratios[file.fileExtension, default: (0, 0)].output += compressed
            overall.input += Int64(sample.count)
            overall.output += compressed
        }
        guard overall.input > 0 else { return 0 }
        let fallback = Double(overall.output) / Double(overall.input)
        var savings: Int64 = 0
        for file in files {
            let ratio = ratios[file.fileExtension].map { Double($0.output) / Double(max(1, $0.input)) } ?? fallback
            let after = Self.allocatedAfterCompression(size: file.size, ratio: ratio)
            savings += max(0, file.allocated - after)
        }
        return savings * 9 / 10
    }

    /// Ce qu'occuperait le fichier compressé : la ressource (en-tête, table des
    /// blocs, blocs, carte), arrondie au bloc, jamais moins d'un bloc.
    static func allocatedAfterCompression(size: Int64, ratio: Double) -> Int64 {
        let chunks = (size + Int64(chunk) - 1) / Int64(chunk)
        let overhead = 0x100 + 8 + 8 * chunks + 50
        let compressed = Int64((Double(size) * min(1.05, max(0, ratio))).rounded(.up)) + overhead
        return max(block, (compressed + block - 1) / block * block)
    }

    static func sample(_ url: URL, length: Int) -> [UInt8]? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: length)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, length) }
        guard count > 0 else { return nil }
        return Array(buffer.prefix(count))
    }

    /// La taille zlib d'un bloc, au niveau qu'utilisera la compression.
    static func deflatedSize(_ input: [UInt8]) -> Int {
        var length = compressBound(uLong(input.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = output.withUnsafeMutableBufferPointer { out in
            input.withUnsafeBufferPointer { source in
                compress2(out.baseAddress, &length, source.baseAddress, uLong(input.count), 6)
            }
        }
        return status == Z_OK ? Int(length) : input.count
    }
}
