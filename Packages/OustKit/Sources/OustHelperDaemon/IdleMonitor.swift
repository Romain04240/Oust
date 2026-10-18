import Foundation
import Synchronization

/// Fait quitter le démon quand personne ne s'en sert.
///
/// launchd le lance au premier message d'Oust! et le relancera au suivant :
/// rien ne justifie qu'un processus root reste là entre deux nettoyages. Il
/// part après `idle` secondes sans demande, jamais au milieu d'une.
public final class IdleMonitor: Sendable {

    private struct State {
        var running = 0
        var lastActivity = Date()
    }

    private let state = Mutex(State())
    private let idle: TimeInterval
    private let timer: any DispatchSourceTimer

    /// `onIdle` est appelé une seule fois, sur une file d'arrière-plan.
    public init(idle: TimeInterval, onIdle: @escaping @Sendable () -> Void) {
        self.idle = idle
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fr.meaillais.oust.helper.idle"))
        let check = max(1, idle / 4)
        timer.schedule(deadline: .now() + check, repeating: check)
        timer.setEventHandler { [weak self] in
            guard let self, self.isIdle(at: Date()) else { return }
            self.timer.cancel()
            onIdle()
        }
        timer.resume()
    }

    deinit { timer.cancel() }

    func begin() {
        state.withLock { $0.running += 1; $0.lastActivity = Date() }
    }

    func end() {
        state.withLock { $0.running -= 1; $0.lastActivity = Date() }
    }

    func isIdle(at now: Date) -> Bool {
        state.withLock { $0.running == 0 && now.timeIntervalSince($0.lastActivity) >= idle }
    }
}
