import Foundation
import OustCore
import Testing
@testable import OustModel

@Suite @MainActor
struct AnalysisReviewTests {
    @Test("La validation sur un disque externe mesure l’espace libre sans toucher aux fichiers ni au panier")
    func externalReview() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = try fixture.item("autre", in: fixture.other, method: .trash)
        let a = try fixture.item("installateur", in: fixture.volume, method: .trash)
        let b = try fixture.item("cache", in: fixture.volume, method: .removeNow)
        let c = try fixture.item("outil", in: fixture.volume, method: .simulatorDevice(udid: "fictif"))
        let model = fixture.model()
        model.cart.insert(other.id)
        var review = try fixture.review(using: model, items: [a, b, c, other])
        #expect(Set(review.rows.map(\.id)) == [a.id, b.id, c.id])
        review.toggleGroup(.projectArtifacts)
        #expect(review.selection == [a.id, b.id, c.id])
        review.toggleGroup(.projectArtifacts)
        #expect(review.selection.isEmpty)
        review.setSelected(a.id, true)
        review.setSelected(b.id, true)
        review.setSelected(c.id, true)
        guard case .confirmed(let reading) = await model.validateAnalysisReview(review) else {
            Issue.record("La sélection du disque doit être validable")
            return
        }
        #expect((reading.available ?? 0) > 0)
        #expect(AnalysisReview.estimatedGain == 0 && reading.reclaimed == 0)
        #expect(model.cart == [other.id])
        #expect(model.cleaning == .idle)
        #expect(!model.canMoveFiles)
        for item in [a, b, c, other] {
            let file = try #require(item.paths.first)
            #expect(try Data(contentsOf: file) == Data([1]))
        }
    }

    @Test("Une revue issue d’un point de montage remplacé ne valide rien")
    func replacedVolume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = try fixture.item("fichier", in: fixture.volume, method: .trash)
        let model = fixture.model()
        var review = try fixture.review(using: model, items: [item])
        review.setSelected(item.id, true)
        let root = fixture.volume.scanRoot
        try FileManager.default.moveItem(at: root, to: fixture.root.appendingPathComponent("ancien"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let replacement = try fixture.item("fichier", in: fixture.volume, method: .trash)
        guard case .unavailable = await model.validateAnalysisReview(review) else {
            Issue.record("Le nouveau dossier ne doit pas être accepté comme l’ancien disque")
            return
        }
        #expect(try Data(contentsOf: #require(replacement.paths.first)) == Data([1]))
    }

    @Test("Une ligne périmée ne revient ni par sa case ni par Tout cocher")
    func updatedReview() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try fixture.item("a", in: fixture.volume, method: .removeNow)
        let b = try fixture.item("b", in: fixture.volume, method: .trash)
        let model = fixture.model()
        var review = try fixture.review(using: model, items: [a, b])
        review.toggleGroup(.projectArtifacts)
        model.items.removeValue(forKey: b.id)
        let result = await model.validateAnalysisReview(review) {
            Issue.record("Une sélection déjà périmée ne doit pas attendre la mesure")
            return nil
        }
        guard case .changed(let ids) = result else {
            Issue.record("Le résultat retiré ne doit plus figurer dans le récapitulatif")
            return
        }
        #expect(ids == [a.id])
        review.keepCurrentRows(ids)
        #expect(review.rows == [a])
        #expect(review.selectedRows == [a])
        review.toggleGroup(.projectArtifacts)
        review.setSelected(b.id, true)
        #expect(review.selection.isEmpty)
        review.toggleGroup(.projectArtifacts)
        #expect(review.selection == [a.id])
        guard case .confirmed = await model.validateAnalysisReview(review) else {
            Issue.record("La catégorie corrigée doit se valider en un clic")
            return
        }
        model.analyzingVolumeID = fixture.volume.id
        model.forgetVolume(at: fixture.volume.mountURL)
        #expect(model.analyzingVolumeID == nil)
        #expect(model.analysisReview(for: fixture.volume) == nil)
    }

    @Test("Une fermeture pendant la mesure écarte son résultat tardif")
    func cancelledValidation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = try fixture.item("document", in: fixture.volume, method: .trash)
        let file = try #require(item.paths.first)
        let model = fixture.model()
        var review = try fixture.review(using: model, items: [item])
        review.setSelected(item.id, true)
        let request = review
        let gate = MeasurementGate()
        let validation = Task {
            await model.validateAnalysisReview(request) { await gate.read() }
        }
        await gate.waitForRead()
        validation.cancel()
        // Une mesure bloquée ne doit pas empêcher une nouvelle revue de fonctionner.
        guard case .confirmed(let reading) = await model.validateAnalysisReview(request) else {
            await gate.finish()
            Issue.record("La nouvelle revue doit être indépendante de la mesure annulée")
            return
        }
        #expect(reading.reclaimed == 0)
        await gate.finish()
        guard case .unavailable = await validation.value else {
            Issue.record("La mesure terminée après annulation doit être ignorée")
            return
        }
        #expect(model.cart.isEmpty)
        #expect(model.cleaning == .idle)
        #expect(!model.canMoveFiles)
        #expect(try Data(contentsOf: file) == Data([1]))
    }

    @Test("Un résultat retiré pendant la mesure est refusé à la validation")
    func removedDuringMeasurement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = try fixture.item("retiré", in: fixture.volume, method: .trash)
        let other = try fixture.item("encore là", in: fixture.volume, method: .manual)
        let model = fixture.model()
        var review = try fixture.review(using: model, items: [item, other])
        review.setSelected(item.id, true)
        let result = await model.validateAnalysisReview(review) {
            model.items.removeValue(forKey: item.id)
            return AnalysisReview.CapacityReading(available: 256)
        }
        guard case .changed(let ids) = result else {
            Issue.record("La fin de mesure doit revérifier les résultats encore présents")
            return
        }
        review.keepCurrentRows(ids)
        #expect(review.rows == [other])
        #expect(review.selection.isEmpty)
        review.toggleGroup(.projectArtifacts)
        #expect(review.selection == [other.id])
    }

    private actor MeasurementGate {
        private var continuation: CheckedContinuation<AnalysisReview.CapacityReading?, Never>?
        let started = AsyncStream<Void>.makeStream()

        func read() async -> AnalysisReview.CapacityReading? {
            await withCheckedContinuation {
                continuation = $0
                started.continuation.yield(())
                started.continuation.finish()
            }
        }

        func waitForRead() async {
            for await _ in started.stream { return }
        }

        func finish() {
            continuation?.resume(returning: AnalysisReview.CapacityReading(available: 256))
            continuation = nil
        }
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-analysis-review-\(UUID())")
        let volume: VolumeDescriptor
        let other: VolumeDescriptor

        init() throws {
            let first = root.appendingPathComponent("premier")
            let second = root.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            volume = Self.descriptor(first)
            other = Self.descriptor(second)
        }

        func item(_ name: String, in volume: VolumeDescriptor, method: CleanupMethod) throws -> CleanupItem {
            let path = volume.scanRoot.appendingPathComponent(name)
            try Data([1]).write(to: path)
            return CleanupItem(title: name, paths: [path], category: .projectArtifacts, owner: "", ruleID: "fixture.review",
                               safety: .safe, method: method, sizes: Sizes(private: 4096), rebuild: .automatic)
        }

        @MainActor func model() -> AppModel {
            let model = AppModel(home: root)
            model.volumes = [volume, other]
            return model
        }

        @MainActor func review(using model: AppModel, items: [CleanupItem]) throws -> AnalysisReview {
            model.analyzingVolumeID = volume.id
            for item in items { model.items[item.id] = item }
            model.saveAnalysisReview(for: volume, location: AnalysisReview.Location(volume.scanRoot), ids: Set(items.map(\.id)))
            model.analyzingVolumeID = nil
            model.volumeAnalysisDates[volume.id] = Date()
            return try #require(model.analysisReview(for: volume))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private static func descriptor(_ folder: URL) -> VolumeDescriptor {
            VolumeDescriptor(name: folder.lastPathComponent, mountURL: folder, scanRoot: folder, isBoot: false,
                             isInternal: false, isRemovable: true,
                             capacity: Capacity(total: 50, available: 25, availableForImportantUsage: 25))
        }
    }
}
