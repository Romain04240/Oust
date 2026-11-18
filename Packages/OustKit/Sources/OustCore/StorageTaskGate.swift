import Foundation
import Synchronization

/// Progress renews the inactivity budget without releasing the native worker.
package final class StorageOperationProgress: Sendable {
    private let lastProgress = Mutex(ContinuousClock.now)

    package init() {}

    package func reportProgress() {
        lastProgress.withLock { $0 = ContinuousClock.now }
    }

    package func waitForInactivity(_ timeout: Duration) async throws {
        while true {
            let remaining = lastProgress.withLock { last in
                timeout - last.duration(to: ContinuousClock.now)
            }
            guard remaining > .zero else { return }
            try await Task.sleep(for: remaining)
        }
    }
}

/// Native work inherits its owner's progress monitor and waits for actual exit.
package enum StorageOperationContext {
    @TaskLocal package static var isBound = false
    @TaskLocal package static var progress: StorageOperationProgress?

    package static func reportProgress() {
        progress?.reportProgress()
    }

    package static func withUnboundContext<Value>(_ operation: () throws -> Value) rethrows -> Value {
        try $isBound.withValue(false) {
            try $progress.withValue(nil, operation: operation)
        }
    }
}

package final class StorageTaskGate: Sendable {
    package static let sharedVolumeAnalysis = StorageTaskGate()
    private let occupied = Mutex(false)

    package init() {}

    package func run<Value: Sendable>(
        timeout: Duration = .seconds(15),
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let (stream, continuation) = AsyncStream<Value>.makeStream()
        let progress = StorageOperationProgress()
        let worker = Task.detached {
            while !Task.isCancelled {
                let acquired = self.occupied.withLock { busy in
                    guard !busy else { return false }
                    busy = true
                    return true
                }
                if acquired {
                    defer {
                        self.occupied.withLock { $0 = false }
                        continuation.finish()
                    }
                    guard !Task.isCancelled else { return }
                    progress.reportProgress()
                    let value = await StorageOperationContext.$progress.withValue(progress) {
                        await StorageOperationContext.$isBound.withValue(true, operation: operation)
                    }
                    guard !Task.isCancelled else { return }
                    continuation.yield(value)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            }
            continuation.finish()
        }
        let deadline = Task {
            do { try await progress.waitForInactivity(timeout) } catch { return }
            worker.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in
            worker.cancel()
            deadline.cancel()
        }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
