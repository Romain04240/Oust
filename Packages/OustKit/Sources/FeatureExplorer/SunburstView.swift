import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustScan
import OustSunburst

/// La vue soleil de l'Explorateur (SPEC §10, phase 2) : le dossier ouvert au
/// centre, ses enfants en anneaux. Un clic sur un dossier y entre, un clic au
/// centre remonte.
///
/// Couleurs : chaque branche de premier niveau prend la lueur d'une section
/// (IDENTITE §3), qui tient 3:1 sur la piste ; plus on descend, plus elle
/// s'éclaircit. Ce qui est trop fin pour un trait à soi prend le gris lavande
/// « Autres » de la jauge (IDENTITE §5). La légende redonne chaque valeur en
/// texte : la couleur ne porte jamais seule l'information.
struct SunburstView: View {
    let focus: TreeNode
    let model: AppModel
    /// Entrer dans un dossier (ou remonter) : l'Explorateur garde un seul dossier
    /// ouvert, que l'arborescence et le soleil partagent.
    let open: (TreeNode) -> Void

    @State private var layout: SunburstLayout?
    @State private var hoveredID: String?
    @State private var selectedID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let rings = 4
    /// Joint entre deux segments, de largeur constante comme sur la jauge.
    static let joint: CGFloat = 1.5

    /// Le focus peut changer avant son `onChange` : aucun secteur de l'ancien
    /// dossier ne doit être interprété avec les coordonnées du nouveau.
    private var displayedLayout: SunburstLayout? {
        guard let layout, layout.root === focus else { return nil }
        return layout
    }

    var body: some View {
        // 260 pt au plus petit : à 1080 × 720, il reste moins de 360 pt sous les
        // onglets, et un minimum de 360 faisait remonter toute la section et
        // sortir la carte par le bas de la fenêtre.
        HStack(alignment: .top, spacing: Spacing.large) {
            chart
                .frame(minWidth: 260, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            Legend(layout: displayedLayout, focus: focus, model: model, highlighted: hoveredID ?? selectedID, open: enter)
                .frame(width: 320)
        }
        .onAppear { relayout() }
        .onChange(of: ObjectIdentifier(focus)) { relayout() }
    }

    private func relayout() {
        layout = SunburstLayout(root: focus, rings: Self.rings)
        hoveredID = nil
        selectedID = nil
    }

    private func enter(_ node: TreeNode) {
        open(node)
    }

    // MARK: Dessin

    private var chart: some View {
        GeometryReader { proxy in
            let geometry = Geometry(size: proxy.size, rings: Self.rings)
            ZStack {
                drawing(geometry: geometry)
                Center(focus: focus, hovered: hovered, canGoUp: focus.parent != nil, diameter: geometry.hole * 2)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: L10n.string("sunburst.accessibility", focus.name,
                                                           Formatters.compactBytes(focus.total.allocated))))
            .accessibilityAction(named: Text("sunburst.go_up", bundle: .oust)) {
                if let parent = focus.parent { enter(parent) }
            }
        }
    }

