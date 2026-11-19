import Foundation
import Synchronization
import Testing
import OustCore
@testable import OustModel
@testable import OustVolume

@Suite("Les détails APFS suivent leur demande") @MainActor
struct StorageDetailsModelTests {
    @Test("Une lecture A tardive ne remplace ni ne termine B", arguments: [false, true])
    func lateResult(olderFinishesFirst: Bool) async throws {
        let f = try Fixture(); defer { f.remove() }
        let reader = ControlledReader(); defer { reader.finishAll() }
        let model = StorageDetailsModel(read: { await reader.read($0) })
        let first = Task { await model.load(for: f.a) }
        await reader.waitForCalls(1)
        #expect(model.isLoading(for: f.a) && model.usage(for: f.a) == nil)
        #expect(model.usage(for: f.b) == nil && model.isLoading(for: f.b))
        let second = Task { await model.load(for: f.b) }
        await reader.waitForCalls(2)
        if olderFinishesFirst {
            reader.finish(1, with: f.usageA); await first.value
            #expect(model.isLoading(for: f.b) && model.usage(for: f.b) == nil)
        }
        reader.finish(2, with: f.usageB); await second.value
        #expect(model.usage(for: f.b)?.identifier == f.usageB.identifier)
        #expect(!model.isLoading(for: f.b) && model.usage(for: f.a) == nil)
        if !olderFinishesFirst { reader.finish(1, with: f.usageA); await first.value }
        #expect(model.usage(for: f.b)?.identifier == f.usageB.identifier)
        #expect(!model.isLoading(for: f.b) && model.usage(for: f.a) == nil)
        #expect(reader.roots == [f.a.scanRoot, f.b.scanRoot] && reader.allReadsCancellable)
        try f.expectDocumentsIntact()
    }

    @Test("A puis B puis A n’admet pas la première réponse A")
    func returningToSameVolume() async throws {
        let f = try Fixture(); defer { f.remove() }
        let reader = ControlledReader(); defer { reader.finishAll() }
        let model = StorageDetailsModel(read: { await reader.read($0) })
        let firstA = Task { await model.load(for: f.a) }
        await reader.waitForCalls(1)
        let middleB = Task { await model.load(for: f.b) }
        await reader.waitForCalls(2)
        let finalA = Task { await model.load(for: f.a) }
        await reader.waitForCalls(3)
        reader.finish(1, with: f.usageA); await firstA.value
        #expect(model.usage(for: f.a) == nil && model.isLoading(for: f.a))
        reader.finish(2, with: f.usageB); await middleB.value
        #expect(model.usage(for: f.a) == nil && model.isLoading(for: f.a))
        reader.finish(3, with: f.usageA); await finalA.value
        #expect(model.usage(for: f.a)?.identifier == f.usageA.identifier)
        #expect(!model.isLoading(for: f.a) && model.usage(for: f.b) == nil)
        try f.expectDocumentsIntact()
    }

    @Test("Fermer pendant la lecture ignore sa réponse même si le lecteur continue")
    func cancelledRead() async throws {
        let f = try Fixture(); defer { f.remove() }
        let reader = ControlledReader(); defer { reader.finishAll() }
        let model = StorageDetailsModel(read: { await reader.read($0) })
        let work = Task { await model.load(for: f.a) }
        await reader.waitForCalls(1)
        work.cancel()
        reader.finish(1, with: f.usageA); await work.value
        #expect(model.usage(for: f.a) == nil && !model.isLoading(for: f.a))
        #expect(reader.roots == [f.a.scanRoot])
        try f.expectDocumentsIntact()
    }

    @Test("Une tâche déjà annulée ne commence aucune lecture")
    func cancelledBeforeAdmission() async throws {
        let f = try Fixture(); defer { f.remove() }
        let reader = ControlledReader(); defer { reader.finishAll() }
        let model = StorageDetailsModel(read: { await reader.read($0) })
        let work = Task { await model.load(for: f.a) }
        work.cancel(); await work.value
        #expect(reader.roots.isEmpty && model.usage(for: f.a) == nil)
        try f.expectDocumentsIntact()
    }

    @Test("Un résultat absent termine seulement son chargement et ne garde pas l’ancien disque")
    func unavailableResult() async throws {
        let f = try Fixture(); defer { f.remove() }
        let reader = ControlledReader(); defer { reader.finishAll() }
        let model = StorageDetailsModel(read: { await reader.read($0) })
        let first = Task { await model.load(for: f.a) }
        await reader.waitForCalls(1)
        reader.finish(1, with: f.usageA); await first.value
        #expect(model.usage(for: f.a) != nil)
        // L’accès de B est déjà vide avant que sa tâche ne commence.
        #expect(model.usage(for: f.b) == nil && model.isLoading(for: f.b))
        let second = Task { await model.load(for: f.b) }
        await reader.waitForCalls(2)
        #expect(model.usage(for: f.a) == nil && model.usage(for: f.b) == nil)
        reader.finish(2, with: nil); await second.value
        #expect(!model.isLoading(for: f.b) && model.usage(for: f.b) == nil)
        #expect(model.usage(for: f.a) == nil)
        try f.expectDocumentsIntact()
    }

