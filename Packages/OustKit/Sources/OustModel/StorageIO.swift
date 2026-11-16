import Foundation

/// Les chemins des sauvegardes et des exports peuvent se trouver sur un partage.
func storageIO<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

func throwingStorageIO<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await storageIO { Result { try work() } }.get()
}
