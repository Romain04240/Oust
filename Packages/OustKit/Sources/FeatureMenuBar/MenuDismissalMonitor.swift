import AppKit

/// NSPopover's transient behavior alone does not dismiss reliably when Oust
/// was already inactive. Observe clicks only while this presentation is open.
@MainActor
final class MenuDismissalMonitor {
    typealias GlobalMonitorInstaller = (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?

    private var local: Any?
    private var global: Any?
    private var inactive: (any NSObjectProtocol)?
    private var generation = UUID()
    private let installGlobalMonitor: GlobalMonitorInstaller

    init(installGlobalMonitor: @escaping GlobalMonitorInstaller = { mask, handler in
        NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }) {
        self.installGlobalMonitor = installGlobalMonitor
    }

    isolated deinit { stop() }

    func start(window: NSWindow, statusRects: @escaping @MainActor () -> [NSRect],
               close: @escaping @MainActor () -> Void) {
        stop()
        let session = generation
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard let self, self.generation == session, let window else { return }
                let point = Self.screenLocation(of: event)
                if !Self.belongs(event.window, to: window), !statusRects().contains(where: { $0.contains(point) }) {
                    close()
                }
            }
            // Never swallow the click intended for a different window.
            return event
        }
        global = installGlobalMonitor(mask) { [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard let self, self.generation == session, let window else { return }
                // The pointer may have moved since this event was queued.
                // Classify the recorded click, never the current pointer.
                let point = Self.screenLocation(of: event)
                guard !window.frame.contains(point), !statusRects().contains(where: { $0.contains(point) }) else { return }
                close()
            }
        }
        inactive = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                          object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.generation == session else { return }
                close()
            }
        }
    }

    private static func screenLocation(of event: NSEvent) -> NSPoint {
        // Events without an in-process window already use screen coordinates.
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    func stop() {
        generation = UUID()
        if let local { NSEvent.removeMonitor(local); self.local = nil }
        if let global { NSEvent.removeMonitor(global); self.global = nil }
        if let inactive { NotificationCenter.default.removeObserver(inactive); self.inactive = nil }
    }

    private static func belongs(_ candidate: NSWindow?, to root: NSWindow) -> Bool {
        var window = candidate
        while let current = window {
            if current === root { return true }
            window = current.parent ?? current.sheetParent
        }
        return false
    }
}
