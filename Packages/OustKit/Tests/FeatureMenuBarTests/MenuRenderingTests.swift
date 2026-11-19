import AppKit
import SwiftUI
import OustWatch
import OustCore
import Testing
@testable import FeatureMenuBar
@testable import OustModel

@Suite("Menu status rendering", .serialized)
@MainActor
struct MenuRenderingTests {
    private func raster(_ image: NSImage) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width),
            pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.clear(CGRect(origin: .zero, size: image.size))
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    @Test("Indicators have no colored container and adapt to charge level", arguments: [0, 10, 20, 40, 100])
    func transparentIndicators(level: Int) {
        let reading = BatteryReading(level: level, state: .onBattery)
        for style in WatchSettings.BatteryPercentageStyle.allCases {
            let image = MenuBarBadge.battery(reading, percentage: "\(level)%", style: style)
            let pixels = raster(image)
            #expect((pixels.colorAt(x: 1, y: 1)?.alphaComponent ?? 1) < 0.01)
            #expect(image.size.width > 25)
            let edge = pixels.colorAt(x: 7, y: Int(image.size.height / 2))!.usingColorSpace(.deviceRGB)!
            if level <= 20 {
                #expect(edge.redComponent > edge.greenComponent)
            } else if level <= 40 {
                #expect(edge.greenComponent > edge.blueComponent)
            } else {
                #expect(edge.greenComponent > edge.redComponent)
            }
        }
        let storage = MenuBarBadge.storage(icon: NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)!, value: "300 GB")
        #expect((raster(storage).colorAt(x: 1, y: 1)?.alphaComponent ?? 1) < 0.01)
    }

    @Test("Inline percentage stays compact and missing readings stay distinct")
    func inlinePercentage() {
        let reading = BatteryReading(level: 100, state: .charged)
        let inside = MenuBarBadge.battery(reading, percentage: "100%", style: .inside)
        let beside = MenuBarBadge.battery(reading, percentage: "100%", style: .beside)
        #expect(inside.size.width < beside.size.width)
        let missing = raster(MenuBarBadge.battery(nil, percentage: nil, style: .inside)).tiffRepresentation
        let empty = raster(MenuBarBadge.battery(BatteryReading(level: 0, state: .onBattery), percentage: "0%", style: .inside)).tiffRepresentation
        #expect(missing != empty)
    }

    @Test("Percentage setting preserves old preferences and survives reload")
    func percentageSettings() throws {
        var settings = WatchSettings.decode(Data(#"{"alertsLowDisk":false,"batteryTemperatureUnit":"fahrenheit"}"#.utf8))
        #expect(settings.batteryPercentageStyle == .beside)
        settings.batteryPercentageStyle = .inside
        let restored = WatchSettings.decode(settings.encoded())
        #expect(restored.batteryPercentageStyle == .inside)
        #expect(!restored.alertsLowDisk)
        #expect(restored.batteryTemperatureUnit == .fahrenheit)
        let unknown = WatchSettings.decode(Data(#"{"alertsLowDisk":false,"batteryPercentageStyle":"future"}"#.utf8))
        #expect(unknown.batteryPercentageStyle == .beside)
        #expect(!unknown.alertsLowDisk)
    }
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

    @Test("Actual viewport placement does not fill the previous page's taller proposal")
    func placementAfterTallProposal() {
        var measured = CGSize.zero
        let root = MenuPanelViewport(maximumHeight: 800) {
            Color.clear.frame(height: 80)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
        .frame(width: 360, height: 600, alignment: .topLeading)
        let host = NSHostingView(rootView: root)
        host.setFrameSize(NSSize(width: 360, height: 600))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(abs(measured.height - 80) < 1)
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
    @Test("Storage warning and plugged-in charged state remain visible")
    func stateSymbols() {
        let icon = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)!
        let normal = MenuBarBadge.storage(icon: icon, value: "10 GB")
        let low = MenuBarBadge.storage(icon: icon, value: "10 GB", isLow: true)
        #expect(low.size.width > normal.size.width)
        #expect(raster(low).tiffRepresentation != raster(normal).tiffRepresentation)
        for style in [WatchSettings.BatteryPercentageStyle.inside, .beside] {
            let charged = MenuBarBadge.battery(BatteryReading(level: 100, state: .charged), percentage: "100%", style: style)
            let disconnected = MenuBarBadge.battery(BatteryReading(level: 100, state: .onBattery), percentage: "100%", style: style)
            #expect(charged.size.width > disconnected.size.width)
        }
    }

    @Test("Animated storage content keeps the same compact natural height")
    func storageHeightWithAnimation() {
        let root = URL(fileURLWithPath: "/oust-fixture-volume", isDirectory: true)
        let volume = VolumeDescriptor(name: "Test disk", mountURL: root, scanRoot: root, isBoot: true,
            isInternal: true, isRemovable: false, capacity: Capacity(total: 1_000_000_000, available: 300_000_000, availableForImportantUsage: 400_000_000))
        func view(_ active: Bool) -> some View {
            MenuPanelViewport(maximumHeight: 800) {
                VolumeLine(volume: volume, isLow: false, presented: active, quit: {}, open: {})
            }.padding(16).frame(width: MenuBarPanel.width)
        }
        let host = NSHostingView(rootView: view(false))
        let still = host.fittingSize.height
        host.rootView = view(true)
        let animated = host.fittingSize.height
        #expect(still > 100 && still < 400)
        #expect(abs(animated - still) < 1)
        host.rootView = view(false)
        #expect(abs(host.fittingSize.height - still) < 1)
    }

    @Test("The complete storage panel returns to its natural size after a taller page")
    func fullStoragePanelHeight() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oust-menu-\(UUID().uuidString)")
        let model = AppModel(home: root, defaults: MenuMemoryDefaults())
        model.volumes = [VolumeDescriptor(name: "Test disk", mountURL: root, scanRoot: root, isBoot: true,
            isInternal: true, isRemovable: false, capacity: Capacity(total: 1_000_000_000, available: 300_000_000, availableForImportantUsage: 400_000_000))]
        let navigation = MenuBarNavigation()
        navigation.height = 850
        let host = NSHostingController(rootView: MenuBarPanel(model: model, navigation: navigation))
        host.sizingOptions = .preferredContentSize
        host.view.setFrameSize(NSSize(width: MenuBarPanel.width, height: 800))
        host.view.layoutSubtreeIfNeeded()
        let natural = host.view.fittingSize
        #expect(natural.height > 250 && natural.height < 450)
        host.view.setFrameSize(natural)
        host.view.layoutSubtreeIfNeeded()
        #expect(abs(host.view.fittingSize.height - natural.height) < 1)
    }

}

private final class MenuMemoryDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func data(forKey defaultName: String) -> Data? { nil }
    override func stringArray(forKey defaultName: String) -> [String]? { nil }
    override func bool(forKey defaultName: String) -> Bool { false }
    override func set(_ value: Any?, forKey defaultName: String) {}
}
