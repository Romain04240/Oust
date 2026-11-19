import AppKit

/// NSPopover's transient behavior alone does not dismiss reliably when Oust
/// was already inactive. Observe clicks only while this presentation is open.
@MainActor
final class MenuDismissalMonitor {
    private var local: Any?
    private var global: Any?
    private var inactive: (any NSObjectProtocol)?
    private var generation = UUID()

    isolated deinit { stop() }

    func start(window: NSWindow, statusRects: @escaping @MainActor () -> [NSRect],
               close: @escaping @MainActor () -> Void) {
        stop()
        let session = generation
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard let self, self.generation == session, let window else { return }
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
                if !Self.belongs(event.window, to: window), !statusRects().contains(where: { $0.contains(point) }) {
                    close()
                }
            }
            // Never swallow the click intended for a different window.
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == session, let window else { return }
                let point = NSEvent.mouseLocation
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
