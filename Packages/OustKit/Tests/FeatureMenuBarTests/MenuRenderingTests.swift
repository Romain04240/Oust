import AppKit
import Testing
@testable import FeatureMenuBar

@Suite("Menu status rendering", .serialized)
@MainActor
struct MenuRenderingTests {
    @Test("Pressing the custom pill adds no native highlight mask")
    func highlight() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
        MenuBarController.configureAppearance(button)
        let cell = try #require(button.cell as? NSButtonCell)
        cell.isHighlighted = true
        #expect(cell.highlightsBy.isEmpty)
        #expect(cell.showsStateBy.isEmpty)
        #expect(!button.isBordered)
    }

    @Test("Storage stays colored in both appearances")
    func colors() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let icon = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { bounds in
                    NSColor.white.setFill()
                    bounds.fill()
                    return true
                }
                icon.isTemplate = true
                let badge = MenuBarBadge.storage(icon: icon, value: "300 GB")
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(badge.size.width),
                                              pixelsHigh: Int(badge.size.height), bitsPerSample: 8,
                                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                badge.draw(in: NSRect(origin: .zero, size: badge.size))
                NSGraphicsContext.restoreGraphicsState()
                let pixel = bitmap.colorAt(x: 9, y: Int(badge.size.height / 2))!.usingColorSpace(.deviceRGB)!
                #expect(max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
                        - min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) > 0.1)
            }
        }
    }
}
