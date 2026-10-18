import Foundation
import OustClean
import OustCore
import OustDesignSystem
import OustLocalization
import OustRules
import OustSafety
import OustScan

/// Analyser, expliquer, nettoyer : ce que la CLI et le serveur MCP offrent aux
/// agents, au-dessus des moteurs de l'app et sans rien en recopier.
///
/// Les chercheurs (`RuleEngine`) trouvent et classent, `CleanupEngine`
/// revalide et supprime, `HistoryStore` journalise. Ce service n'ajoute que ce
/// qui tient à un agent : l'aperçu obligatoire, la politique plus étroite que
/// celle de l'app, et le JSON.
public struct AgentService: Sendable {
    public let environment: AgentEnvironment

    public init(environment: AgentEnvironment) {
        self.environment = environment
    }

    // MARK: - Arguments

    /// `projectArtifacts,agents` ou plusieurs valeurs ; rien : tous les chercheurs.
    public func finders(named names: [String]) throws -> [FinderKind] {
        let names = names.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return FinderKind.homeCases }
        var kinds: [FinderKind] = []
        for name in names {
            guard let kind = FinderKind(rawValue: name) else { throw AgentError.unknownFinder(name) }
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        return kinds
    }

    /// Des chemins absolus, `~` compris, qui doivent exister.
    public func paths(_ raw: [String]) throws -> [URL] {
        var urls: [URL] = []
        for text in raw where !text.isEmpty {
            let expanded = text == "~" ? environment.home.path
                : text.hasPrefix("~/") ? environment.home.path + text.dropFirst(1) : text
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : environment.workingDirectory.appendingPathComponent(expanded)
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path) else { throw AgentError.pathNotFound(text) }
            if !urls.contains(standardized) { urls.append(standardized) }
        }
        return urls
    }

    // MARK: - Analyse

    /// Une analyse à blanc : rien n'est touché, un aperçu est gardé.
    ///
    /// `limit` garde les plus gros ; le jeton ne couvre que ce qui est montré.
    public func scan(finders: [FinderKind], paths: [URL] = [], limit: Int? = nil) async -> ScanReport {
        let now = environment.now()
        let items = await collect(finders: finders, paths: paths)
        let policy = PreselectionPolicy(recencyDays: environment.recencyDays)
        let shownItems = limit.map { Array(items.prefix(max(0, $0))) } ?? items
        let shown = shownItems.map { ItemReport($0, preselected: policy.preselects($0, now: now)) }

        func bytes(_ include: (CleanupItem) -> Bool) -> Int64 {
            items.filter(include).reduce(0) { $0 + $1.sizes.freeable }
        }
        let totals = ScanTotals(
            items: items.count,
            shown: shown.count,
            freeableBytes: bytes { $0.isSelectable && $0.countsInHeadline },
            allowedBytes: bytes { AgentPolicy.verdict(for: $0) == .allowed },
            needsAllowReviewBytes: bytes { AgentPolicy.verdict(for: $0) == .needsReviewFlag }
        )
        var report = ScanReport(
            generatedAt: now,
            scope: ScopeReport(finders: finders.map(\.rawValue), paths: paths.map(\.path)),
            totals: totals,
            truncated: shown.count < items.count,
            items: shown,
            warnings: []
        )

        let preview = Preview(
            token: Preview.newToken(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(environment.previewLifetime),
            finders: finders.map(\.rawValue),
            paths: paths.map(\.path),
            items: shown,
            seals: Dictionary(shownItems.map { ($0.id, Preview.seal(of: $0)) }, uniquingKeysWith: { first, _ in first })
        )
        do {
            try await store().save(preview, now: now)
            report.token = preview.token
            report.expiresAt = preview.expiresAt
        } catch {
            // L'analyse reste utile à lire ; elle ne permet simplement pas de nettoyer.
            report.warnings.append(L10n.string("agent.warning.previewNotSaved", error.localizedDescription))
        }
        return report
    }

    /// Les éléments que trouvent les chercheurs, dans la portée demandée, du
    /// plus libérable au moins.
    ///
    /// `wanted` : ne mesurer que ces chemins (le nettoyage ne remesure pas tout
    /// un dossier de projets pour trois éléments).
    func collect(finders: [FinderKind], paths: [URL], measuring wanted: Set<String>? = nil) async -> [CleanupItem] {
        let snapshot = environment.agentProcesses()
        // Avec une portée, seuls comptent les dossiers de projets qui la
        // contiennent (ils disent où commence chaque projet) ou qu'elle contient :
        // les autres ne donneraient que des éléments hors de portée.
        let roots = paths.isEmpty ? environment.projectRoots : environment.projectRoots.filter { root in
            paths.contains { PathNormalizer.isWithin($0.path, root.path) || PathNormalizer.isWithin(root.path, $0.path) }
        }
        // Un chemin hors des dossiers de projets réglés est parcouru comme un
        // dossier de projets de plus.
        let extraRoots = paths.filter { path in !roots.contains { PathNormalizer.isWithin(path.path, $0.path) } }
        let context = environment.ruleContext(roots: roots + extraRoots, processes: snapshot)

        let scope = paths.map(\.path)
        let inScope: @Sendable (URL) -> Bool = { url in
            scope.isEmpty || scope.contains { PathNormalizer.isWithin(url.path, $0) }
        }
        let isWanted: @Sendable (URL) -> Bool = { url in
            wanted.map { $0.contains(PathNormalizer.normalize(url.path)) } ?? true
        }
        // Ce qui est hors de portée n'est pas mesuré : `RuleEngine` écarte ce
        // qui mesure zéro, et rien n'a été parcouru pour rien.
        let measurer = Measurer { urls in
            await Scanner.measure(urls.filter { inScope($0) && isWanted($0) })
        }

        var seen = Set<String>()
        var items: [CleanupItem] = []
        for var item in await RuleEngine.collect(context, finders: finders, measurer: measurer) {
            guard !item.paths.isEmpty, item.paths.allSatisfy(inScope), item.paths.contains(where: isWanted),
                  seen.insert(item.id).inserted else { continue }
            widenActivityScope(of: &item, extraRoots: extraRoots, processes: snapshot)
            items.append(item)
        }
        return items.sorted {
            $0.sizes.freeable != $1.sizes.freeable ? $0.sizes.freeable > $1.sizes.freeable : $0.id < $1.id
        }
    }

    /// Hors des dossiers de projets réglés, un `--path` ne dit pas où commence
    /// le projet, et `RuleContext` prendrait son premier sous-dossier pour le
    /// projet entier. Le dépôt git qui contient l'artefact en tient lieu : ce
    /// qui travaille n'importe où dans le dépôt le protège (le 18/10/2026, `adb`
    /// tournait à la racine d'un projet, loin du dossier `build` visé).
    func widenActivityScope(of item: inout CleanupItem, extraRoots: [URL], processes: ProcessSnapshot) {
        guard item.category == .projectArtifacts, let first = item.paths.first,
              extraRoots.contains(where: { root in item.paths.allSatisfy { PathNormalizer.isWithin($0.path, root.path) } }),
              let repository = GitInspector.repositoryRoot(containing: first.deletingLastPathComponent()) else { return }
        if let scope = item.activityScope, PathNormalizer.isWithin(repository.path, scope.path) { return }
        item.activityScope = repository
        if let process = processes.busy(under: repository.path) {
            item.protect(.activeProcess(name: process.name))
        }
    }

    // MARK: - Explication

    /// Ce que c'est, comment ça revient, ce qu'Oust! en fera.
    ///
    /// Un élément montré par un aperçu récent est expliqué en entier ; à défaut,
    /// un identifiant de règle (`cache.npm`) l'est au moins par sa règle.
    public func explain(_ id: String) async throws -> ExplainReport {
        let item = await store().latestItem(id: id)
        let rule = item?.rule ?? String(id.split(separator: "|", maxSplits: 1).first ?? "")
        let what = Describe.ruleWhat(rule)
        // Une règle inconnue du catalogue rend sa clé telle quelle.
        guard item != nil || what != "rule.\(rule).what" else { throw AgentError.unknownItems([id]) }
        let back = [Describe.ruleBack(rule), item?.rebuild.label].compactMap { $0 }.joined(separator: " ")
        return ExplainReport(id: id, rule: rule, title: Describe.ruleTitle(rule), what: what, back: back,
                             method: item?.method.label, protections: item?.protections.map(\.label) ?? [],
                             item: item)
    }

    // MARK: - Nettoyage

    /// Nettoie des éléments montrés par un aperçu, par `CleanupEngine`.
    ///
    /// Tout ou rien avant d'agir : un identifiant inconnu, un élément refusé ou
    /// changé depuis l'aperçu, et rien n'est touché. Ensuite, chaque élément est
    /// revalidé juste avant de partir (RULES.md, règle 2) et journalisé.
    ///
    /// Sans `token`, le plus récent des aperçus valables qui les contient tous.
    public func clean(ids requested: [String], token: String?, allowReview: Bool = false, dryRun: Bool = false,
                      progress: (@Sendable (OutcomeReport) -> Void)? = nil) async throws -> CleanReport {
        var ids: [String] = []
        for id in requested where !id.isEmpty && !ids.contains(id) { ids.append(id) }
        guard !ids.isEmpty else { throw AgentError.usage(L10n.string("agent.error.noIDs")) }

        let started = environment.now()
        let store = await store()
        let preview: Preview
        if let token {
            guard let found = store.preview(token: token), found.expiresAt > started else { throw AgentError.tokenExpired }
            let unknown = ids.filter { found.item($0) == nil }
            guard unknown.isEmpty else { throw AgentError.unknownItems(unknown) }
            preview = found
        } else {
            guard let found = store.latest(containing: ids, now: started) else { throw AgentError.previewRequired }
            preview = found
        }

        // On repart du disque, et non de l'aperçu : ce qui part est ce que les
        // chercheurs trouvent à cet instant, avec sa classe d'à présent.
        let previewed = ids.compactMap(preview.item)
        let wanted = Set(previewed.flatMap(\.paths).map(PathNormalizer.normalize))
        let current = await collect(finders: preview.finders.compactMap(FinderKind.init(rawValue:)),
                                    paths: preview.paths.map { URL(fileURLWithPath: $0) }, measuring: wanted)
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = ids.compactMap { byID[$0] }
        let vanished = previewed.filter { byID[$0.id] == nil }

        let refusals = items.compactMap { refusal(of: $0, allowReview: allowReview) }
        guard refusals.isEmpty else { throw AgentError.refused(refusals) }
        let changed = items.filter { preview.seals[$0.id] != Preview.seal(of: $0) }.map(\.id)
        guard changed.isEmpty else { throw AgentError.changedSincePreview(changed) }

        if dryRun {
            let outcomes = items.map { OutcomeReport(wouldClean: ItemReport($0, preselected: false)) }
                + vanished.map(OutcomeReport.init(vanished:))
            let now = items.filter(\.method.freesImmediately).reduce(0) { $0 + $1.sizes.freeable }
            let later = items.filter { !$0.method.freesImmediately }.reduce(0) { $0 + $1.sizes.freeable }
            return CleanReport(dryRun: true, token: preview.token, startedAt: started, finishedAt: environment.now(),
                               outcomes: outcomes,
                               totals: Self.totals(outcomes, freedNow: now, pendingInTrash: later, measured: nil, heldBack: 0))
        }

        // Tout entre au journal d'Oust! : s'il ne peut pas être écrit (bac à sable
        // d'un agent, droits), on ne nettoie pas sans trace.
        do {
            try await environment.history.ensureWritable()
        } catch {
            throw AgentError.journalUnavailable(error.localizedDescription)
        }

        let environment = environment
        let engine = CleanupEngine(
            trasher: environment.trasher,
            history: environment.history,
            pathGuard: PathGuard(home: environment.home),
            processes: { environment.agentProcesses() },
            capacity: environment.capacity,
            // Jamais d'invite administrateur depuis un agent (`AgentPolicy`) ; la
            // politique refuse déjà les snapshots, ceci en est la ceinture.
            deleteSnapshots: { _ in false },
            runningApps: environment.runningApps,
            // Effacé sur place, sans dossier de transit : le processus s'arrête
            // juste après, et le chiffre rendu doit déjà être vrai.
            transit: nil,
            // L'Historique de l'app distingue ce qu'un agent a nettoyé.
            origin: .agent(name: environment.agentName())
        )
        // L'annulation (`notifications/cancelled` en MCP) arrête le nettoyage
        // entre deux éléments ; le flux, lui, va jusqu'au bilan. D'où une tâche
        // à part, que l'annulation de l'appelant n'interrompt pas.
        let cancellation = CleanupCancellation()
        let consumer = Task { () -> CleanupReport? in
            var report: CleanupReport?
            for await event in engine.run(items, cancellation: cancellation) {
                switch event {
                case .itemFinished(let outcome): progress?(OutcomeReport(outcome))
                case .finished(let final): report = final
                case .began, .itemBegan: break
                }
            }
            return report
        }
        let report = await withTaskCancellationHandler {
            await consumer.value
        } onCancel: {
            cancellation.cancel()
        }

        let outcomes = (report?.outcomes ?? []).map(OutcomeReport.init) + vanished.map(OutcomeReport.init(vanished:))
        return CleanReport(
            dryRun: false, token: preview.token, startedAt: started, finishedAt: environment.now(),
            outcomes: outcomes,
            totals: Self.totals(outcomes, freedNow: report?.expectedNow ?? 0, pendingInTrash: report?.pendingInTrash ?? 0,
                                measured: report?.measuredNow, heldBack: report?.heldBack ?? 0)
        )
    }

    /// Pourquoi l'agent ne peut pas nettoyer cet élément, ou `nil`.
    func refusal(of item: CleanupItem, allowReview: Bool) -> AgentError.Refusal? {
        let verdict = AgentPolicy.verdict(for: item)
        switch verdict {
        case .allowed:
            return nil
        case .needsReviewFlag:
            return allowReview ? nil : AgentError.Refusal(id: item.id, reason: verdict.code,
                                                          label: L10n.string("agent.verdict.needsAllowReview"))
        case .refused(let refusal):
            // Un élément protégé dit pourquoi : « node travaille ici » apprend
            // plus à l'agent que « protégé ».
            let reasons = item.protections.map(Describe.protection)
            let label = refusal == .protected && !reasons.isEmpty
                ? reasons.joined(separator: ", ") : L10n.string(refusal.localizationKey)
            return AgentError.Refusal(id: item.id, reason: refusal.rawValue, label: label)
        }
    }

    static func totals(_ outcomes: [OutcomeReport], freedNow: Int64, pendingInTrash: Int64, measured: Int64?,
                       heldBack: Int64) -> CleanTotals {
        CleanTotals(
            requested: outcomes.count,
            succeeded: outcomes.count(where: \.succeeded),
            skipped: outcomes.count(where: { $0.result == "skipped" }),
            failed: outcomes.count(where: { $0.result == "failed" }),
            freedNowBytes: freedNow,
            pendingInTrashBytes: pendingInTrash,
            measuredFreedBytes: measured,
            heldBackBytes: heldBack
        )
    }

    func store() async -> PreviewStore {
        if let directory = environment.stateDirectory { return PreviewStore(directory: directory) }
        return PreviewStore(directory: await environment.history.directory)
    }
}