    @ViewBuilder private func drawing(geometry: Geometry) -> some View {
        let canvas = Canvas { context, _ in
            if let layout = displayedLayout { draw(layout, geometry: geometry, in: &context) }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoveredID = displayedLayout?.segment(at: point, center: geometry.center, holeRadius: geometry.hole,
                                                     ringWidth: geometry.ringWidth)?.id
            case .ended:
                hoveredID = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            tap(at: value.location, geometry: geometry)
        })
        if reduceMotion {
            canvas
        } else {
            // Un seul dessin : un fondu croisé laisserait d'anciens secteurs
            // visibles alors que le clic vise déjà le nouveau dossier.
            canvas.keyframeAnimator(initialValue: CGFloat(1), trigger: layout.map { ObjectIdentifier($0.root) }) { content, opacity in
                content.opacity(Double(opacity)).allowsHitTesting(opacity > 0)
            } keyframes: { _ in
                MoveKeyframe(CGFloat(0))
                LinearKeyframe(CGFloat(1), duration: 0.25)
            }
        }
    }

    private var hovered: SunburstSegment? {
        guard let id = hoveredID else { return nil }
        return displayedLayout?.segments.first { $0.id == id }
    }

    private func tap(at point: CGPoint, geometry: Geometry) {
        guard let layout = displayedLayout else { return }
        let distance = hypot(point.x - geometry.center.x, point.y - geometry.center.y)
        if distance < geometry.hole {
            if let parent = focus.parent { enter(parent) }
            return
        }
        guard let segment = layout.segment(at: point, center: geometry.center, holeRadius: geometry.hole,
                                           ringWidth: geometry.ringWidth) else { return }
        if let node = segment.node, !node.children.isEmpty || !node.files.isEmpty {
            enter(node)
        } else {
            selectedID = segment.id
        }
    }

    private func draw(_ layout: SunburstLayout, geometry: Geometry, in context: inout GraphicsContext) {
        let center = geometry.center
        // La piste : l'anneau complet en verre fumé, 35 % de noir (IDENTITE §5).
        var track = Path()
        track.addArc(center: center, radius: geometry.outer, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        track.addArc(center: center, radius: geometry.hole, startAngle: .degrees(360), endAngle: .zero, clockwise: true)
        context.fill(track, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))

        let highlighted = hoveredID ?? selectedID
        for segment in layout.segments {
            let inner = geometry.hole + CGFloat(segment.depth - 1) * geometry.ringWidth + Self.joint / 2
            let outer = inner + geometry.ringWidth - Self.joint
            guard let path = Self.arc(center: center, inner: inner, outer: outer, start: segment.start, end: segment.end) else {
                continue
            }
            var color = Self.color(for: segment)
            if segment.id == highlighted { color = color.mix(with: .white, by: 0.35) }
            context.fill(path, with: .color(color))
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.75)
        }
    }

    /// Un secteur d'anneau, avec des joints de largeur constante : l'angle retiré
    /// de chaque côté dépend du rayon.
    static func arc(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double) -> Path? {
        let startAngle = start * 2 * .pi - .pi / 2
        let endAngle = end * 2 * .pi - .pi / 2
        let trimOuter = Double(joint / 2 / outer)
        let trimInner = Double(joint / 2 / max(inner, 1))
        guard endAngle - startAngle > 2 * trimInner else { return nil }
        // Un segment qui fait tout le tour se dessine sans joint.
        let full = end - start > 0.9999
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(startAngle + (full ? 0 : trimOuter)),
                    endAngle: .radians(endAngle - (full ? 0 : trimOuter)), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(endAngle - (full ? 0 : trimInner)),
                    endAngle: .radians(startAngle + (full ? 0 : trimInner)), clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Les lueurs des sections (IDENTITE §3), en commençant par celle de l'Explorateur.
    static let branchColors: [Color] = [
        Color(hex: 0x4FC3FF), Color(hex: 0x9E8CFF), Color(hex: 0x3EE0A8), Color(hex: 0xFF8A4C),
        Color(hex: 0xFF6FB8), Color(hex: 0x8FA2FF), Color(hex: 0xFFB547),
    ]

    /// « Autres » sur la jauge (IDENTITE §5).
    static let others = Color(hex: 0xD9D4EC)

    static func color(for segment: SunburstSegment) -> Color {
        guard let branch = segment.branch else {
            if case .smallFiles = segment.kind { return others.opacity(0.7) }
            return others
        }
        let base = branchColors[branch % branchColors.count]
        return base.mix(with: .white, by: min(0.45, 0.13 * Double(segment.depth - 1)))
    }

    struct Geometry {
        let center: CGPoint
        let outer: CGFloat
        let hole: CGFloat
        let ringWidth: CGFloat

        init(size: CGSize, rings: Int) {
            let side = min(size.width, size.height)
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            outer = max(40, side / 2 - Spacing.small)
            hole = outer * 0.3
            ringWidth = (outer - hole) / CGFloat(rings)
        }
    }
}

// MARK: - Centre

