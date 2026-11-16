import Foundation
import Testing
@testable import OustAgent
import OustClean
import OustCore
import OustRules
import OustSafety

@Suite("L'analyse des agents est à blanc et dit tout")
struct AgentScanTests {

    @Test("Un artefact de projet, avec sa classe, sa méthode et son coût de reconstruction")
    func reportsArtifact() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")

        let report = await bench.service.scan(finders: [.projectArtifacts])

        let item = try #require(report.items.first)
        #expect(report.items.count == 1)
        #expect(item.rule == "artifact.node_modules")
        #expect(item.safety == "rebuilds")
        #expect(item.method.kind == "removeNow")
        #expect(item.method.family == "immediate")
        #expect(item.method.requiresAdministrator == false)
        #expect(item.rebuild.kind == "command" && item.rebuild.command == "pnpm install")
        #expect(item.agent.verdict == "allowed")
        #expect(item.sizes.freeableBytes > 0)
        #expect(item.paths == [bench.projects.appendingPathComponent("web/node_modules").path])
        // Une analyse ne touche à rien, mais garde un aperçu.
        #expect(bench.exists("maison/Developpement/web/node_modules/react/index.js"))
        #expect(report.token?.count == 32)
        #expect(FileManager.default.fileExists(atPath: bench.stateFolder.appendingPathComponent("agent-previews.json").path))
        #expect(await bench.history().isEmpty)
    }

    @Test("--path ne garde que ce qui est dedans")
    func pathScope() async throws {
        let bench = try AgentBench()
        let web = try bench.nodeProject("web")
        try bench.nodeProject("api")

        let all = await bench.service.scan(finders: [.projectArtifacts])
        let scoped = await bench.service.scan(finders: [.projectArtifacts], paths: [web])

        #expect(all.items.count == 2)
        #expect(scoped.items.map(\.owner) == ["web"])
        #expect(scoped.scope.paths == [web.path])
    }

    @Test("Un dossier hors des dossiers de projets réglés est parcouru quand on le nomme")
    func pathOutsideProjectRoots() async throws {
        let bench = try AgentBench()
        let elsewhere = try bench.nodeProject("outil", under: "maison/ailleurs")

        let plain = await bench.service.scan(finders: [.projectArtifacts])
        let named = await bench.service.scan(finders: [.projectArtifacts],
                                              paths: [elsewhere.deletingLastPathComponent()])

        #expect(plain.items.isEmpty)
        #expect(named.items.map(\.title) == ["node_modules"])
    }

    @Test("Hors des dossiers réglés, ce qui travaille dans le dépôt protège tout le dépôt")
    func repositoryIsTheProject() async throws {
        let bench = try AgentBench()
        // Le dépôt monorepo/ ; l'artefact vit loin de sa racine.
        try bench.text("maison/ailleurs/monorepo/.git/HEAD", "ref: refs/heads/main")
        try bench.nodeProject("mobile", under: "maison/ailleurs/monorepo/apps")
        let repository = bench.home.appendingPathComponent("ailleurs/monorepo")
        bench.processes.withLock {
            $0 = [ActiveProcess(pid: 4242, name: "adb", workingDirectory: repository.path)]
        }

        let report = await bench.service.scan(finders: [.projectArtifacts], paths: [repository])

        let item = try #require(report.items.first)
        #expect(item.safety == "protected")
        #expect(item.agent.verdict == "refused" && item.agent.reason == "protected")
        #expect(item.protections.map(\.kind) == ["activeProcess"])
    }

    @Test("limit garde les plus gros et le dit")
    func limit() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("petit")
        try bench.nodeProject("gros")
        try bench.file("maison/Developpement/gros/node_modules/lourd.bin", bytes: 400_000)

        let report = await bench.service.scan(finders: [.projectArtifacts], limit: 1)

        #expect(report.items.map(\.owner) == ["gros"])
        #expect(report.truncated)
        #expect(report.totals.items == 2 && report.totals.shown == 1)
    }

    @Test("Un processus dans le projet le protège ; celui qui demande, non")
    func requesterDoesNotProtect() async throws {
        let bench = try AgentBench()
        let web = try bench.nodeProject("web")
        bench.processes.withLock {
            $0 = [ActiveProcess(pid: 4242, name: "claude", workingDirectory: web.path, executablePath: "/opt/claude")]
        }

        let busy = await bench.service.scan(finders: [.projectArtifacts])
        #expect(busy.items.first?.agent.verdict == "refused")
        #expect(busy.items.first?.protections.first?.argument == "claude")

        // Le même processus, quand c'est lui qui appelle oust.
        bench.requester.withLock { $0 = [4242] }
        let asked = await bench.service.scan(finders: [.projectArtifacts])
        #expect(asked.items.first?.agent.verdict == "allowed")
    }

    @Test("Un gros fichier ancien des Téléchargements est « à examiner »")
    func reviewItem() async throws {
        let bench = try AgentBench()
        try bench.file("maison/Downloads/film.mov", bytes: 200_000, modified: Date().addingTimeInterval(-60 * 86_400))

        let report = await bench.service.scan(finders: [.userContent])

        let item = try #require(report.items.first)
        #expect(item.safety == "review")
        #expect(item.method.kind == "trash" && item.method.freesImmediately == false)
        #expect(item.agent.verdict == "needsAllowReview")
        #expect(item.preselected == false)
        #expect(report.totals.allowedBytes == 0 && report.totals.needsAllowReviewBytes > 0)
    }

    @Test("Un chemin qui n'existe pas, un chercheur inconnu : erreurs d'usage")
    func badArguments() throws {
        let bench = try AgentBench()
        #expect(throws: AgentError.pathNotFound("nulle-part")) { try bench.service.paths(["nulle-part"]) }
        #expect(throws: AgentError.unknownFinder("bidule")) { try bench.service.finders(named: ["agents,bidule"]) }
        // Tous, sauf ceux qui ne cherchent que sur un autre disque choisi dans l'app.
        #expect(try bench.service.finders(named: []) == FinderKind.homeCases)
        #expect(FinderKind.homeCases.count == FinderKind.allCases.count - FinderKind.volumeOnly.count)
        #expect(try bench.service.finders(named: ["agents,xcode", "agents"]) == [.agents, .xcode])
        #expect(try bench.service.paths(["maison"]) == [bench.home])
        #expect(try bench.service.paths(["~"]) == [bench.home])
    }
}

