import Foundation
import Synchronization
import Testing
import OustCore
@testable import OustModel

@Suite("Le contexte des rafraîchissements autonomes")
struct BackgroundStorageContextTests {
    @Test("Un rafraîchissement issu d’une analyse ne conserve ni son verrou ni son signal de progression")
    func clearsInheritedAnalysisContext() async {
        let gate = StorageTaskGate()
        let observed = Mutex((isBound: true, hasProgress: true, cancelsCommands: true))
        let retainedParentContext = await gate.run(timeout: .seconds(2)) {
          await CommandCancellationContext.$cancelsReadOnlyCommands.withValue(true) {
            let child = AppModel.backgroundStorageTask {
                observed.withLock {
                    $0 = (StorageOperationContext.isBound, StorageOperationContext.progress != nil,
                          CommandCancellationContext.cancelsReadOnlyCommands)
                }
            }
            await child.value
            return StorageOperationContext.isBound && StorageOperationContext.progress != nil
                && CommandCancellationContext.cancelsReadOnlyCommands
          }
        }

        #expect(retainedParentContext == true)
        let snapshot = observed.withLock { $0 }
        #expect(!snapshot.isBound)
        #expect(!snapshot.hasProgress)
        #expect(!snapshot.cancelsCommands)
    }
}
