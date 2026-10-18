import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// L'alerte disque bas en pastille, à la manière de Juicy pour la batterie
/// (Romain, 18/10/2026) : une pastille compacte qui flotte sous la barre des
/// menus, détachée du bord, dit l'essentiel en une ligne et repart seule. Le
/// détail est dans la vue d'ensemble, à un clic. Une notification de macOS
/// reste possible en option, dans les Réglages.
///
/// La pastille dit aussi autre chose que le disque bas : l'entretien planifié,
/// d'autres veilles ensuite. Elles passent un `CapsuleMessage` à `show(_:open:)` ;
/// une seule pastille à la fois, la dernière arrivée remplace la précédente.
///
/// Première version, refusée : une capsule raccrochée au bord de l'écran,
/// autour de l'encoche, sur trois lignes. « Trop grosse », et Juicy flotte.
///
/// Un `NSPanel` sans bordure et non activant : il passe au-dessus des fenêtres
/// sans jamais prendre le focus à l'app où l'on tape.
@MainActor
public final class CapsulePresenter {
    public static let shared = CapsulePresenter()

    private var panel: CapsulePanel?
    private let state = CapsuleState()

    /// Combien de temps la capsule reste, si on ne la survole pas.
    static let lifetime: Duration = .seconds(7)

    /// L'alerte disque bas.
    public func show(_ alert: LowDiskAlert, open: @escaping @MainActor () -> Void) {
        show(.lowDisk(alert), open: open)
    }

    /// N'importe quel message, sous la même forme ; `open` répond au clic.
    public func show(_ message: CapsuleMessage, open: @escaping @MainActor () -> Void) {
        let screen = Self.targetScreen()
        guard let screen else { return }
        let geometry = CapsuleGeometry(screen: screen)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        state.message = message
        state.onOpen = { [weak self] in
            open()
            self?.dismiss()
        }
        state.onDismiss = { [weak self] in self?.dismiss() }
        panel.setFrame(geometry.frame, display: true)
        panel.orderFrontRegardless()
        state.present(for: Self.lifetime)
        // VoiceOver n'a pas à deviner qu'une capsule vient d'apparaître.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message.announcement,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    public func dismiss() {
        state.withdraw { [weak self] in self?.panel?.orderOut(nil) }
    }

    private func makePanel() -> CapsulePanel {
        let panel = CapsulePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CapsuleView(state: state))
        return panel
    }

    /// L'écran où l'on regarde : celui de la souris, à défaut celui de la
    /// fenêtre active. Posée d'office sur l'écran à encoche, elle passait
    /// inaperçue de qui travaille sur un écran externe (18/10/2026).
    static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// Le panneau ne devient jamais fenêtre clé ni principale : il ne vole pas le focus.
final class CapsulePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Où poser la pastille : centrée, à un écart visible sous la barre des menus
/// et l'encoche, jamais accrochée au bord. Le panneau déborde un peu de la
/// pastille pour laisser place à l'ombre et au rebond, sans mordre sur la
/// barre des menus.
struct CapsuleGeometry {
    let frame: NSRect

    static let pillHeight: CGFloat = 46
    /// L'écart entre la barre des menus (ou le bas de l'encoche) et la pastille.
    static let gap: CGFloat = 12
    /// Au-dessus de la pastille, moins que l'écart : le panneau reste sous la barre.
    static let topMargin: CGFloat = 8
    static let sideMargin: CGFloat = 28
    static let width: CGFloat = 640

    init(screen: NSScreen) {
        let full = screen.frame
        let notch = screen.safeAreaInsets.top
        let bar = notch > 0 ? notch : max(0, full.maxY - screen.visibleFrame.maxY)
        let pillTop = full.maxY - bar - Self.gap
        let height = Self.topMargin + Self.pillHeight + Self.sideMargin
        frame = NSRect(x: full.midX - Self.width / 2, y: pillTop + Self.topMargin - height,
                       width: Self.width, height: height)
    }
}

/// L'état partagé entre le présentateur (AppKit) et la vue (SwiftUI).
@MainActor
@Observable
final class CapsuleState {
    var message: CapsuleMessage?
    var isShown = false
    var isHovered = false {
        didSet { if !isHovered, isShown { schedule(after: .seconds(3)) } }
    }
    @ObservationIgnored var onOpen: () -> Void = {}
    @ObservationIgnored var onDismiss: () -> Void = {}
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var removal: Task<Void, Never>?

    func present(for lifetime: Duration) {
        removal?.cancel()
        isShown = true
        schedule(after: lifetime)
    }

    private func schedule(after delay: Duration) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isHovered else { return }
            self.onDismiss()
        }
    }

    /// Repart, puis retire le panneau une fois l'animation finie.
    func withdraw(then remove: @escaping @MainActor () -> Void) {
        timer?.cancel()
        guard isShown else { return }
        isShown = false
        removal = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            remove()
        }
    }
}

