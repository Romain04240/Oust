import AppKit
import SwiftUI
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
        button.image = MenuBarBadge.storage(icon: NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)!, value: "300 GB")
        func pixels(highlighted: Bool) -> Data {
            cell.isHighlighted = highlighted
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 90, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current?.cgContext.clear(button.bounds)
            cell.draw(withFrame: button.bounds, in: button)
            NSGraphicsContext.restoreGraphicsState()
            return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        #expect(pixels(highlighted: false) == pixels(highlighted: true))
    }

    @Test("The panel returns to natural height after details collapse")
    func naturalHeight() {
        func root(_ height: CGFloat) -> some View {
            MenuPanelViewport(maximumHeight: 600) {
                Color.clear.frame(height: height)
            }.frame(width: 420)
        }
        let host = NSHostingView(rootView: root(80))
        #expect(abs(host.fittingSize.height - 80) < 1)
        host.rootView = root(240)
        #expect(abs(host.fittingSize.height - 240) < 1)
        host.rootView = root(80)
        #expect(abs(host.fittingSize.height - 80) < 1)
        host.rootView = root(900)
        #expect(host.fittingSize.height <= 600)
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
