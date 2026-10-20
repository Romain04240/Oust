import Foundation
import Testing
@testable import OustModel
import OustCore

@Suite("Les conseils ouvrent les éléments précis encore présents")
@MainActor
struct StorageAdviceTests {
    @Test("Un conseil ne reprend ni les éléments étrangers ni ceux devenus protégés")
    func matchingItems() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-model-\(UUID().uuidString)")
        let model = AppModel(home: home)
        func item(_ name: String) -> CleanupItem {
            CleanupItem(title: name, paths: [home.appendingPathComponent(name)], category: .projectArtifacts,
                        owner: "fixture", ruleID: "fixture", safety: .rebuilds, method: .removeNow,
                        sizes: Sizes(private: 500), rebuild: .automatic)
        }
        let first = item("first")
        let other = item("other")
        var blocked = item("blocked")
        blocked.protect(.inUse)
        model.items = [first.id: first, other.id: other, blocked.id: blocked]
        let advice = StorageAdvice(id: "builds", title: "fixture", detail: "fixture", bytes: 1000,
                                   destination: .developer, url: nil, itemIDs: [first.id, blocked.id, "missing"])
        #expect(model.items(for: advice).map(\.id) == [first.id])
        #expect(model.cart.isEmpty)
        model.items.removeValue(forKey: first.id)
        #expect(model.items(for: advice).isEmpty)
    }
}