private struct Center: View {
    let focus: TreeNode
    let hovered: SunburstSegment?
    let canGoUp: Bool
    /// Le diamètre du trou : le texte s'y règle.
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Le texte suit la taille du trou, une ligne par information. À 1080 pt
        // de fenêtre, le trou ne fait qu'une centaine de points : un titre fixe
        // de 28 pt y coupait « 165 Go » en « 165 G / o », et le nom du dossier
        // au milieu d'un mot.
        VStack(spacing: Spacing.hair) {
            Text(verbatim: hovered.map(SunburstText.name) ?? focus.name)
                .font(.system(size: min(13, max(11, diameter * 0.11)), weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
            Text(verbatim: Formatters.compactBytes(hovered?.bytes ?? focus.total.allocated))
                .font(.system(size: min(28, max(15, diameter * 0.17)), weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Les chiffres qui défilent sont un mouvement : un fondu à la place
                // quand « Réduire les animations » est actif (RULES.md, règle 14).
                .contentTransition(reduceMotion ? .opacity : .numericText())
            if let hovered, focus.total.allocated > 0 {
                Text(verbatim: Formatters.percent(Double(hovered.bytes) / Double(focus.total.allocated)))
                    .font(Typography.caption.monospacedDigit())
            } else if canGoUp {
                Label { Text("sunburst.go_up", bundle: .oust) } icon: { Image(systemName: "chevron.up") }
                    .font(Typography.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: diameter * 0.8)
        .foregroundStyle(Palette.onGradient)
    }
}

/// Les mots d'un segment, partagés par le centre et la légende.
enum SunburstText {
    static func name(_ segment: SunburstSegment) -> String {
        switch segment.kind {
        case .directory, .file: segment.name
        case .smallFiles(let count): L10n.string("sunburst.small_files", Formatters.count(count))
        case .others(let count): L10n.string("sunburst.others", Formatters.count(count))
        }
    }
}

// MARK: - Légende

private struct Legend: View {
    let layout: SunburstLayout?
    let focus: TreeNode
    let model: AppModel
    let highlighted: String?
    let open: (TreeNode) -> Void

    var body: some View {
        let ring = layout?.segments.filter { $0.depth == 1 } ?? []
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let id = highlighted, let segment = layout?.segments.first(where: { $0.id == id }) {
                Detail(segment: segment, focus: focus, model: model)
                Divider().opacity(0.4)
            }
            Text("sunburst.legend", bundle: .oust).font(Typography.caption.weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(ring) { segment in
                        Button {
                            if let node = segment.node { open(node) }
                        } label: {
                            HStack(spacing: Spacing.small) {
                                RoundedRectangle(cornerRadius: 3).fill(SunburstView.color(for: segment))
                                    .frame(width: 12, height: 12)
                                Text(verbatim: SunburstText.name(segment)).lineLimit(1).truncationMode(.middle)
                                    .minimumScaleFactor(0.85)
                                Spacer()
                                Text(verbatim: Formatters.percent(segment.span)).font(Typography.caption.monospacedDigit())
                                Text(verbatim: Formatters.compactBytes(segment.bytes)).font(Typography.size)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, Spacing.hair)
                            .background(segment.id == highlighted ? Color.white.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: Radius.small))
                        }
                        .buttonStyle(.plain)
                        .disabled(segment.node == nil)
                    }
                }
            }
        }
        .padding(Spacing.large)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// Le segment survolé ou choisi : où il est, ce qu'il pèse, et de quoi le jeter.
private struct Detail: View {
    let segment: SunburstSegment
    let focus: TreeNode
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(verbatim: SunburstText.name(segment)).font(Typography.headline).lineLimit(2)
            Text(verbatim: segment.path).font(.system(size: 10, design: .monospaced)).lineLimit(2)
                .truncationMode(.middle).textSelection(.enabled)
            HStack {
                Text(verbatim: Formatters.compactBytes(segment.bytes)).font(Typography.size)
                if focus.total.allocated > 0 {
                    Text(verbatim: L10n.string("sunburst.share", Formatters.percent(Double(segment.bytes) / Double(focus.total.allocated)),
                                               focus.name))
                        .font(Typography.caption)
                }
            }
            if let item {
                // Côte à côte s'ils tiennent, l'un sous l'autre sinon : dans les
                // 288 pt de la légende, « Afficher dans le Finder » était coupé.
                ViewThatFits(in: .horizontal) {
                    HStack { actions(for: item) }
                    VStack(alignment: .leading) { actions(for: item) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func actions(for item: CleanupItem) -> some View {
        Button { model.toggle(item) } label: {
            Label { Text(model.isInCart(item.id) ? "row.remove_from_cart" : "row.add_to_cart", bundle: .oust) }
                icon: { Image(systemName: "trash") }
                .lineLimit(1)
        }
        .fixedSize()
        .disabled(!model.canSelectForCleanup(item))
        Button { NSWorkspace.shared.activateFileViewerSelecting(item.paths) } label: {
            Label { Text("row.reveal", bundle: .oust) } icon: { Image(systemName: "folder") }
                .lineLimit(1)
        }
        .fixedSize()
    }

    /// L'élément de la corbeille d'Oust! que représente le segment, s'il en est un.
    private var item: CleanupItem? {
        switch segment.kind {
        case .directory:
            return segment.node.map(model.item(for:))
        case .file:
            let parentPath = (segment.path as NSString).deletingLastPathComponent
            guard let parent = focus.node(at: parentPath),
                  let leaf = parent.files.first(where: { $0.name == segment.name }) else { return nil }
            return model.item(for: leaf, in: parent)
        case .smallFiles, .others:
            return nil
        }
    }
}
