import AppKit
import OustWatch

@MainActor
enum MenuBarBadge {
    private static var height: CGFloat { max(20, NSStatusBar.system.thickness - 2) }
    private static let padding: CGFloat = 7
    private static let gap: CGFloat = 5

    static func storage(icon: NSImage, value: String?) -> NSImage {
        let glyphWidth: CGFloat = 15
        return pill(glyphWidth: glyphWidth, value: value, tint: .systemGreen,
                    fillOpacity: 0.22, borderOpacity: 0.38) { x in
            let rect = NSRect(x: x, y: (height - glyphWidth) / 2, width: glyphWidth, height: glyphWidth)
            drawTinted(icon, in: rect, tint: .systemGreen)
        }
    }

    static func battery(_ reading: BatteryReading?, percentage: String?) -> NSImage {
        let tint: NSColor = switch reading {
        case .none: .secondaryLabelColor
        case .some(let reading):
            switch (reading.state, reading.level) {
            case (.onBattery, ...10): .systemRed
            case (.onBattery, ...20): .systemOrange
            case (.onBattery, ...40): .systemYellow
            case (.onAC, _): .systemTeal
            default: .systemGreen
            }
        }
        let source: String? = switch reading?.state {
        case .charging: "bolt.fill"
        case .onAC: "powerplug.fill"
        default: nil
        }
        let glyphWidth: CGFloat = source == nil ? 24 : 38
        return pill(glyphWidth: glyphWidth, value: percentage, tint: tint,
                    fillOpacity: 0.22, borderOpacity: 0.38) { x in
            let center = height / 2
            let body = NSRect(x: x, y: center - 5.5, width: 21, height: 11)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
            tint.setStroke()
            outline.lineWidth = 1.25
            outline.stroke()
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 1.5, y: center - 2, width: 1.5, height: 4),
                         xRadius: 0.75, yRadius: 0.75).fill()
            if let reading, reading.level > 0 {
                let fill = body.insetBy(dx: 2.1, dy: 2.1)
                let fraction = CGFloat(min(100, reading.level)) / 100
                let charge = NSRect(x: fill.minX, y: fill.minY, width: fill.width * fraction, height: fill.height)
                tint.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: charge, xRadius: min(1.5, charge.width / 2), yRadius: 1.5).fill()
            } else if reading == nil {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: body.midX - 2, y: center - 3))
                slash.line(to: NSPoint(x: body.midX + 2, y: center + 3))
                slash.lineWidth = 1.2
                slash.stroke()
            }
            if let source, let symbol = NSImage(systemSymbolName: source, accessibilityDescription: nil) {
                drawTinted(symbol, in: NSRect(x: x + 28, y: center - 5, width: 10, height: 10), tint: tint)
            }
        }
    }

    private static func pill(glyphWidth: CGFloat, value: String?, tint: NSColor,
                             fillOpacity: CGFloat, borderOpacity: CGFloat,
                             drawGlyph: @escaping (CGFloat) -> Void) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = value.map { NSAttributedString(string: $0, attributes: attributes) }
        let textSize = text?.size() ?? .zero
        let width = padding * 2 + glyphWidth + (text == nil ? 0 : gap + ceil(textSize.width))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { bounds in
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                     xRadius: height / 2, yRadius: height / 2)
            tint.withAlphaComponent(fillOpacity).setFill()
            shape.fill()
            tint.withAlphaComponent(borderOpacity).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            drawGlyph(padding)
            text?.draw(at: NSPoint(x: padding + glyphWidth + gap, y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        // Reuse the raster while the sample is unchanged. The controller
        // recreates it when the button's effective appearance changes.
        image.cacheMode = .bySize
        return image
    }

    private static func drawTinted(_ image: NSImage, in rect: NSRect, tint: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        context.saveGState()
        context.setBlendMode(.sourceIn)
        context.setFillColor(tint.cgColor)
        context.fill(rect)
        context.restoreGState()
        context.endTransparencyLayer()
    }
}

/// Keep NSStatusBarButton's event handling and accessibility, but draw only
/// Oust's image. The system status-cell bezel ignores its highlight mask on
/// some macOS versions and otherwise adds a second glass capsule.
@MainActor
final class MenuBarBadgeCell: NSButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let image else { return }
        let rect = NSRect(x: cellFrame.midX - image.size.width / 2,
                          y: cellFrame.midY - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
}
