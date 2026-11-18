import Foundation
import Synchronization
import Testing
@testable import OustRules
import OustCore
import OustScan

@Suite("Publication des lots externes")
struct BoundBatchPublicationTests {
    @Test("Le lot rendu est une valeur et la publication revérifie les manifestes")
    func snapshotAndExplicitPublicationCheck() async throws {
        let home = try FakeHome()
        try home.file("Volume/SteamLibrary/steamapps/common/Jeu/donnees", bytes: 1_200_000)
        let anchor = try home.openVolume(home.root.appendingPathComponent("Volume", isDirectory: true))
        var context = home.context()
        context.volume = VolumeScope(root: anchor.url, name: "Test", fileSystem: "apfs")
        context.volume?.root = anchor.url
        context.volumeAnchor = anchor
        var batches: [RuleBatch] = []
        for await batch in RuleEngine.run(context, finders: [.games]) { batches.append(batch) }
        let batch = try #require(batches.first)
        #expect(batch.items.contains { $0.ruleID == "game.steam.leftover" })

        try home.text("Volume/SteamLibrary/steamapps/appmanifest_42.acf", #""installdir" "Jeu""#)
        // The consumer can inspect the value without starting another native read.
        #expect(batch.items.contains { $0.ruleID == "game.steam.leftover" })
        #expect(!batch.revalidatedItems().contains { $0.ruleID == "game.steam.leftover" })
    }

    @Test("La fermeture du flux ne termine pas une lecture encore suspendue")
    func streamTerminationWaitsForActualWorker() async throws {
        let home = try FakeHome()
        try home.text("Volume/temoin", "")
        let anchor = try home.openVolume(home.root.appendingPathComponent("Volume", isDirectory: true))
        let suspended = Mutex<CheckedContinuation<TreeNode?, Never>?>(nil)
        let finished = Mutex(false)
        var context = home.context()
        context.volume = VolumeScope(root: anchor.url, name: "Test", fileSystem: "apfs")
        context.volume?.root = anchor.url
        context.volumeAnchor = anchor
        context.tree = {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                suspended.withLock { $0 = continuation }
            }
        }
        let operation = StorageOperationContext.$isBound.withValue(true) {
            RuleEngine.runWithinStorageOperation(context, finders: [.games])
        }
        let consumer = Task { for await _ in operation.batches {} }
        for _ in 0..<100 where suspended.withLock({ $0 == nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let held = suspended.withLock { value in
            let continuation = value
            value = nil
            return continuation
        }
        let continuation = try #require(held)
        operation.completion.cancel()
        consumer.cancel()
        let waiter = Task {
            await operation.completion.value
            finished.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!finished.withLock { $0 })
        continuation.resume(returning: nil)
        await waiter.value
        #expect(finished.withLock { $0 })
    }

    @Test("Une preuve native bloquée retient le worker après expiration")
    func blockedProofKeepsWorkerSlot() async throws {
        let gate = BoundRuleRun()
        let semaphore = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let proofFinished = Mutex(false)
        let work: @Sendable (@escaping @Sendable () -> Void) -> AsyncStream<RuleBatch> = { release in
            calls.withLock { $0 += 1 }
            return AsyncStream { continuation in
                Task {
                    defer { release(); continuation.finish() }
                    _ = await checkStorageIO {
                        semaphore.wait()
                        return true
                    }
                    proofFinished.withLock { $0 = true }
                }
            }
        }
        for await _ in gate.run(timeout: .milliseconds(30), work: work) {}
        for await _ in gate.run(timeout: .milliseconds(30), work: work) {}
        #expect(calls.withLock { $0 } == 1)
        #expect(!proofFinished.withLock { $0 })
        semaphore.signal()
        for _ in 0..<100 where !proofFinished.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(proofFinished.withLock { $0 })
    }
}
