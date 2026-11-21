import Foundation

/// Aucun réglage lu avant une attente ne vaut autorisation après celle-ci.
@MainActor
enum AlertNotificationGate {
    static func send<Value: Sendable>(
        permission: () async -> Bool,
        enabled: () -> Bool,
        current: () async -> Value?,
        reserve: (Value) -> Bool,
        post: (Value) async -> Bool,
        complete: (Bool) -> Void,
        withdraw: () async -> Void
    ) async {
        guard await permission(), !Task.isCancelled, enabled(), let value = await current(),
              !Task.isCancelled, enabled(), reserve(value) else { return }
        let accepted = await post(value)
        complete(accepted)
        // Après acceptation, c'est un événement daté, pas un indicateur en direct.
        // Une lecture occupée ou un composant expiré n'efface pas cet historique.
        if accepted && !enabled() { await withdraw() }
    }
}
