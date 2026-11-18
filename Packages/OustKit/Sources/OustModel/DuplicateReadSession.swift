import Synchronization

/// Les travaux admis peuvent finir avant la prise d'effet de la nouvelle liste.
/// Les travaux encore en file ne peuvent plus entrer après révocation.
final class DuplicateReadSession: Sendable {
    private struct State {
        var revoked = false
        var readers = 0
    }
    private let state = Mutex(State())

    func acquire() -> Bool {
        state.withLock {
            guard !$0.revoked, $0.readers < 4 else { return false }
            $0.readers += 1
            return true
        }
    }

    func release() {
        state.withLock { $0.readers -= 1 }
    }

    func revoke() {
        state.withLock { $0.revoked = true }
    }

    var isIdle: Bool { state.withLock { $0.readers == 0 } }
    var isRevoked: Bool { state.withLock { $0.revoked } }

    final class Reader: Sendable {
        private let session: DuplicateReadSession
        fileprivate init(_ session: DuplicateReadSession) { self.session = session }
        deinit { session.release() }
    }

    func reader() -> Reader? {
        acquire() ? Reader(self) : nil
    }
}
