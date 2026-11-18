import Foundation
import Synchronization
import Testing
@testable import OustCore

@Suite("Le délai suit l’activité réelle du stockage")
struct StorageInactivityTests {
    @Test("La progression du worker natif renouvelle aussi le délai")
    func nativeProgressContinues() async {
        let result = await StorageTaskGate().run(timeout: .milliseconds(200)) {
            await checkStorageIO {
                for _ in 0..<8 {
                    Thread.sleep(forTimeInterval: 0.05)
                    StorageOperationContext.reportProgress()
                }
                return 9
            }
        }
        #expect(result == .some(.some(9)))
    }

    @Test("Une opération qui progresse dépasse le budget total sans expirer")
    func healthyProgressContinues() async throws {
        let gate = StorageTaskGate()
        let began = ContinuousClock.now
        let result = await gate.run(timeout: .milliseconds(200)) {
            for _ in 0..<8 {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return -1 }
                StorageOperationContext.reportProgress()
            }
            return 7
        }
        #expect(result == 7)
        #expect(began.duration(to: ContinuousClock.now) >= .milliseconds(400))
    }

    @Test("L’inactivité après une progression termine l’attente et conserve le worker")
    func stallAfterProgress() async throws {
        let gate = StorageTaskGate()
        let resume = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        defer { resume.signal() }
        let result = await gate.run(timeout: .milliseconds(80)) {
            for _ in 0..<4 {
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return nil as Int? }
                StorageOperationContext.reportProgress()
            }
            return await checkStorageIO {
                calls.withLock { $0 += 1 }
                resume.wait()
                return 1
            }
        }
        #expect(result == nil)
        #expect(calls.withLock { $0 } == 1)
        let retry = await gate.run(timeout: .milliseconds(30)) { 2 }
        #expect(retry == nil)
        resume.signal()
        let next = await gate.run(timeout: .seconds(2)) { 3 }
        #expect(next == 3)
    }

    @Test("Une tâche autonome ne conserve ni le contexte borné ni le moniteur")
    func unboundContextClearsProgress() async {
        let observed = await StorageTaskGate().run {
            let task = StorageOperationContext.withUnboundContext {
                Task { (StorageOperationContext.isBound, StorageOperationContext.progress == nil) }
            }
            return await task.value
        }
        #expect(observed?.0 == false)
        #expect(observed?.1 == true)
    }
}
