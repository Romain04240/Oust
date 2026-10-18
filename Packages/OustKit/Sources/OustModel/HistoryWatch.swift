import Foundation
import OustClean
import OustScan

extension HistoryStore {

    /// Un signal à chaque écriture au journal, d'où qu'elle vienne.
    ///
    /// L'app n'est plus seule à y écrire : `oust`, la commande des agents IA, y
    /// ajoute ses lignes depuis un autre processus. Relu seulement au lancement,
    /// l'Historique ignorait ce qu'un agent venait de nettoyer jusqu'au
    /// suivant.
    ///
    /// Le suivi commence avant que la fonction rende la main : ce qui s'écrit
    /// juste après n'est pas manqué. FSEvents suit un chemin, même avant que le
    /// dossier existe : la première écriture, au premier nettoyage, est vue.
    public nonisolated func changes(latency: TimeInterval = 0.3) -> AsyncStream<Void> {
        let events = FileSystemEvents.watch([directory.path], latency: latency)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let relay = Task {
                for await paths in events where paths.contains(where: HistoryStore.isJournal) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
}
