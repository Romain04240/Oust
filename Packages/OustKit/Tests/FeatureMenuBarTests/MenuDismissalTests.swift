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
}