@Suite("Le nettoyage des agents passe par OustClean, et seulement après un aperçu")
struct AgentCleanTests {

    @Test("Le régénérable part, le reste du projet reste, le journal le retient")
    func removesAndJournals() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        let scan = await bench.service.scan(finders: [.projectArtifacts])
        let item = try #require(scan.items.first)

        let report = try await bench.service.clean(ids: [item.id], token: scan.token)

        #expect(report.outcomes.map(\.result) == ["removed"])
        #expect(report.totals.freedNowBytes == item.sizes.freeableBytes)
        #expect(!bench.exists("maison/Developpement/web/node_modules"))
        #expect(bench.exists("maison/Developpement/web/src/main.js"))
        #expect(bench.exists("maison/Developpement/web/package.json"))
        let history = await bench.history()
        #expect(history.map(\.itemID) == [item.id])
        #expect(history.first?.result == .removed)
    }

    @Test("À blanc, rien n'est touché ni journalisé")
    func dryRun() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        let scan = await bench.service.scan(finders: [.projectArtifacts])
        let id = try #require(scan.items.first?.id)

        let report = try await bench.service.clean(ids: [id], token: scan.token, dryRun: true)

        #expect(report.dryRun)
        #expect(report.outcomes.map(\.result) == ["wouldClean"])
        #expect(report.totals.freedNowBytes > 0)
        #expect(bench.exists("maison/Developpement/web/node_modules/react/index.js"))
        #expect(await bench.history().isEmpty)
    }

    @Test("Une Corbeille indisponible fait refuser un lot mixte avant toute suppression")
    func unavailableTrashRefusesMixedBatch() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        try bench.file("maison/Downloads/film.mov", bytes: 200_000, modified: Date().addingTimeInterval(-60 * 86_400))
        var environment = bench.environment()
        environment.trasher = FinderTrasher()
        let service = AgentService(environment: environment)
        let scan = await service.scan(finders: [.projectArtifacts, .userContent])
        let removal = try #require(scan.items.first { $0.method.kind == "removeNow" })
        let trash = try #require(scan.items.first { $0.method.kind == "trash" })
        #expect(removal.agent.verdict == "allowed")
        #expect(trash.agent.verdict == "refused")
        #expect(scan.totals.needsAllowReviewBytes == 0)
        for dryRun in [true, false] {
            do {
                _ = try await service.clean(ids: [removal.id, trash.id], token: scan.token,
                                            allowReview: true, dryRun: dryRun)
                Issue.record("Le lot mixte aurait dû être refusé")
            } catch let error as AgentError {
                guard case .refused(let refusals) = error else { Issue.record("\(error)"); continue }
                #expect(refusals.map(\.id) == [trash.id])
                #expect(refusals.map(\.reason) == ["unavailable"])
            }
        }
        #expect(bench.exists("maison/Developpement/web/node_modules/react/index.js"))
        #expect(bench.exists("maison/Downloads/film.mov"))
        #expect(await bench.history().isEmpty)
    }

    @Test("« À examiner » exige allowReview, et part alors dans la corbeille")
    func reviewNeedsFlag() async throws {
        let bench = try AgentBench()
        try bench.file("maison/Downloads/film.mov", bytes: 200_000, modified: Date().addingTimeInterval(-60 * 86_400))
        let scan = await bench.service.scan(finders: [.userContent])
        let id = try #require(scan.items.first?.id)

        await #expect(throws: AgentError.self) { try await bench.service.clean(ids: [id], token: scan.token) }
        #expect(bench.exists("maison/Downloads/film.mov"))

        let report = try await bench.service.clean(ids: [id], token: scan.token, allowReview: true)

        #expect(report.outcomes.map(\.result) == ["trashed"])
        #expect(report.totals.pendingInTrashBytes > 0 && report.totals.freedNowBytes == 0)
        #expect(!bench.exists("maison/Downloads/film.mov"))
        // La corbeille du test, jamais celle du Mac.
        let landed = try #require(report.outcomes.first?.trashedTo.first)
        #expect(landed.hasPrefix(bench.trash.path))
        #expect(await bench.history().first?.trashedTo == [landed])
    }

    @Test("Jamais un élément protégé, même nommé ; et rien du lot ne part")
    func protectedRefusesEverything() async throws {
        let bench = try AgentBench()
        let busy = try bench.nodeProject("busy")
        try bench.nodeProject("libre")
        bench.processes.withLock { $0 = [ActiveProcess(pid: 4242, name: "node", workingDirectory: busy.path)] }
        let scan = await bench.service.scan(finders: [.projectArtifacts])
        let ids = scan.items.map(\.id)
        #expect(ids.count == 2)

        do {
            _ = try await bench.service.clean(ids: ids, token: scan.token)
            Issue.record("le nettoyage aurait dû être refusé")
        } catch let error as AgentError {
            guard case .refused(let refusals) = error else { Issue.record("\(error)"); return }
            #expect(refusals.map(\.reason) == ["protected"])
            #expect(error.exitCode == .refused)
        }
        #expect(bench.exists("maison/Developpement/busy/node_modules"))
        #expect(bench.exists("maison/Developpement/libre/node_modules"))
        #expect(await bench.history().isEmpty)
    }

    @Test("Devenu protégé depuis l'aperçu : refusé")
    func protectedSincePreview() async throws {
        let bench = try AgentBench()
        let web = try bench.nodeProject("web")
        let scan = await bench.service.scan(finders: [.projectArtifacts])
        let id = try #require(scan.items.first?.id)
        bench.processes.withLock { $0 = [ActiveProcess(pid: 4242, name: "vite", workingDirectory: web.path)] }

        await #expect(throws: AgentError.self) { try await bench.service.clean(ids: [id], token: scan.token) }
        #expect(bench.exists("maison/Developpement/web/node_modules"))
    }

    @Test("Sans aperçu, avec un jeton inconnu ou périmé : rien")
    func previewIsRequired() async throws {
        let bench = try AgentBench()
        let web = try bench.nodeProject("web")
        let id = "artifact.node_modules|" + web.appendingPathComponent("node_modules").path

        await #expect(throws: AgentError.previewRequired) { try await bench.service.clean(ids: [id], token: nil) }
        let scan = await bench.service.scan(finders: [.projectArtifacts])
        #expect(scan.items.first?.id == id)
        await #expect(throws: AgentError.tokenExpired) { try await bench.service.clean(ids: [id], token: "0123") }
        await #expect(throws: AgentError.unknownItems(["cache.npm|ailleurs"])) {
            try await bench.service.clean(ids: ["cache.npm|ailleurs"], token: scan.token)
        }

        // Trente et une minutes plus tard, le jeton ne vaut plus rien.
        bench.clock.withLock { $0 = $0.addingTimeInterval(31 * 60) }
        await #expect(throws: AgentError.tokenExpired) { try await bench.service.clean(ids: [id], token: scan.token) }
        await #expect(throws: AgentError.previewRequired) { try await bench.service.clean(ids: [id], token: nil) }
        #expect(bench.exists("maison/Developpement/web/node_modules"))
    }

    @Test("Le jeton ne couvre que ce qui a été montré")
    func tokenCoversShownOnly() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("petit")
        try bench.nodeProject("gros")
        try bench.file("maison/Developpement/gros/node_modules/lourd.bin", bytes: 400_000)
        let all = await bench.service.scan(finders: [.projectArtifacts])
        let hidden = try #require(all.items.last?.id)

        let truncated = await bench.service.scan(finders: [.projectArtifacts], limit: 1)

        await #expect(throws: AgentError.unknownItems([hidden])) {
            try await bench.service.clean(ids: [hidden], token: truncated.token)
        }
    }

    @Test("Changé depuis l'aperçu (classe, méthode ou chemins) : il faut analyser de nouveau")
    func changedSincePreview() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        let scan = await bench.service.scan(finders: [.projectArtifacts])
        let id = try #require(scan.items.first?.id)
        // Le sceau de l'aperçu ne correspond plus à ce que les chercheurs trouvent.
        let file = bench.stateFolder.appendingPathComponent("agent-previews.json")
        var previews = try JSONDecoder.agent().decode([Preview].self, from: Data(contentsOf: file))
        previews[0].seals[id] = "autre chose"
        try JSONEncoder.agent().encode(previews).write(to: file)

        await #expect(throws: AgentError.changedSincePreview([id])) {
            try await bench.service.clean(ids: [id], token: scan.token)
        }
        #expect(bench.exists("maison/Developpement/web/node_modules"))
    }

    @Test("Disparu depuis l'aperçu : noté, sans erreur pour le reste")
    func vanishedIsSkipped() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        try bench.nodeProject("api")
        let scan = await bench.service.scan(finders: [.projectArtifacts])
        let ids = scan.items.map(\.id)
        try FileManager.default.removeItem(at: bench.projects.appendingPathComponent("api/node_modules"))

        let report = try await bench.service.clean(ids: ids, token: scan.token)

        #expect(Set(report.outcomes.map(\.result)) == ["removed", "skipped"])
        #expect(report.outcomes.first { $0.result == "skipped" }?.reason == "vanished")
        #expect(report.totals.succeeded == 1 && report.totals.skipped == 1)
    }

    @Test("Un journal impossible à écrire : on ne nettoie pas sans trace")
    func journalMustBeWritable() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        let scan = await bench.service.scan(finders: [.projectArtifacts])
        let id = try #require(scan.items.first?.id)
        try FileManager.default.createDirectory(at: bench.historyFolder, withIntermediateDirectories: true)
        chmod(bench.historyFolder.path, 0o500)

        do {
            _ = try await bench.service.clean(ids: [id], token: scan.token)
            Issue.record("le nettoyage aurait dû être refusé")
        } catch let error as AgentError {
            #expect(error.code == "journalUnavailable")
            #expect(error.exitCode == .failure)
        }
        #expect(bench.exists("maison/Developpement/web/node_modules"))
    }
}

