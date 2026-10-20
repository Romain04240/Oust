import Foundation
import Testing
@testable import OustModel
import OustCore
import OustVolume

@Suite("Les snapshots relus remplacent l'état précédent")
@MainActor
struct SnapshotStateTests {
    @Test("Les snapshots suivent la date décroissante, même si le plus ancien est le plus gros")
    func chronologicalOrder() async {
        let model = AppModel(home: FileManager.default.temporaryDirectory.appendingPathComponent("oust-model-\(UUID().uuidString)"))
        var oldest = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-18-101500.local")
        oldest.privateBytes = 10_000
        var newest = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-20-131500.local")
        newest.privateBytes = 1
        var morning = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-20-081500.local")
        morning.privateBytes = 500
        let snapshots = [morning, oldest, newest]
        await model.refreshSnapshots(using: { snapshots })
        let expected = [newest.name, morning.name, oldest.name].map { "snapshot|" + $0 }
        #expect(model.deletableSnapshots.map(\.id) == expected)
        model.add(model.deletableSnapshots)
        #expect(model.cartItems.map(\.id) == expected)
        model.searchText = "TimeMachine"
        #expect(model.searchResults.map(\.id) == expected)
    }
    @Test("Une date disparue quitte la liste et la corbeille, une liste illisible les conserve")
    func refresh() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-model-\(UUID().uuidString)")
        let model = AppModel(home: home)
        let first = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-18-101500.local")
        let second = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-19-101500.local")
        await model.refreshSnapshots(using: { [first, second] })
        model.add(model.deletableSnapshots)
        #expect(model.deletableSnapshots.count == 2)
        #expect(model.cart.count == 2)
        await model.refreshSnapshots(using: { [second] })
        #expect(model.snapshots == [second])
        #expect(model.deletableSnapshots.count == 1)
        #expect(model.cart == ["snapshot|" + second.name])
        await model.refreshSnapshots(using: { nil })
        #expect(model.snapshotReadFailed)
        #expect(model.snapshots == [second])
        #expect(model.cart.count == 1)
        await model.refreshSnapshots(using: { [] })
        #expect(!model.snapshotReadFailed)
        #expect(model.deletableSnapshots.isEmpty)
        #expect(model.cart.isEmpty)
    }
    @Test("Les mesures Time Machine sont gardées même si un snapshot tiers est présent")
    func thirdPartySnapshot() async {
        let model = AppModel(home: FileManager.default.temporaryDirectory.appendingPathComponent("oust-model-\(UUID().uuidString)"))
        var first = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-18-101500.local")
        first.privateBytes = 100
        var second = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-19-101500.local")
        second.privateBytes = 200
        let inventory = SnapshotInventory(snapshots: [first, LocalSnapshot(name: "third.party.snapshot"), second], retainedBytes: 700)
        let shown = [LocalSnapshot(name: first.name), LocalSnapshot(name: second.name)]
        await model.refreshSnapshots(using: { shown }, inventory: { inventory })
        await model.snapshotSizeTask?.value
        #expect(model.snapshotRetainedBytes == 700)
        #expect(model.snapshots.count == 2)
        #expect(model.snapshots.first?.privateBytes == 100)
        model.add(model.deletableSnapshots)
        #expect(model.cartSnapshotIsAggregate)
        #expect(model.cartTotal == 700)
        model.cart.remove("snapshot|" + second.name)
        #expect(!model.cartSnapshotIsAggregate)
        #expect(model.cartTotal == 100)
        // Une suppression partielle ou une reliste illisible ne réattribue pas
        // l'ancien total de tous les snapshots à la seule entrée restante.
        model.items.removeValue(forKey: "snapshot|" + second.name)
        #expect(!model.cartSnapshotIsAggregate)
        #expect(model.cartTotal == 100)
        await model.refreshSnapshots(using: { nil })
        #expect(model.snapshotRetainedBytes == nil)
        #expect(model.cartTotal == 100)
    }

    @Test("Une taille APFS réellement nulle reste connue jusqu'à la corbeille")
    func measuredZero() async {
        let model = AppModel(home: FileManager.default.temporaryDirectory.appendingPathComponent("oust-model-\(UUID().uuidString)"))
        var snapshot = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-18-101500.local")
        snapshot.privateBytes = 0
        let inventory = SnapshotInventory(snapshots: [snapshot], retainedBytes: 0)
        let shown = [LocalSnapshot(name: snapshot.name)]
        await model.refreshSnapshots(using: { shown }, inventory: { inventory })
        await model.snapshotSizeTask?.value
        model.add(model.deletableSnapshots)
        #expect(model.cartSnapshotSizesKnown)
        #expect(model.cartSnapshotBytes == 0)
        #expect(model.cartItems.first?.measuredSnapshotBytes == 0)
    }

    @Test("Une reliste en échec ne laisse pas la mesure de l'ancienne révision active")
    func staleMeasurement() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oust-model-\(UUID().uuidString)")
        let model = AppModel(home: home)
        let gate = InventoryGate()
        let snapshot = LocalSnapshot(name: "com.apple.TimeMachine.2026-10-18-101500.local")
        await model.refreshSnapshots(using: { [snapshot] }, inventory: { await gate.read() })
        await gate.waitForRead()
        #expect(model.snapshotSizing)
        let previous = model.snapshotSizeTask
        await model.refreshSnapshots(using: { nil })
        #expect(!model.snapshotSizing)
        #expect(model.snapshotReadFailed)
        await gate.finish(SnapshotInventory(snapshots: [snapshot], retainedBytes: 500))
        await previous?.value
        #expect(!model.snapshotSizing)
        #expect(model.snapshotRetainedBytes == nil)
    }

}


private actor InventoryGate {
    private var continuation: CheckedContinuation<SnapshotInventory?, Never>?
    func read() async -> SnapshotInventory? {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForRead() async {
        while continuation == nil { await Task.yield() }
    }
    func finish(_ inventory: SnapshotInventory) {
        continuation?.resume(returning: inventory)
        continuation = nil
    }
}
