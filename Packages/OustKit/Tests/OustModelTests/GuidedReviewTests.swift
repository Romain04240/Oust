import Foundation
import OustCore
import OustScan
import Testing
@testable import OustModel

@Suite("Parcours guidé de consultation") @MainActor
struct GuidedReviewTests {
    @MainActor private struct Fixture {
        let root: URL
        let file: URL
        let boot: VolumeDescriptor
        let external: VolumeDescriptor
        let model: AppModel
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let contents = Data(repeating: 73, count: 4096)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-guided-review-\(UUID())")
                .resolvingSymlinksInPath()
            let home = root.appendingPathComponent("boot"), other = root.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            file = home.appendingPathComponent("fixture.bin")
            try Data(repeating: 73, count: 4096).write(to: file)
            let capacity = Capacity(total: 1_000_000, available: 400_000, availableForImportantUsage: 500_000)
            var local = VolumeDescriptor(name: "Local", mountURL: home, scanRoot: home, isBoot: true,
                isInternal: true, isRemovable: false, capacity: capacity)
            local.mountIdentity = VolumeMountIdentity(device: 7, inode: 101, createdSeconds: 1, createdNanoseconds: 0)
            boot = local
            external = VolumeDescriptor(name: "External", mountURL: other, scanRoot: other, isBoot: false,
                isInternal: false, isRemovable: true, capacity: capacity)
            model = AppModel(home: home, defaults: GuidedReviewDefaults(),
                disk: DiskIndexModel(store: TreeStore(directory: root.appendingPathComponent("Index"))))
            model.volumes = [boot, external]
            model.volumeAnalysisDates[boot.id] = date
        }

        var chosen: CleanupItem {
            CleanupItem(id: "guided.fixture.chosen", title: "Fixture", paths: [file], category: .toolVersions,
                owner: "Fixture", ruleID: "tool.brew_cleanup", safety: .safe,
                method: .brewCleanup(executable: boot.scanRoot.appendingPathComponent("bin/brew").path),
                sizes: .zero, rebuild: .nothing)
        }

        func selectChosen() {
            model.items[chosen.id] = chosen
            model.toggle(chosen)
        }

        func start() throws -> GuidedReviewSession {
            model.startGuidedReview()
            return try #require(model.guidedReview)
        }

        func offer(_ step: AppSection) throws -> GuidedReviewSession {
            _ = try start()
            let index = try #require(GuidedReviewSession.steps.firstIndex(of: step))
            for _ in 0..<index {
                let current = try #require(model.guidedReview)
                model.skipGuidedReview(token: current.token)
            }
            return try #require(model.guidedReview)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("L'ordre est explicite et une collecte terminée suffit sans parcours de fichiers")
    func exactOrderAndAdmission() throws {
        let f = try Fixture(); defer { f.remove() }
        #expect(GuidedReviewSession.steps == [.applications, .browsers, .system, .timeMachine, .explorer,
            .largeFiles, .duplicates, .photos, .clouds, .developer, .archive, .cart])
        #expect(f.model.analysis == .idle && f.model.canStartGuidedReview)
        let session = try f.start()
        #expect(session.index == 0 && session.completedCount == 0 && session.step == .applications)
        #expect(session.stage == .offering && f.model.section == .overview)
        #expect(!f.model.canStartGuidedReview && f.model.cart.isEmpty && f.model.items.isEmpty)
        #expect(f.model.disk.currentTree == nil && !f.model.disk.isRefreshing)
        #expect(f.model.overviewAnalysisTask == nil && f.model.bootAnalysisRequest == nil)
        #expect(f.model.cleaning == .idle && f.model.explorer == .idle)
        f.model.startGuidedReview()
        #expect(f.model.guidedReview == session)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }

    @Test("Le démarrage exige une consultation locale disponible",
          arguments: ["analysis", "missingDate", "search", "section", "external", "missingBoot", "removable", "nonInternal"])
    func admissionConditions(_ blockedBy: String) throws {
        let f = try Fixture(); defer { f.remove() }
        switch blockedBy {
        case "analysis": f.model.analysis = .running
        case "missingDate": f.model.volumeAnalysisDates.removeValue(forKey: f.boot.id)
        case "search": f.model.searchText = "fixture"
        case "section": f.model.section = .applications
        case "external": f.model.analysisVolumeID = f.external.id
        case "missingBoot": f.model.volumes = [f.external]
        case "removable":
            var changed = f.boot; changed.isRemovable = true
            f.model.volumes = [changed, f.external]
        default:
            var changed = f.boot; changed.isInternal = false
            f.model.volumes = [changed, f.external]
        }
        let section = f.model.section
        #expect(!f.model.canStartGuidedReview)
        f.model.startGuidedReview()
        #expect(f.model.guidedReview == nil && f.model.section == section)
        #expect(f.model.items.isEmpty && f.model.cart.isEmpty && f.model.cleaning == .idle)
    }