@Suite("Explication")
struct AgentExplainTests {

    @Test("Un élément montré s'explique en entier ; une règle, par sa règle")
    func explain() async throws {
        let bench = try AgentBench()
        try bench.nodeProject("web")
        let scan = await bench.service.scan(finders: [.projectArtifacts])
        let id = try #require(scan.items.first?.id)

        let full = try await bench.service.explain(id)
        #expect(full.rule == "artifact.node_modules")
        #expect(full.item?.id == id)
        #expect(full.method != nil)
        #expect(!full.what.isEmpty && !full.back.isEmpty)

        let rule = try await bench.service.explain("cache.npm")
        #expect(rule.rule == "cache.npm" && rule.item == nil && rule.method == nil)

        await #expect(throws: AgentError.unknownItems(["rien.du.tout"])) { try await bench.service.explain("rien.du.tout") }
    }
}

@Suite("Politique des agents")
struct AgentPolicyTests {

    func item(_ safety: SafetyClass, method: CleanupMethod = .removeNow,
              protections: [ProtectionReason] = []) -> CleanupItem {
        CleanupItem(title: "x", paths: [URL(fileURLWithPath: "/nulle/part")], category: .projectArtifacts,
                    owner: "x", ruleID: "artifact.node_modules", safety: safety, protections: protections,
                    method: method, rebuild: .automatic)
    }