    @Test("L’identité suit le disque, sa racine et son montage, jamais sa capacité")
    func volumeIdentity() throws {
        let f = try Fixture(); defer { f.remove() }
        let model = StorageDetailsModel(read: { _ in nil })
        let original = model.identity(for: f.a)
        var capacity = f.a
        capacity.capacity = Capacity(total: 2_000, available: 1_500, availableForImportantUsage: 1_600)
        capacity.name = "Nouveau nom"
        #expect(model.identity(for: capacity) == original)
        #expect(model.identity(for: f.b) != original)
        var root = f.a; root.scanRoot = f.b.scanRoot
        #expect(model.identity(for: root) != original)
        var mounted = f.a
        mounted.mountIdentity = VolumeMountIdentity(device: 7, inode: 1, createdSeconds: 1, createdNanoseconds: 0,
                                                   filesystemID: [7, 1])
        #expect(model.identity(for: mounted) != original)
        var remounted = mounted
        remounted.mountIdentity = VolumeMountIdentity(device: 7, inode: 2, createdSeconds: 1, createdNanoseconds: 0,
                                                     filesystemID: [7, 1])
        #expect(model.identity(for: mounted) != model.identity(for: remounted))
        try f.expectDocumentsIntact()
    }

    private struct Fixture {
        let root: URL
        let a: VolumeDescriptor
        let b: VolumeDescriptor
        let usageA: APFSContainerUsage
        let usageB: APFSContainerUsage

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("oust-storage-details-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
            let a = root.appendingPathComponent("A", isDirectory: true)
            let b = root.appendingPathComponent("B", isDirectory: true)
            do {
                for folder in [a, b] {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data(repeating: 31, count: 1_024).write(to: folder.appendingPathComponent("document.txt"))
                }
                self.usageA = try Self.usage("A", in: root)
                self.usageB = try Self.usage("B", in: root)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
            self.root = root
            let capacity = Capacity(total: 1_000, available: 400, availableForImportantUsage: 500)
            self.a = VolumeDescriptor(name: "A", mountURL: a, scanRoot: a, isBoot: false,
                                      isInternal: false, isRemovable: true, capacity: capacity)
            self.b = VolumeDescriptor(name: "B", mountURL: b, scanRoot: b, isBoot: false,
                                      isInternal: false, isRemovable: true, capacity: capacity)
        }

        private static func usage(_ marker: String, in root: URL) throws -> APFSContainerUsage {
            let document = root.appendingPathComponent("usage-\(marker).plist")
            let object: [String: Any] = ["Containers": [[
                "ContainerReference": marker, "CapacityCeiling": 1_000, "CapacityFree": 400,
                "Volumes": [["DeviceIdentifier": "volume-\(marker)", "Name": marker, "CapacityInUse": 500]],
            ]]]
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: document)
            guard let parsed = APFSContainerUsage.parse(try Data(contentsOf: document), reference: marker,
                                                        selectedVolume: "volume-\(marker)") else { throw InvalidFixture() }
            return parsed
        }

        func expectDocumentsIntact() throws {
            for folder in [a.scanRoot, b.scanRoot] {
                #expect(try Data(contentsOf: folder.appendingPathComponent("document.txt")) == Data(repeating: 31, count: 1_024))
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        private struct InvalidFixture: Error {}
    }
}

/// Le faux lecteur ignore volontairement l’annulation de ses appelants.
private final class ControlledReader: Sendable {
    private struct State {
        var roots: [URL] = []
        var allReadsCancellable = true
        var pending: [Int: CheckedContinuation<APFSContainerUsage?, Never>] = [:]
        var prepared: [Int: Reply] = [:]
    }
    private struct Reply { let usage: APFSContainerUsage? }
    private let state = Mutex(State())

    var roots: [URL] { state.withLock { $0.roots } }
    var allReadsCancellable: Bool { state.withLock { $0.allReadsCancellable } }

    func read(_ root: URL) async -> APFSContainerUsage? {
        await withCheckedContinuation { continuation in
            let reply: Reply? = state.withLock {
                $0.roots.append(root)
                $0.allReadsCancellable = $0.allReadsCancellable && CommandCancellationContext.cancelsReadOnlyCommands
                let call = $0.roots.count
                if let reply = $0.prepared.removeValue(forKey: call) { return reply }
                $0.pending[call] = continuation
                return nil
            }
            if let reply { continuation.resume(returning: reply.usage) }
        }
    }

    func finish(_ call: Int, with usage: APFSContainerUsage?) {
        let continuation = state.withLock {
            let continuation = $0.pending.removeValue(forKey: call)
            if continuation == nil { $0.prepared[call] = Reply(usage: usage) }
            return continuation
        }
        continuation?.resume(returning: usage)
    }

    func finishAll() {
        let pending = state.withLock { value in
            let pending = Array(value.pending.values)
            value.pending.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume(returning: nil) }
    }

    func waitForCalls(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while roots.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(roots.count >= count)
    }
}