    @Test("Passer n'ouvre aucune section et le dernier panier conserve son veto et ses choix sans gain")
    func skipWithoutOpeningAndFinishCart() throws {
        let f = try Fixture(); defer { f.remove() }
        f.selectChosen()
        let forbidden = CleanupItem(id: "guided.fixture.forbidden", title: "Fixture interdite", paths: [f.file],
            category: .toolVersions, owner: "Fixture", ruleID: "fixture.forbidden", safety: .safe,
            method: .trash, sizes: .zero, rebuild: .nothing)
        f.model.items[forbidden.id] = forbidden
        f.model.toggle(forbidden)
        let items = f.model.items, cart = f.model.cart
        #expect(cart == [f.chosen.id] && !f.model.canSelectForCleanup(forbidden))
        var session = try f.start()
        for index in 0..<(GuidedReviewSession.steps.count - 1) {
            #expect(session.index == index && session.completedCount == index)
            let previous = session
            f.model.skipGuidedReview(token: previous.token)
            session = try #require(f.model.guidedReview)
            #expect(session.id == previous.id && session.token != previous.token)
            #expect(session.stage == .offering && session.index == index + 1 && f.model.section == .overview)
            #expect(f.model.items == items && f.model.cart == cart && f.model.cleaning == .idle)
        }
        #expect(session.step == .cart)
        f.model.skipGuidedReview(token: session.token)
        f.model.completeGuidedReviewStep(token: session.token)
        #expect(f.model.guidedReview == session && f.model.section == .overview)
        f.model.examineGuidedReview(token: session.token)
        let examining = try #require(f.model.guidedReview)
        #expect(examining.stage == .examining && f.model.section == .cart)
        #expect(examining.token != session.token)
        f.model.completeGuidedReviewStep(token: examining.token)
        #expect(f.model.guidedReview == nil && f.model.section == .cart)
        #expect(f.model.cart == cart && f.model.cartItems.map(\.id) == [f.chosen.id] && f.model.cartTotal == 0)
        #expect(f.model.items == items && f.model.cleaning == .idle && !f.model.canMoveFiles)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }

    @Test("Examiner puis revenir avance dans l'ordre sans choisir ni modifier de fichier")
    func examineEveryStep() throws {
        let f = try Fixture(); defer { f.remove() }
        f.model.items[f.chosen.id] = f.chosen
        let items = f.model.items
        _ = try f.start()
        for (index, step) in GuidedReviewSession.steps.enumerated() {
            let offered = try #require(f.model.guidedReview)
            #expect(offered.index == index && offered.step == step && offered.stage == .offering)
            f.model.examineGuidedReview(token: offered.token)
            let examining = try #require(f.model.guidedReview)
            #expect(examining.stage == .examining && examining.token != offered.token)
            #expect(examining.id == offered.id && f.model.section == step)
            #expect(f.model.cart.isEmpty && f.model.items == items && f.model.cleaning == .idle)
            f.model.completeGuidedReviewStep(token: examining.token)
            if step != .cart {
                let next = try #require(f.model.guidedReview)
                #expect(next.index == index + 1 && next.stage == .offering && next.token != examining.token)
                #expect(f.model.section == .overview)
            }
        }
        #expect(f.model.guidedReview == nil && f.model.section == .cart && f.model.cart.isEmpty)
        #expect(f.model.disk.currentTree == nil && !f.model.disk.isRefreshing)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }

    @Test("La pause garde la page et la reprise respecte les changements manuels du panier")
    func pauseAndResumePreserveLiveChoices() throws {
        let f = try Fixture(); defer { f.remove() }
        f.selectChosen()
        let offered = try f.start()
        f.model.examineGuidedReview(token: offered.token)
        let examining = try #require(f.model.guidedReview)
        f.model.pauseGuidedReview(token: examining.token)
        let paused = try #require(f.model.guidedReview)
        #expect(paused.stage == .paused && paused.index == examining.index && paused.token != examining.token)
        #expect(f.model.section == .applications && f.model.cart == [f.chosen.id])
        f.model.toggle(f.chosen)
        f.model.pauseGuidedReview(token: paused.token)
        f.model.examineGuidedReview(token: paused.token)
        f.model.skipGuidedReview(token: paused.token)
        f.model.completeGuidedReviewStep(token: paused.token)
        #expect(f.model.guidedReview == paused)
        f.model.resumeGuidedReview(token: paused.token)
        let resumed = try #require(f.model.guidedReview)
        #expect(resumed.id == paused.id && resumed.index == paused.index && resumed.stage == .offering)
        #expect(resumed.token != paused.token && f.model.section == .overview && f.model.cart.isEmpty)
        #expect(f.model.items[f.chosen.id] == f.chosen && f.model.cleaning == .idle)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }

    @Test("La navigation libre ou une recherche met en pause sans avancer",
          arguments: ["offer.navigation", "offer.search", "examine.navigation", "examine.search"])
    func manualNavigationPauses(_ action: String) throws {
        let f = try Fixture(); defer { f.remove() }
        let offered = try f.start()
        if action.hasPrefix("examine") { f.model.examineGuidedReview(token: offered.token) }
        let current = try #require(f.model.guidedReview)
        if action.hasSuffix("navigation") { f.model.section = .history } else { f.model.searchText = "fixture" }
        let paused = try #require(f.model.guidedReview)
        #expect(paused.stage == .paused && paused.index == 0 && paused.token != current.token)
        let section = f.model.section
        f.model.examineGuidedReview(token: offered.token)
        f.model.skipGuidedReview(token: offered.token)
        #expect(f.model.guidedReview == paused && f.model.section == section)
        f.model.resumeGuidedReview(token: paused.token)
        let resumed = try #require(f.model.guidedReview)
        #expect(resumed.stage == .offering && resumed.index == 0 && resumed.token != paused.token)
        #expect(f.model.section == .overview && f.model.searchText.isEmpty)
    }

    @Test("Un double clic ou une autre fenêtre ne réutilise pas un ancien jeton")
    func staleWindowTokens() throws {
        let f = try Fixture(); defer { f.remove() }
        let firstWindow = try f.start(), secondWindow = firstWindow
        f.model.examineGuidedReview(token: firstWindow.token)
        let examining = try #require(f.model.guidedReview)
        f.model.examineGuidedReview(token: secondWindow.token)
        f.model.skipGuidedReview(token: secondWindow.token)
        f.model.completeGuidedReviewStep(token: secondWindow.token)
        f.model.pauseGuidedReview(token: secondWindow.token)
        f.model.endGuidedReview(token: secondWindow.token)
        #expect(f.model.guidedReview == examining && f.model.section == .applications)
        f.model.completeGuidedReviewStep(token: examining.token)
        let next = try #require(f.model.guidedReview)
        f.model.completeGuidedReviewStep(token: examining.token)
        #expect(f.model.guidedReview == next && next.index == 1 && next.id == firstWindow.id)
        f.model.skipGuidedReview(token: next.token)
        let skipped = try #require(f.model.guidedReview)
        f.model.skipGuidedReview(token: next.token)
        #expect(f.model.guidedReview == skipped && skipped.index == 2 && f.model.section == .overview)
    }

    @Test("Le disque ou la source d'analyse remplacés invalident le parcours",
          arguments: ["external", "missingBoot", "root", "identity", "date", "missingDate", "analysis"])
    func sourceInvalidation(_ change: String) throws {
        let f = try Fixture(); defer { f.remove() }
        f.selectChosen()
        let session = try f.start()
        switch change {
        case "external": f.model.analysisVolumeID = f.external.id
        case "missingBoot": f.model.volumes = [f.external]
        case "root":
            var replacement = f.boot; replacement.scanRoot = f.external.scanRoot
            f.model.volumes = [replacement, f.external]
        case "identity":
            var replacement = f.boot
            replacement.mountIdentity = VolumeMountIdentity(device: 7, inode: 202, createdSeconds: 2, createdNanoseconds: 0)
            f.model.volumes = [replacement, f.external]
        case "date": f.model.volumeAnalysisDates[f.boot.id] = f.date.addingTimeInterval(1)
        case "missingDate": f.model.volumeAnalysisDates.removeValue(forKey: f.boot.id)
        default: f.model.analysis = .running
        }
        #expect(f.model.guidedReview == nil)
        f.model.examineGuidedReview(token: session.token)
        f.model.resumeGuidedReview(token: session.token)
        #expect(f.model.guidedReview == nil && f.model.section == .overview)
        #expect(f.model.cart == [f.chosen.id] && f.model.cleaning == .idle)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }

    @Test("Les commandes revérifient la source même sans notification préalable",
          arguments: ["examine", "skip", "complete", "pause", "resume"])
    func commandsRevalidateSource(_ command: String) throws {
        let f = try Fixture(); defer { f.remove() }
        let offered = try f.start()
        if command == "complete" { f.model.examineGuidedReview(token: offered.token) }
        if command == "resume" { f.model.pauseGuidedReview(token: offered.token) }
        let stale = try #require(f.model.guidedReview)
        f.model.volumeAnalysisDates[f.boot.id] = f.date.addingTimeInterval(1)
        // Simule une fenêtre gardant une ancienne valeur après la notification.
        f.model.guidedReview = stale
        switch command {
        case "examine": f.model.examineGuidedReview(token: stale.token)
        case "skip": f.model.skipGuidedReview(token: stale.token)
        case "complete": f.model.completeGuidedReviewStep(token: stale.token)
        case "pause": f.model.pauseGuidedReview(token: stale.token)
        default: f.model.resumeGuidedReview(token: stale.token)
        }
        #expect(f.model.guidedReview == nil && f.model.cart.isEmpty && f.model.cleaning == .idle)
    }

    @Test("Un changement sans rapport avec la source conserve l'étape courante")
    func unrelatedUpdatesKeepSession() throws {
        let f = try Fixture(); defer { f.remove() }
        let session = try f.start()
        var boot = f.boot; boot.capacity.available = 300_000
        f.model.volumes = [f.external, boot]
        f.model.volumeAnalysisDates[f.external.id] = f.date.addingTimeInterval(1)
        f.model.analysis = .done(f.date)
        #expect(f.model.guidedReview == session && f.model.section == .overview)
    }

    @Test("Un Explorateur étranger ne s'ouvre pas sous le nom du disque guidé",
          arguments: [AppSection.explorer, .largeFiles])
    func foreignExplorerPreventsExamining(_ step: AppSection) throws {
        let f = try Fixture(); defer { f.remove() }
        f.selectChosen()
        let session = try f.offer(step)
        var otherRoot = f.boot; otherRoot.scanRoot = f.external.scanRoot
        var otherIdentity = f.boot
        otherIdentity.mountIdentity = VolumeMountIdentity(device: 7, inode: 303, createdSeconds: 3, createdNanoseconds: 0)
        for displayed in [f.external, otherRoot, otherIdentity] {
            f.model.treeVolume = displayed
            #expect(f.model.guidedReviewNeedsStartupExplorer)
            f.model.examineGuidedReview(token: session.token)
            #expect(f.model.guidedReview == session && f.model.section == .overview)
            #expect(f.model.treeVolume == displayed && f.model.disk.currentTree == nil)
        }
        f.model.skipGuidedReview(token: session.token)
        let next = try #require(f.model.guidedReview)
        #expect(next.index == session.index + 1 && next.stage == .offering && next.token != session.token)
        #expect(f.model.section == .overview && f.model.cart == [f.chosen.id] && f.model.cleaning == .idle)
        #expect(!f.model.disk.isRefreshing && f.model.scanTask == nil)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }

    @Test("Le retour à l'Explorateur local ou vide permet d'examiner sans lancer de parcours",
          arguments: ["explorer.boot", "explorer.empty", "largeFiles.boot", "largeFiles.empty"])
    func startupExplorerAllowsExamining(_ state: String) throws {
        let f = try Fixture(); defer { f.remove() }
        let step: AppSection = state.hasPrefix("explorer") ? .explorer : .largeFiles
        f.model.treeVolume = f.external
        let offered = try f.offer(step)
        f.model.examineGuidedReview(token: offered.token)
        #expect(f.model.guidedReview == offered && f.model.guidedReviewNeedsStartupExplorer)
        f.model.treeVolume = state.hasSuffix("boot") ? f.boot : nil
        #expect(!f.model.guidedReviewNeedsStartupExplorer)
        let ready = try #require(f.model.guidedReview)
        f.model.examineGuidedReview(token: ready.token)
        let examining = try #require(f.model.guidedReview)
        #expect(examining.stage == .examining && examining.step == step && f.model.section == step)
        #expect(examining.token != ready.token && f.model.cart.isEmpty && f.model.cleaning == .idle)
        #expect(f.model.treeVolume == (state.hasSuffix("boot") ? f.boot : nil))
        #expect(f.model.disk.currentTree == nil && !f.model.disk.isRefreshing && f.model.scanTask == nil)
    }

    @Test("Changer l'Explorateur pendant l'examen met en pause et bloque l'ancienne validation",
          arguments: [AppSection.explorer, .largeFiles])
    func redirectedExplorerPauses(_ step: AppSection) throws {
        let f = try Fixture(); defer { f.remove() }
        f.selectChosen()
        let offered = try f.offer(step)
        f.model.examineGuidedReview(token: offered.token)
        let examining = try #require(f.model.guidedReview)
        f.model.treeVolume = f.external
        let paused = try #require(f.model.guidedReview)
        #expect(paused.stage == .paused && paused.index == examining.index && paused.token != examining.token)
        #expect(f.model.section == step && f.model.guidedReviewNeedsStartupExplorer)
        f.model.completeGuidedReviewStep(token: examining.token)
        #expect(f.model.guidedReview == paused)
        f.model.resumeGuidedReview(token: paused.token)
        let resumed = try #require(f.model.guidedReview)
        #expect(resumed.stage == .offering && resumed.index == examining.index && f.model.section == .overview)
        f.model.examineGuidedReview(token: resumed.token)
        #expect(f.model.guidedReview == resumed)
        f.model.skipGuidedReview(token: resumed.token)
        let next = try #require(f.model.guidedReview)
        #expect(next.index == resumed.index + 1 && next.stage == .offering)
        #expect(f.model.treeVolume == f.external && f.model.cart == [f.chosen.id] && f.model.cleaning == .idle)
        #expect(!f.model.disk.isRefreshing && f.model.scanTask == nil)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }

    @Test("Terminer revérifie aussi le disque affiché sans dépendre de sa notification",
          arguments: [AppSection.explorer, .largeFiles])
    func completionRevalidatesExplorer(_ step: AppSection) throws {
        let f = try Fixture(); defer { f.remove() }
        let offered = try f.offer(step)
        f.model.examineGuidedReview(token: offered.token)
        let examining = try #require(f.model.guidedReview)
        f.model.treeVolume = f.external
        // Simule une valeur conservée par une fenêtre avant sa mise en pause.
        f.model.guidedReview = examining
        f.model.completeGuidedReviewStep(token: examining.token)
        #expect(f.model.guidedReview?.index == examining.index && f.model.section == step)
        #expect(f.model.cart.isEmpty && f.model.cleaning == .idle && f.model.treeVolume == f.external)
    }

    @Test("Abandonner ne change pas les choix et un ancien abandon ne ferme pas une nouvelle session")
    func abandonAndRestart() throws {
        let f = try Fixture(); defer { f.remove() }
        f.selectChosen()
        let first = try f.start()
        f.model.endGuidedReview(token: first.token)
        #expect(f.model.guidedReview == nil && f.model.canStartGuidedReview)
        #expect(f.model.cart == [f.chosen.id] && f.model.section == .overview)
        let current = try f.start()
        #expect(current.id != first.id && current.token != first.token)
        f.model.endGuidedReview(token: first.token)
        #expect(f.model.guidedReview == current)
        f.model.examineGuidedReview(token: current.token)
        let examining = try #require(f.model.guidedReview)
        f.model.endGuidedReview(token: examining.token)
        #expect(f.model.guidedReview == nil && f.model.section == .applications)
        #expect(f.model.cartItems.map(\.id) == [f.chosen.id] && f.model.cleaning == .idle)
        #expect(try Data(contentsOf: f.file) == f.contents)
    }
}

private final class GuidedReviewDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey key: String) -> Any? { nil }
    override func data(forKey key: String) -> Data? { nil }
    override func stringArray(forKey key: String) -> [String]? { nil }
    override func bool(forKey key: String) -> Bool { false }
    override func set(_ value: Any?, forKey key: String) {}
}