    @Test("Sûr et reconstruit : oui ; à examiner : avec le drapeau ; le reste : jamais")
    func classes() {
        #expect(AgentPolicy.verdict(for: item(.safe)) == .allowed)
        #expect(AgentPolicy.verdict(for: item(.rebuilds)) == .allowed)
        #expect(AgentPolicy.verdict(for: item(.review)) == .needsReviewFlag)
        #expect(AgentPolicy.verdict(for: item(.protected)) == .refused(.protected))
        #expect(AgentPolicy.verdict(for: item(.inaccessible)) == .refused(.inaccessible))
        #expect(AgentPolicy.verdict(for: item(.safe, protections: [.inUse])) == .refused(.protected))
        #expect(AgentPolicy.allows(item(.review), allowReview: true))
        #expect(!AgentPolicy.allows(item(.review), allowReview: false))
        #expect(!AgentPolicy.allows(item(.protected), allowReview: true))
    }

    @Test("Jamais de mot de passe administrateur, jamais de « à faire soi-même »")
    func methods() {
        #expect(AgentPolicy.verdict(for: item(.safe, method: .localSnapshot(date: "2026-10-18-120000")))
                == .refused(.administrator))
        #expect(AgentPolicy.verdict(for: item(.review, method: .manual)) == .refused(.manualOnly))
        #expect(AgentPolicy.verdict(for: item(.review, method: .archive(copy: "/Volumes/x"))) == .refused(.notForAgents))
        #expect(AgentPolicy.verdict(for: item(.review, method: .photoAsset(localIdentifier: "ABC/L0/001")))
                == .refused(.notForAgents))
        #expect(MethodReport(.localSnapshot(date: "d")).requiresAdministrator)
        #expect(AgentPolicy.verdict(for: item(.rebuilds, method: .gitWorktreeRemove(repository: "/r"))) == .refused(.unavailable))
    }

    @Test("La lignée du processus, et ce qu'elle ne protège pas")
    func requester() {
        let lineage = Requester.lineage()
        #expect(lineage.contains(getpid()) && lineage.contains(getppid()))
        let snapshot = ProcessSnapshot(processes: [
            ActiveProcess(pid: 1, name: "moi", workingDirectory: "/projet", executablePath: "/projet/bin/moi"),
            ActiveProcess(pid: 2, name: "autre", workingDirectory: "/projet"),
        ])
        let seen = Requester.snapshot(snapshot, excluding: [1])
        #expect(seen.busy(under: "/projet")?.name == "autre")
        #expect(seen.running(inside: "/projet/bin")?.name == "moi")
        #expect(Requester.snapshot(snapshot, excluding: [1, 2]).busy(under: "/projet") == nil)
    }
}
