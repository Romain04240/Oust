import Foundation
import Testing
import OustCore
@testable import OustModel

private actor AlertReadGate {
    private var release: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    private var entered = false
    func wait() async { entered = true; ready?.resume(); ready = nil; await withCheckedContinuation { release = $0 } }
    func untilEntered() async { if !entered { await withCheckedContinuation { ready = $0 } } }
    func finish() { release?.resume(); release = nil }
}
@Suite @MainActor struct AlertDiskPublicationTests {
    @Test func lateCollectionAndNilPublication() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentinel = dir.appendingPathComponent("fictif.bin"); try Data([1,2,3]).write(to: sentinel)
        let watch = WatchModel(defaults: MemoryDefaults())
        let old = VolumeDescriptor(name: "QA", mountURL: dir, scanRoot: dir, isBoot: true, isInternal: true, isRemovable: false,
            capacity: Capacity(total: 1000, available: 100, availableForImportantUsage: 100))
        var recent = old; recent.capacity = Capacity(total: 1000, available: 700, availableForImportantUsage: 700)
        let gate = AlertReadGate()
        let pending = Task { await watch.checkDisk(read: { await gate.wait(); return [old] }, excluding: []) }
        await gate.untilEntered()
        watch.updateBoot(recent)
        await gate.finish(); await pending.value
        #expect(watch.boot?.capacity.available == 700)
        await watch.checkDisk(read: { [] }, excluding: [])
        #expect(watch.boot == nil)
        #expect(try Data(contentsOf: sentinel) == Data([1,2,3]))
    }
}
