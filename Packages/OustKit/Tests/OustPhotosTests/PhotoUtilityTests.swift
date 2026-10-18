import Foundation
import Testing
import OustCore
@testable import OustPhotos

@Suite("Les photos utiles : codes, documents, écrans, jamais les visages")
struct PhotoUtilityTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Les signaux mesurés sur des images types donnent la bonne famille")
    func classifier() {
        // Valeurs relevées le 18/10/2026 sur des vignettes de 1 024 points.
        #expect(UtilityClassifier.kind(of: PhotoSignals(labels: ["document": 0.49, "printed_page": 0.48])) == .document)
        #expect(UtilityClassifier.kind(of: PhotoSignals(labels: ["document": 0.32], documentOutline: 0.99,
                                                        textCharacters: 87)) == .document)
        #expect(UtilityClassifier.kind(of: PhotoSignals(barcodes: 1, labels: ["document": 0.07])) == .barcode)
        #expect(UtilityClassifier.kind(of: PhotoSignals(labels: ["outdoor": 0.82, "sky": 0.75])) == nil)
        #expect(UtilityClassifier.kind(of: PhotoSignals(labels: ["receipt": 0.6])) == .receipt)
        #expect(UtilityClassifier.kind(of: PhotoSignals(labels: ["credit_card": 0.7])) == .card)
        #expect(UtilityClassifier.kind(of: PhotoSignals(labels: ["computer_monitor": 0.8])) == .screen)
        #expect(UtilityClassifier.kind(of: PhotoSignals(textCharacters: 130)) == .text)
        // Un contour de feuille seul ne suffit pas : un tableau, une fenêtre en ont un.
        #expect(UtilityClassifier.kind(of: PhotoSignals(documentOutline: 0.95)) == nil)
    }

    @Test("Un visage, ou des gens, et la photo n'est jamais proposée")
    func people() {
        #expect(UtilityClassifier.kind(of: PhotoSignals(faces: 1, barcodes: 1, labels: ["document": 0.9])) == nil)
        #expect(UtilityClassifier.kind(of: PhotoSignals(labels: ["people": 0.6, "document": 0.9])) == nil)
    }

    @Test("Seules les photos de la période ; ni vidéos ni captures ; par famille, puis les plus récentes")
    func analysis() async {
        let library = FakeLibrary()
        let day: TimeInterval = 86_400
        library.add("ancien-doc", created: now.addingTimeInterval(-400 * day), size: 2_000_000)
        library.add("doc", created: now.addingTimeInterval(-10 * day), size: 2_000_000)
        library.add("doc-recent", created: now.addingTimeInterval(-2 * day), size: 1_000_000)
        library.add("qr", created: now.addingTimeInterval(-20 * day), size: 500_000)
        library.add("paysage", created: now.addingTimeInterval(-5 * day), size: 3_000_000)
        library.add("capture", created: now.addingTimeInterval(-5 * day), size: 300_000, screenshot: true)
        library.add("film", media: .video, created: now.addingTimeInterval(-5 * day), size: 9_000_000, duration: 10)
        let document = PhotoSignals(labels: ["document": 0.7])
        library.signalsByID = [
            "ancien-doc": document, "doc": document, "doc-recent": document, "capture": document, "film": document,
            "qr": PhotoSignals(barcodes: 1), "paysage": PhotoSignals(labels: ["outdoor": 0.8]),
        ]

        let matches = await PhotoAnalyzer.utilities(library, among: library.all, since: now.addingTimeInterval(-365 * day))

        #expect(matches.map(\.id) == ["qr", "doc-recent", "doc"])
        #expect(matches.map(\.kind) == [.barcode, .document, .document])
        let item = matches[1].entry.cleanupItem(for: .utility)
        #expect(item.ruleID == "photos.utility")
        #expect(item.category == .photoUtilities)
        #expect(!PreselectionPolicy().preselects(item, now: now))
    }

    @Test("Les documents et les cartes ne se cochent pas par lot")
    func noBulkForSensitive() {
        #expect(!PhotoUtilityKind.document.allowsSelectAll)
        #expect(!PhotoUtilityKind.card.allowsSelectAll)
        #expect(PhotoUtilityKind.barcode.allowsSelectAll)
    }

    @Test("Chaque famille a son nom dans le catalogue")
    func catalog() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OustLocalization/Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let keys = Set((object?["strings"] as? [String: Any] ?? [:]).keys)
        for kind in PhotoUtilityKind.allCases {
            #expect(keys.contains(kind.localizationKey), "clé absente : \(kind.localizationKey)")
        }
    }
}
