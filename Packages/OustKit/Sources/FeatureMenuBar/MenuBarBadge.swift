import AppKit
import OustWatch

@MainActor
enum MenuBarBadge {
    private static var height: CGFloat { max(20, NSStatusBar.system.thickness - 2) }
    // macOS already spaces status items. Keep only enough image inset for
    // the battery outline and anti-aliasing, rather than padding it twice.
    private static let padding: CGFloat = 2
    private static let gap: CGFloat = 5

    static func storage(icon: NSImage, value: String?, isLow: Bool = false) -> NSImage {
        let glyphWidth: CGFloat = 15
        return pill(glyphWidth: glyphWidth + (isLow ? 15 : 0), value: value, tint: .systemPurple) { x in
            let rect = NSRect(x: x, y: (height - glyphWidth) / 2, width: glyphWidth, height: glyphWidth)
            drawTinted(icon, in: rect, tint: .systemPurple)
            if isLow, let warning = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) {
                drawTinted(warning, in: NSRect(x: x + glyphWidth + 3, y: (height - 12) / 2, width: 12, height: 12), tint: .systemOrange)
            }
        }
    }

    static func battery(_ reading: BatteryReading?, percentage: String?,
                        style: WatchSettings.BatteryPercentageStyle = .beside) -> NSImage {
        let tint: NSColor = switch reading {
        case .none: .secondaryLabelColor
        case .some(let reading):
            switch reading.level {
            case ...10: .systemRed
            case ...20: .systemOrange
            case ...40: .systemYellow
            default: reading.state == .onAC ? .systemTeal : .systemGreen
            }
        }
        let source: String? = switch reading?.state {
        case .charging, .charged: "bolt.fill"
        case .onAC: "powerplug.fill"
        default: nil
        }
        let bodyWidth: CGFloat = style == .inside ? 34 : 21
        let bodyHeight: CGFloat = style == .inside ? 14 : 11
        let glyphWidth: CGFloat = bodyWidth + (source == nil ? 3 : 17)
        return pill(glyphWidth: glyphWidth, value: style == .inside ? nil : percentage, tint: tint) { x in
            let center = height / 2
            let bodyX = x + (source == nil ? 0 : 14)
            let body = NSRect(x: bodyX, y: center - bodyHeight / 2, width: bodyWidth, height: bodyHeight)
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
                tint.withAlphaComponent(style == .inside ? 0.28 : 0.9).setFill()
                NSBezierPath(roundedRect: charge, xRadius: min(1.5, charge.width / 2), yRadius: 1.5).fill()
            } else if reading == nil {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: body.midX - 2, y: center - 3))
                slash.line(to: NSPoint(x: body.midX + 2, y: center + 3))
                slash.lineWidth = 1.2
                slash.stroke()
            }
            if style == .inside, let reading {
                let number = NSAttributedString(string: String(min(100, max(0, reading.level))), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                ])
                let size = number.size()
                number.draw(at: NSPoint(x: body.midX - size.width / 2, y: center - size.height / 2))
            }
            if let source, let symbol = NSImage(systemSymbolName: source, accessibilityDescription: nil) {
                drawTinted(symbol, in: NSRect(x: x, y: center - 5, width: 10, height: 10), tint: tint)
            }
        }
    }

    private static func pill(glyphWidth: CGFloat, value: String?, tint: NSColor,
                             drawGlyph: @escaping (CGFloat) -> Void) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = value.map { NSAttributedString(string: $0, attributes: attributes) }
        let textSize = text?.size() ?? .zero
        let width = padding * 2 + glyphWidth + (text == nil ? 0 : gap + ceil(textSize.width))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
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