/// La pastille elle-même, aux couleurs de l'icône (IDENTITE §2) : le fond
/// violet profond, et l'anneau en dégradé devenu le contour, qui sert de jauge.
/// Texte blanc (IDENTITE §4, règles 2 et 3), coins entièrement arrondis, ombre douce.
struct CapsuleView: View {
    @Bindable var state: CapsuleState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if let message = state.message {
                pill(message)
                    // Un fondu et un léger rebond ; avec Réduire les animations, le fondu seul.
                    .scaleEffect(reduceMotion || state.isShown ? 1 : 0.86, anchor: .top)
                    .opacity(state.isShown ? max(0, 1 + drag / 40) : 0)
                    .offset(y: min(0, drag))
                    .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.35),
                               value: state.isShown)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, CapsuleGeometry.topMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    /// Vers le haut, elle s'en va ; relâchée trop tôt, elle revient en place.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in drag = value.translation.height }
            .onEnded { value in
                if value.translation.height < -16 || value.predictedEndTranslation.height < -40 {
                    state.onDismiss()
                }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { drag = 0 }
            }
    }

    /// Une ligne. Pour le disque bas : « Espace disque » et le nom du disque,
    /// sans quoi on ne saurait pas lequel (Romain, 18/10/2026), l'espace libre ;
    /// ce qu'Oust! peut rendre sans risque si une analyse le sait. Pour
    /// l'entretien : « Entretien », ce qu'il rendrait.
    private func pill(_ message: CapsuleMessage) -> some View {
        HStack(spacing: Spacing.small + 2) {
            Image(systemName: message.symbol)
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: message.label)
                .font(.system(size: 14, weight: .semibold))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let figure = message.figure {
                    Text(verbatim: figure)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                }
                Text(verbatim: message.word)
                    .font(.system(size: 14, weight: .semibold))
            }
            if let note = message.safeNote {
                Label {
                    Text(verbatim: note)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: Palette.symbol(for: .safe)).foregroundStyle(Palette.vivid(for: .safe))
                }
                .labelStyle(.titleAndIcon)
                .padding(.leading, Spacing.tight)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.xLarge + 4)
        .frame(height: CapsuleGeometry.pillHeight)
        // Le fond de l'icône, violet profond : l'anneau en dégradé s'y lit, ce
        // qu'il ne faisait pas sur le dégradé magenta de la vue d'ensemble.
        .background(Self.deep, in: Capsule())
        .glassEffect(.regular.tint(Color(hex: 0x1B0E52).opacity(0.25)).interactive(), in: Capsule())
        .overlay(PillGauge(gauge: message.gauge, isShown: state.isShown))
        .shadow(color: Palette.colors(for: .overview).glow.opacity(0.45), radius: 14, y: 4)
        .contentShape(Capsule())
        .onTapGesture { state.onOpen() }
        .onHover { state.isHovered = $0 }
        .gesture(swipe)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: message.announcement))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(verbatim: message.hint))
        // Le trait « bouton » ne suffit pas : sans action, VoiceOver annonçait
        // un bouton qu'il ne pouvait pas presser (18/10/2026).
        .accessibilityAction { state.onOpen() }
    }

    /// Le fond d'icône (IDENTITE, « Identité ») : radial `#3A1C94 → #1B0E52`.
    private static let deep = RadialGradient(colors: [Color(hex: 0x3A1C94), Color(hex: 0x1B0E52)],
                                             center: .top, startRadius: 0, endRadius: 220)
}

/// Le contour de la pastille en jauge, comme l'anneau de l'icône (IDENTITE §5) :
/// la piste fumée tout autour, la part utilisée en dégradé de l'anneau, partie
/// du haut au centre dans le sens des aiguilles d'une montre. L'espace libre,
/// c'est ce qui reste de la piste. Ce qu'on peut rendre (l'entretien) finit la
/// part utilisée en vert, la couleur du sûr : on voit ce que le disque
/// retrouverait.
private struct PillGauge: View {
    let gauge: CapsuleGauge
    let isShown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 3 pt, trop fin ; 6, trop épais (Romain, 18/10/2026).
    static let lineWidth: CGFloat = 4.5
    /// Le dégradé de l'anneau suit le tour, du rose au départ jusqu'au cyan :
    /// le début de la jauge ne se perd plus dans le violet du fond, et ce qui
    /// reste libre se lit entre le cyan et le rose.
    private static let ring = AngularGradient(
        colors: [Color(hex: 0xFF3D8B), Color(hex: 0xB23BFF), Color(hex: 0x4F5BFF), Color(hex: 0x1FD1FF)],
        // Un peu avant midi : le bout arrondi du départ reste rose, au lieu de
        // reprendre le cyan de la fin du dégradé.
        center: .center, startAngle: .degrees(-105), endAngle: .degrees(255)
    )

    var body: some View {
        // La jauge se remplit à l'arrivée ; avec Réduire les animations, d'un coup.
        let shown = isShown || reduceMotion
        let filled = min(1, max(0.02, gauge.filled))
        let kept = max(0, filled - gauge.giveBack)
        ZStack {
            // La piste en verre fumé, 35 % de noir, comme celle de la jauge (IDENTITE §5).
            PillOutline(inset: Self.lineWidth / 2)
                .stroke(Color.black.opacity(0.35), lineWidth: Self.lineWidth)
            if gauge.giveBack > 0 {
                // Dessous : le bout arrondi du dégradé vient le recouvrir, la
                // jonction reste nette.
                PillOutline(inset: Self.lineWidth / 2)
                    .trim(from: shown ? kept : 0, to: shown ? filled : 0)
                    .stroke(Palette.vivid(for: .safe), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.9).delay(0.15), value: isShown)
            }
            if kept > 0 {
                PillOutline(inset: Self.lineWidth / 2)
                    .trim(from: 0, to: shown ? kept : 0)
                    .stroke(Self.ring, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.9).delay(0.15), value: isShown)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Le tour d'une capsule, du haut au centre, dans le sens des aiguilles d'une
/// montre : `trim` y découpe la jauge.
private struct PillOutline: Shape {
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let radius = box.height / 2
        var path = Path()
        path.move(to: CGPoint(x: box.midX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - radius, y: box.minY))
        path.addArc(center: CGPoint(x: box.maxX - radius, y: box.midY), radius: radius,
                    startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: box.minX + radius, y: box.maxY))
        path.addArc(center: CGPoint(x: box.minX + radius, y: box.midY), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
