import Foundation
import Synchronization

/// Les travaux admis peuvent finir avant la prise d'effet de la nouvelle liste.
/// Les travaux encore en file ne peuvent plus entrer après révocation.
final class DuplicateReadSession: Sendable {
    private struct State {
        var revoked = false
        var readers = 0
        var idle: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())

    func acquire() -> Bool {
        state.withLock {
            guard !$0.revoked else { return false }
            $0.readers += 1
            return true
        }
    }

    func release() {
        let idle = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.readers -= 1
            guard state.readers == 0 else { return nil }
            defer { state.idle = nil }
            return state.idle
        }
        idle?.resume()
    }

    func revoke() {
        state.withLock { $0.revoked = true }
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            let idle = state.withLock {
                if $0.readers == 0 { return true }
                $0.idle = continuation
                return false
            }
            if idle { continuation.resume() }
        }
    }
}
