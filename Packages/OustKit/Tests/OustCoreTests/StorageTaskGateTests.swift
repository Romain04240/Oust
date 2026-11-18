import Foundation
import Synchronization
import Testing
@testable import OustCore

@Suite("Le verrou des opérations de stockage")
struct StorageTaskGateTests {
    @Test("Un contrôle natif expiré garde le verrou et ignore son résultat tardif")
    func nativeCheckRetainsPermit() async throws {
        let gate = StorageTaskGate()
        let resume = DispatchSemaphore(value: 0)
        let started = Mutex(0)
        let finished = Mutex(false)
        defer { resume.signal() }
        let result = await gate.run(timeout: .milliseconds(40)) {
            await checkStorageIO {
                started.withLock { $0 += 1 }
                resume.wait()
                finished.withLock { $0 = true }
                return 1
            }
        }
        #expect(result == nil)
        #expect(started.withLock { $0 } == 1)
        let retry = await gate.run(timeout: .milliseconds(40)) {
            started.withLock { $0 += 1 }
            return 2
        }
        #expect(retry == nil)
        #expect(started.withLock { $0 } == 1)
        #expect(!finished.withLock { $0 })
        resume.signal()
        let next = await gate.run(timeout: .seconds(2)) { 3 }
        #expect(next == 3)
        #expect(finished.withLock { $0 })
    }

    @Test("L’annulation du demandeur termine l’attente sans libérer prématurément le travail natif")
    func callerCancellation() async throws {
        let gate = StorageTaskGate()
        let resume = DispatchSemaphore(value: 0)
        let started = Mutex(false)
        defer { resume.signal() }
        let request = Task {
            await gate.run(timeout: .seconds(2)) {
                await checkStorageIO {
                    started.withLock { $0 = true }
                    resume.wait()
                    return 1
                }
            }
        }
        for _ in 0..<100 where !started.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        request.cancel()
        let cancelled = await request.value
        #expect(cancelled == nil)
        let retry = await gate.run(timeout: .milliseconds(30)) { 2 }
        #expect(retry == nil)
        resume.signal()
        let next = await gate.run(timeout: .seconds(2)) { 3 }
        #expect(next == 3)
    }
}
