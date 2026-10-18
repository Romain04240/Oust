import SwiftUI
import OustCore
import OustLocalization

/// La jauge de disque (IDENTITE §5) : l'anneau de l'icône, mais vivant.
///
/// Départ à midi, sens horaire : les catégories de la plus grande à la plus
/// petite, puis « Autres », puis le panier (en Éclat, détaché), puis l'espace
/// libre — la piste seule. Le panier touche ainsi l'espace libre, qui s'agrandit
/// d'un bloc quand on le chasse.
public struct DiskGauge: View {
    public struct Segment: Identifiable, Sendable {
        public let id: String
        public let value: Int64
        public let color: Color

        public init(id: String, value: Int64, color: Color) {
            self.id = id
            self.value = value
            self.color = color
        }
    }

    let segments: [Segment]
    let cart: Int64
    let capacity: Capacity
    let beat: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kick = false

    public init(segments: [Segment], cart: Int64, capacity: Capacity, beat: Int = 0) {
        self.segments = segments
        self.cart = cart
        self.capacity = capacity
        self.beat = beat
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = size / 2
            let arcs = layout(radius: radius)
            ZStack {
                // La piste : l'anneau complet, en verre fumé.
                AnnularSector(start: 0, end: .pi * 2, innerRatio: 0.54)
                    .fill(Color.black.opacity(0.35))
                ForEach(arcs) { arc in
                    AnnularSector(start: arc.start, end: arc.end, innerRatio: 0.54,
                                  cornerRadius: radius * 0.094, detach: arc.isCart ? radius * 0.08 : 0)
                        .fill(arc.isCart ? AnyShapeStyle(Palette.eclat)
                              : AnyShapeStyle(LinearGradient(colors: [arc.color, arc.color.mix(with: .black, by: 0.15)],
                                                             startPoint: .top, endPoint: .bottom)))
                        .overlay(
                            AnnularSector(start: arc.start, end: arc.end, innerRatio: 0.54,
                                          cornerRadius: radius * 0.094, detach: arc.isCart ? radius * 0.08 : 0)
                                .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                        )
                        .shadow(color: arc.isCart ? Palette.eclatSolid.opacity(0.6) : arc.color.opacity(0.45), radius: 10)
                        .scaleEffect(arc.isCart && kick ? 1.04 : 1)
                }
                VStack(spacing: 2) {
                    Text(verbatim: Formatters.compactBytes(capacity.available))
                        .font(.system(size: size * 0.13, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText(value: Double(capacity.available)))
                    Text(verbatim: L10n.string("gauge.free_of", Formatters.compactBytes(capacity.total)))
                        .font(.system(size: max(10, size * 0.045), weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.25), value: arcs.map(\.end))
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: beat) {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.08)) { kick = true }
            withAnimation(.easeIn(duration: 0.08).delay(0.08)) { kick = false }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: L10n.string("gauge.accessibility", Formatters.compactBytes(capacity.available),
                                                       Formatters.compactBytes(capacity.total), Formatters.compactBytes(cart))))
    }

    struct Arc: Identifiable {
        let id: String
        let start: Double
        let end: Double
        let color: Color
        let isCart: Bool
    }

    /// Les angles de chaque segment, joints compris.
    ///
    /// Le joint a une largeur constante (0,065 R), pas un angle constant : sur
    /// l'icône comme ici, il paraît égal partout. Un segment trop petit pour être
    /// vu rejoint « Autres ».
    func layout(radius: CGFloat) -> [Arc] {
        let total = Double(max(1, capacity.total))
        let mid = Double(radius) * 0.77
        let gap = Double(radius) * 0.065 / mid
        let minimum = max(gap * 2.2, 9.6 * .pi / 180)

        let cartValue = min(Double(cart), Double(capacity.used))
        var shown: [(String, Double, Color, Bool)] = []
        var hidden = 0.0
        var categoriesTotal = 0.0
        for segment in segments.sorted(by: { $0.value > $1.value }) {
            let angle = Double(segment.value) / total * .pi * 2
            categoriesTotal += Double(segment.value)
            if angle >= minimum { shown.append((segment.id, angle, segment.color, false)) } else { hidden += angle }
        }
        let others = max(0, Double(capacity.used) - categoriesTotal - cartValue) / total * .pi * 2 + hidden
        if others > gap { shown.append(("others", others, Color(hex: 0xD9D4EC), false)) }
        let cartAngle = cartValue / total * .pi * 2
        if cartAngle > 0 { shown.append(("cart", max(cartAngle, minimum), .clear, true)) }

        var arcs: [Arc] = []
        var cursor = -Double.pi / 2
        for (id, angle, color, isCart) in shown {
            let start = cursor + gap / 2
            let end = max(start + 0.001, cursor + angle - gap / 2)
            arcs.append(Arc(id: id, start: start, end: end, color: color, isCart: isCart))
            cursor += angle
        }
        return arcs
    }
}

/// Un secteur d'anneau aux coins arrondis, qu'on peut détacher vers l'extérieur.
struct AnnularSector: Shape {
    var start: Double
    var end: Double
    var innerRatio: CGFloat
    var cornerRadius: CGFloat = 0
    var detach: CGFloat = 0

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let bisector = (start + end) / 2
        let center = CGPoint(x: rect.midX + cos(bisector) * detach, y: rect.midY + sin(bisector) * detach)
        let span = end - start
        // Les coins ne doivent pas se chevaucher sur un petit segment.
        let corner = min(cornerRadius, (outer - inner) / 2.2, CGFloat(span) * inner / 2.2)
        var path = Path()
        guard span > 0 else { return path }
        if span >= .pi * 2 - 0.001 {
            path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            return path.normalized(eoFill: true)
        }
        let outerInset = Double(corner / outer)
        let innerInset = Double(corner / inner)
        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        path.move(to: point(outer - corner, start))
        path.addQuadCurve(to: point(outer, start + outerInset), control: point(outer, start))
        path.addArc(center: center, radius: outer, startAngle: .radians(start + outerInset),
                    endAngle: .radians(end - outerInset), clockwise: false)
        path.addQuadCurve(to: point(outer - corner, end), control: point(outer, end))
        path.addLine(to: point(inner + corner, end))
        path.addQuadCurve(to: point(inner, end - innerInset), control: point(inner, end))
        path.addArc(center: center, radius: inner, startAngle: .radians(end - innerInset),
                    endAngle: .radians(start + innerInset), clockwise: true)
        path.addQuadCurve(to: point(inner + corner, start), control: point(inner, start))
        path.closeSubpath()
        return path
    }
}
