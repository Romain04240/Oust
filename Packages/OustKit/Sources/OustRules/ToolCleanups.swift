import Foundation
import OustCore
import OustSafety

/// Ce que des outils savent nettoyer eux-mêmes : Homebrew, Docker, OrbStack.
///
/// On leur demande d'abord, à blanc, ce qu'ils retireraient ; c'est ce qu'on
/// montre. Le vrai nettoyage n'est lancé que depuis la corbeille, après
/// confirmation, et par l'outil lui-même (RULES.md, règle 6).
struct ToolCleanupsFinder {
    let context: RuleContext

    func find() async -> [Candidate] {
        async let brew = homebrew()
        async let containers = containerEngines()
        return await brew + containers
    }

    // MARK: - Homebrew

    /// Homebrew sans réseau : ni mise à jour automatique, ni appel à GitHub, ni
    /// statistiques (RULES.md, règle 11).
    static let brewEnvironment = [
        "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_GITHUB_API": "1", "HOMEBREW_NO_AUTOREMOVE": "1",
    ]

    func homebrew() async -> [Candidate] {
        guard let brew = context.tools.locate(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) else { return [] }
        // Pour lister les anciennes versions, Homebrew lit la description des
        // formules : depuis son cache local ou depuis le dépôt homebrew-core.
        // Sans l'un ni l'autre, il irait la chercher en ligne ; on s'abstient.
        let prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent()
        let offline = [
            context.path("Library/Caches/Homebrew/api/formula.jws.json"),
            prefix.appendingPathComponent("Library/Taps/homebrew/homebrew-core"),
        ].contains { FileManager.default.fileExists(atPath: $0.path) }
        guard offline else { return [] }
        let dryRun = await context.tools.run(brew, ["cleanup", "--dry-run"], Self.brewEnvironment, 180)
        guard dryRun.succeeded else { return [] }
        // Le cache de téléchargements a déjà sa règle (`cache.homebrew`) : ne pas
        // le compter deux fois (RULES.md, règle 9).
        let cache = context.path("Library/Caches/Homebrew").path
        let paths = Self.brewPaths(in: dryRun.output)
            .filter { !PathNormalizer.isWithin($0, cache) }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) || $0.isSymbolicLink }
        guard !paths.isEmpty else { return [] }
        return [Candidate(item: CleanupItem(
            id: "brew-cleanup|\(brew)", title: "Homebrew", detail: "brew cleanup", paths: paths,
            category: .toolVersions, owner: "Homebrew", ruleID: "tool.brew_cleanup", safety: .safe,
            method: .brewCleanup(executable: brew), rebuild: .nothing
        ))]
    }

    /// Les chemins des lignes « Would remove: /opt/homebrew/Cellar/x/1.0 (12 files, 3.4MB) ».
    ///
    /// La taille annoncée par Homebrew est une taille logique : on ne la reprend
    /// pas, on mesure les chemins nous-mêmes (RULES.md, règle 9).
    static func brewPaths(in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Would remove: ") else { return nil }
            var path = String(line.dropFirst("Would remove: ".count))
            if let open = path.range(of: " (", options: .backwards), path.hasSuffix(")") {
                path = String(path[..<open.lowerBound])
            }
            return path.hasPrefix("/") ? path : nil
        }
    }

    // MARK: - Docker et OrbStack

    /// Les processus d'un moteur déjà lancé. La CLI d'OrbStack démarre sa machine
    /// virtuelle à la première commande : une analyse ne doit rien démarrer.
    static let engineProcesses = ["OrbStack", "OrbStack Helper", "com.docker.backend", "Docker Desktop", "limactl"]

    func containerEngines() async -> [Candidate] {
        guard Self.engineProcesses.contains(where: context.processes.isRunning) else { return [] }
        guard let docker = context.tools.locate([
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker", context.path(".orbstack/bin/docker").path,
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]) else { return [] }
        // Un contexte peut désigner un démon distant (`ssh://`, `tcp://`) : on ne
        // l'interroge pas (RULES.md, règle 11), et on n'y supprimerait rien.
        let endpoint = await context.tools.run(docker, ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], nil, 15)
        guard endpoint.succeeded, endpoint.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("unix://") else {
            return []
        }
        let contextName = await context.tools.run(docker, ["context", "show"], nil, 10)
        let engine = Self.engineName(contextName.succeeded ? contextName.output : "")
        var candidates: [Candidate] = []

        func candidate(_ title: String, scope: PruneScope, ids: [String], rule: String, safety: SafetyClass,
                       bytes: Int64, rebuild: RebuildCost) -> Candidate {
            Candidate(item: CleanupItem(
                id: "container|\(docker)|\(scope.rawValue)", title: title, detail: engine, paths: [],
                category: .containers, owner: engine, ruleID: rule, safety: safety,
                // L'espace se libère dans le disque virtuel du moteur, qui le rend au
                // Mac en se compactant : hors du total en titre, comme `Docker.raw`.
                notes: [.managedSeparately],
                method: .containerPrune(executable: docker, scope: scope, ids: ids),
                sizes: Sizes(private: bytes), rebuild: rebuild
            ), needsMeasure: false)
        }

        let usage = await context.tools.run(docker, ["system", "df", "--format", "{{json .}}"], nil, 60)
        if usage.succeeded, let cache = Self.usageLines(usage.output).first(where: { $0.type == "Build Cache" }), cache.reclaimable > 0 {
            candidates.append(candidate("Build Cache", scope: .buildCache, ids: [], rule: "container.build_cache",
                                        safety: .rebuilds, bytes: cache.reclaimable,
                                        rebuild: .command("docker build", minutes: 5)))
        }
        // Images et conteneurs : relevés un à un, pour ne retirer ensuite que ce
        // qu'on a montré. Une sortie qu'on ne sait pas lire ne propose rien.
        let detail = await context.tools.run(docker, ["system", "df", "-v", "--format", "{{json .}}"], nil, 120)
        if detail.succeeded, let verbose = Self.verboseUsage(detail.output) {
            if !verbose.unusedImages.isEmpty {
                // Une image construite ici ne se retélécharge pas : l'utilisateur décide.
                candidates.append(candidate("Images", scope: .unusedImages, ids: verbose.unusedImages,
                                            rule: "container.images", safety: .review, bytes: verbose.imageBytes,
                                            rebuild: .command("docker pull · docker build", minutes: nil)))
            }
            if !verbose.stoppedContainers.isEmpty {
                // Un conteneur arrêté garde ce qu'on y a écrit : l'utilisateur décide.
                candidates.append(candidate("Containers", scope: .stoppedContainers, ids: verbose.stoppedContainers,
                                            rule: "container.stopped", safety: .review, bytes: verbose.containerBytes,
                                            rebuild: .irreversible))
            }
        }
        return candidates
    }

    struct VerboseUsage: Sendable, Equatable {
        /// Références (`dépôt:étiquette`, ou identifiant si l'image n'en a pas).
        var unusedImages: [String] = []
        /// Ce qu'elles occupent en propre (`UniqueSize`) : les couches partagées
        /// avec une image gardée ne seraient pas rendues.
        var imageBytes: Int64 = 0
        var stoppedContainers: [String] = []
        var containerBytes: Int64 = 0
    }

    /// `docker system df -v --format '{{json .}}'` : un objet avec `Images` et `Containers`.
    static func verboseUsage(_ output: String) -> VerboseUsage? {
        guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = object["Images"] as? [[String: Any]], let containers = object["Containers"] as? [[String: Any]] else {
            return nil
        }
        var usage = VerboseUsage()
        var counted = Set<String>()
        for image in images where (image["Containers"] as? String) == "0" {
            guard let id = image["ID"] as? String, PruneScope.isPlainReference(id) else { continue }
            let repository = image["Repository"] as? String ?? "<none>"
            let tag = image["Tag"] as? String ?? "<none>"
            let reference = repository != "<none>" && tag != "<none>" ? "\(repository):\(tag)" : id
            guard PruneScope.isPlainReference(reference), !usage.unusedImages.contains(reference) else { continue }
            usage.unusedImages.append(reference)
            if counted.insert(id).inserted {
                usage.imageBytes += (image["UniqueSize"] as? String).flatMap(dockerBytes) ?? 0
            }
        }
        for container in containers {
            guard let state = container["State"] as? String, ["exited", "created", "dead"].contains(state),
                  let id = container["ID"] as? String, PruneScope.isPlainReference(id) else { continue }
            usage.stoppedContainers.append(id)
            usage.containerBytes += (container["Size"] as? String).flatMap(dockerBytes) ?? 0
        }
        return usage
    }

    struct UsageLine: Sendable, Equatable {
        let type: String
        let reclaimable: Int64
    }

    /// Une ligne JSON par type : `{"Type":"Images","Reclaimable":"1.2GB (50%)",…}`.
    static func usageLines(_ output: String) -> [UsageLine] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["Type"] as? String else { return nil }
            let reclaimable = (object["Reclaimable"] as? String).flatMap(dockerBytes) ?? 0
            return UsageLine(type: type, reclaimable: reclaimable)
        }
    }

    /// « 1.234GB (50%) » → 1 234 000 000. Docker compte en base 1000, comme le Finder.
    static func dockerBytes(_ text: String) -> Int64? {
        let value = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, scale) in units where value.hasSuffix(suffix) {
            guard let number = Double(value.dropLast(suffix.count)) else { return nil }
            return Int64(number * scale)
        }
        return nil
    }

    /// Le moteur derrière la CLI, d'après le contexte actif.
    static func engineName(_ context: String) -> String {
        let name = context.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "orbstack": return "OrbStack"
        case "desktop-linux", "default", "": return "Docker"
        default: return name
        }
    }
}
