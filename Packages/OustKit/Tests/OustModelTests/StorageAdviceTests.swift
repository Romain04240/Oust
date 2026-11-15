import Foundation
import Testing
@testable import OustModel
import OustCore
import OustDuplicates

@Suite("Les conseils ouvrent les éléments précis encore présents")
@MainActor
struct StorageAdviceTests {
    @Test("L'analyse exclut les actions suspendues dès chaque résultat")
    func preselectionHonorsAvailability() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-model-\(UUID().uuidString)")
        let model = AppModel(home: home)
        let item = CleanupItem(title: "Cache fictif", paths: [home.appendingPathComponent("cache")],
                               category: .packageCaches, owner: "fixture", ruleID: "fixture",
                               safety: .safe, method: .removeNow, sizes: Sizes(private: 400), rebuild: .automatic)
        let policy = PreselectionPolicy()
        #expect(policy.preselects(item))
        model.recordAnalyzedItem(item, preselect: true, policy: policy)
        #expect(model.items[item.id] != nil && model.cart.isEmpty)
        var supported = item
        supported.method = .evictLocalCopy
        model.recordAnalyzedItem(supported, preselect: true, policy: policy)
        #expect(model.isInCart(item.id))
        model.recordAnalyzedItem(item, preselect: false, policy: policy)
        #expect(model.cart.isEmpty)
    }

    @Test("Des doublons fictifs sont visibles sans proposer de nettoyage suspendu")
    func suspendedDuplicates() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-model-\(UUID().uuidString)")
        let downloads = home.appendingPathComponent("Downloads")
        let fm = FileManager.default
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let original = home.appendingPathComponent("a.txt")
        let copy = downloads.appendingPathComponent("a.txt")
        let data = Data(repeating: 17, count: 64 * 1024)
        try data.write(to: original)
        try data.write(to: copy)
        let options = DuplicateOptions(roots: [home], minimumSize: 1, preferredForRemoval: [downloads])
        let group = try #require(await DuplicateFinder.find(options).first)
        #expect(group.reclaimable > 0)
        let model = AppModel(home: home)
        model.showDuplicates([group], volume: nil)
        let index = try #require(group.proposed.first)
        for asClones in [false, true] {
            model.duplicatesAsClones = asClones
            let candidate = try #require(model.duplicateItem(group: group, file: index))
            #expect(!model.canCleanDuplicates && model.availableDuplicateSuggestions.isEmpty)
            #expect(model.reclaimableDuplicateBytes == 0)
            #expect(!model.canSelectForCleanup(candidate))
        }
        #expect(model.duplicateGroups.count == 1 && model.cart.isEmpty)
    }

    @Test("Des sources et une destination présentes ne réactivent pas un transfert suspendu")
    func suspendedTransferAdvice() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-model-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let source = home.appendingPathComponent("example.txt")
        try Data("fictif".utf8).write(to: source)
        let model = AppModel(home: home)
        model.transfer.present(sources: [source])
        model.transfer.chooseFolder(home)
        #expect(!model.canMoveFiles && !model.transfer.canPrepare)
        await model.refreshAdvice()
        #expect(!model.archive.search.hasRun)
        #expect(model.storageAdvice.allSatisfy { $0.url == nil })
    }

    @Test("Un conseil ne reprend ni les éléments étrangers ni ceux devenus protégés")
    func matchingItems() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-model-\(UUID().uuidString)")
        let model = AppModel(home: home)
        func item(_ name: String, method: CleanupMethod = .evictLocalCopy) -> CleanupItem {
            CleanupItem(title: name, paths: [home.appendingPathComponent(name)], category: .projectArtifacts,
                        owner: "fixture", ruleID: "fixture", safety: .rebuilds, method: method,
                        sizes: Sizes(private: 500), rebuild: .automatic)
        }
        let first = item("first")
        let other = item("other")
        let suspended = item("suspended", method: .removeNow)
        var blocked = item("blocked")
        blocked.protect(.inUse)
        model.items = [first.id: first, other.id: other, blocked.id: blocked, suspended.id: suspended]
        let advice = StorageAdvice(id: "builds", title: "fixture", detail: "fixture", bytes: 1000,
                                   destination: .developer, url: nil, itemIDs: [first.id, blocked.id, suspended.id, "missing"])
        #expect(model.items(for: advice).map(\.id) == [first.id])
        #expect(model.cart.isEmpty)
        model.toggle(suspended)
        model.add([suspended, first])
        #expect(model.cartItems.map(\.id) == [first.id])
        #expect(model.cartFreesNow == 500)
        #expect(!model.watch.canRun)
        model.items.removeValue(forKey: first.id)
        #expect(model.items(for: advice).isEmpty)
    }
}
