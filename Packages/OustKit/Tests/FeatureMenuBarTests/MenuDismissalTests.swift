import AppKit
import Testing
@testable import FeatureMenuBar

@Suite("Outside menu clicks", .serialized)
@MainActor
struct MenuDismissalTests {
    @Test("Clicks inside, in a child window and on status icons keep their native behavior")
    func nativeClicks() throws {
        let application = NSApplication.shared
        let root = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let child = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 100, height: 100),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 500, y: 100, width: 200, height: 200),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        root.addChildWindow(child, ordered: .above)
        defer { root.removeChildWindow(child); root.orderOut(nil); child.orderOut(nil); other.orderOut(nil) }
        let monitor = MenuDismissalMonitor()
        defer { monitor.stop() }
        var closed = 0
        monitor.start(window: root, statusRects: { [NSRect(x: 500, y: 100, width: 40, height: 30)] }, close: { closed += 1 })
        func send(_ window: NSWindow, _ point: NSPoint, type: NSEvent.EventType = .leftMouseDown) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            application.sendEvent(event)
        }
        try send(root, NSPoint(x: 10, y: 10))
        try send(child, NSPoint(x: 10, y: 10))
        try send(other, NSPoint(x: 10, y: 10)) // Status icon's screen rectangle.
        #expect(closed == 0)
        try send(other, NSPoint(x: 100, y: 100), type: .rightMouseDown)
        #expect(closed == 1)
        monitor.stop()
        try send(other, NSPoint(x: 100, y: 100))
        #expect(closed == 1)
    }

    @Test("Reopening replaces the observers; stopped presentations cannot close the next one")
    func lifecycle() {
        let app = NSApplication.shared
        let root = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let monitor = MenuDismissalMonitor()
        var old = 0, current = 0
        monitor.start(window: root, statusRects: { [] }, close: { old += 1 })
        monitor.start(window: root, statusRects: { [] }, close: { current += 1 })
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        #expect(old == 0 && current == 1)
        monitor.stop()
        monitor.stop()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        #expect(old == 0 && current == 1)
    }

    @Test("Global clicks use the recorded position after the pointer returns to the panel")
    func recordedGlobalPosition() throws {
        _ = NSApplication.shared
        let pointer = NSEvent.mouseLocation
        let root = NSWindow(contentRect: NSRect(x: pointer.x - 200, y: pointer.y - 150, width: 400, height: 300),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { root.orderOut(nil) }
        let storage = NSRect(x: root.frame.maxX + 100, y: root.frame.minY, width: 40, height: 24)
        let battery = storage.offsetBy(dx: 60, dy: 0)
        var handlers: [(NSEvent) -> Void] = []
        let monitor = MenuDismissalMonitor(installGlobalMonitor: { _, handler in
            handlers.append(handler)
            return nil // No system-wide input is installed or posted by this fixture.
        })
        defer { monitor.stop() }
        var closed = 0
        monitor.start(window: root, statusRects: { [storage, battery] }, close: { closed += 1 })
        let handler = try #require(handlers.first)
        func recordedClick(_ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        // The event was outside; the real pointer is now where the panel was
        // positioned. Invoking the actual registered handler must still close.
        try handler(recordedClick(NSPoint(x: root.frame.maxX + 300, y: root.frame.maxY + 100)))
        #expect(closed == 1)
        // Inside clicks and each actual status icon retain their exclusions,
        // regardless of the current pointer position.
        for rect in [root.frame, storage, battery] {
            try handler(recordedClick(NSPoint(x: rect.midX, y: rect.midY)))
            #expect(closed == 1)
        }
    }

    @Test("Queued global clicks from a stopped presentation cannot close a reopened panel")
    func delayedGlobalLifecycle() throws {
        _ = NSApplication.shared
        let root = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { root.orderOut(nil) }
        var handlers: [(NSEvent) -> Void] = []
        let monitor = MenuDismissalMonitor(installGlobalMonitor: { _, handler in
            handlers.append(handler)
            return nil
        })
        defer { monitor.stop() }
        var old = 0, current = 0
        monitor.start(window: root, statusRects: { [] }, close: { old += 1 })
        monitor.start(window: root, statusRects: { [] }, close: { current += 1 })
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 600, y: 500),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let oldHandler = try #require(handlers.first), currentHandler = try #require(handlers.last)
        oldHandler(event)
        #expect(old == 0 && current == 0)
        currentHandler(event)
        #expect(old == 0 && current == 1)
        monitor.stop()
        currentHandler(event)
        #expect(old == 0 && current == 1)
    }
}
