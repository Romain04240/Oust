import Foundation
import OustCore
import Synchronization

/// One outstanding external analysis. A timed-out kernel read keeps the slot
/// until its worker actually exits, so retries cannot accumulate blocked work.
final class BoundRuleRun: Sendable {
    static let shared = BoundRuleRun()
    private let occupied = Mutex(false)

    func run(timeout: Duration = .seconds(15),
             work: @escaping @Sendable (@escaping @Sendable () -> Void) -> AsyncStream<RuleBatch>) -> AsyncStream<RuleBatch> {
        AsyncStream { continuation in
            let progress = StorageOperationProgress()
            let worker = Task.detached {
                while !Task.isCancelled {
                    let acquired = self.occupied.withLock { busy in
                        guard !busy else { return false }
                        busy = true
                        return true
                    }
                    if acquired {
                        let release: @Sendable () -> Void = {
                            self.occupied.withLock { $0 = false }
                        }
                        progress.reportProgress()
                        let stream = StorageOperationContext.$progress.withValue(progress) {
                            StorageOperationContext.$isBound.withValue(true) { work(release) }
                        }
                        for await batch in stream {
                            guard !Task.isCancelled else { break }
                            continuation.yield(batch)
                        }
                        continuation.finish()
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                }
                continuation.finish()
            }
            let deadline = Task {
                do { try await progress.waitForInactivity(timeout) } catch { return }
                continuation.finish()
                worker.cancel()
            }
            continuation.onTermination = { _ in
                worker.cancel()
                deadline.cancel()
            }
        }
    }
}
