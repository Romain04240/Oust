import Foundation

/// Une vérification d'affichage peut expirer pendant qu'un appel noyau
/// réseau continue. Seul le premier résultat est publié.
package func checkStorageIO<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
    if StorageOperationContext.isBound {
        guard !Task.isCancelled else { return nil }
        let progress = StorageOperationContext.progress
        let value = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = StorageOperationContext.$progress.withValue(progress, operation: work)
                continuation.resume(returning: result)
            }
        }
        guard !Task.isCancelled else { return nil }
        StorageOperationContext.reportProgress()
        return value
    }
    let (stream, continuation) = AsyncStream<T>.makeStream()
    DispatchQueue.global(qos: .userInitiated).async {
        continuation.yield(work())
        continuation.finish()
    }
    let deadline = Task {
        do { try await Task.sleep(for: .milliseconds(750)) }
        catch { return }
        continuation.finish()
    }
    defer { deadline.cancel(); continuation.finish() }
    var results = stream.makeAsyncIterator()
    return await results.next()
}
