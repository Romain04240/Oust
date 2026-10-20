import AppKit
import SwiftUI
import OustClean
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustVolume

/// Un disque monté, une pastille de la barre d'outils, au centre (Romain,
/// 18/10/2026 : pas « Macintosh HD +1 », chaque disque à sa place).
///
/// Un seul élément de barre d'outils, sans le verre commun que la barre pose
/// d'ordinaire (« des pastilles dans des pastilles », Romain) : chaque pastille
/// porte le sien, de la hauteur de celui de l'Historique. Un seul élément pour
/// pouvoir défiler de côté quand les disques ne tiennent plus, au lieu que la
/// barre en range dans son menu « » » (Romain, 18/10/2026).
public struct DiskToolbar: ToolbarContent {
    let model: AppModel
    /// La place que la barre d'outils peut lui donner : sans limite, la barre
    /// rangeait toute la bande dans son menu « » » dès qu'elle débordait.
    let maxWidth: CGFloat

    public init(model: AppModel, maxWidth: CGFloat) {
        self.model = model
        self.maxWidth = maxWidth
    }

    public var body: some ToolbarContent {
        ToolbarItem(id: "disks", placement: .principal) {
            DiskStrip(model: model, maxWidth: maxWidth)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// Moins de 10 % libres : la pastille le dit d'un coup d'œil.
    static func isLow(_ capacity: Capacity) -> Bool {
        capacity.total > 0 && Double(capacity.availableForImportantUsage) / Double(capacity.total) < 0.1
    }
}

/// Les pastilles côte à côte ; quand elles ne tiennent plus, elles défilent :
/// au trackpad, ou par les flèches qui apparaissent alors aux bords (une
/// molette de souris ne fait pas défiler de côté).
struct DiskStrip: View {
    let model: AppModel
    let maxWidth: CGFloat
    @State private var contentWidth: CGFloat = 0
    @State private var position = ScrollPosition(idType: String.self)
    @State private var visible: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var overflows: Bool { contentWidth > maxWidth + 0.5 }
    private var ids: [String] { model.volumes.map(\.id) }
    private var hiddenBefore: Bool { overflows && ids.first.map { !visible.contains($0) } == true }
    private var hiddenAfter: Bool { overflows && ids.last.map { !visible.contains($0) } == true }

    /// La place d'une flèche et de son écart.
    private static let arrowSpace: CGFloat = 26 + 6

    var body: some View {
        // Les flèches de part et d'autre, à elles : posées sur la bande, elles
        // couvraient le dernier disque (Romain, 18/10/2026). Présentes dès que
        // ça déborde, grisées au bout, pour que rien ne saute.
        HStack(spacing: 6) {
            if overflows { arrow("chevron.left", step: -1).disabled(!hiddenBefore) }
            ScrollView(.horizontal) {
                row.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            }
            .scrollIndicators(.never)
            .scrollDisabled(!overflows)
            .scrollPosition($position)
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { visible = Set($0) }
            .frame(width: min(max(contentWidth, 1), maxWidth - (overflows ? 2 * Self.arrowSpace : 0)))
            // Un fondu au bord dit qu'il y a d'autres disques plus loin.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [hiddenBefore ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 20)
                    Rectangle()
                    LinearGradient(colors: [.black, hiddenAfter ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 20)
                }
            }
            if overflows { arrow("chevron.right", step: 1).disabled(!hiddenAfter) }
        }
    }

    private var row: some View {
        GlassEffectContainer(spacing: Spacing.small) {
            HStack(spacing: Spacing.small) {
                ForEach(model.volumes) { volume in
                    DiskPastille(model: model, volume: volume).id(volume.id)
                }
            }
            .scrollTargetLayout()
        }
        .fixedSize()
    }

    /// Fait venir le disque suivant (ou précédent) caché.
    private func arrow(_ symbol: String, step: Int) -> some View {
        Button {
            let shown = ids.enumerated().filter { visible.contains($0.element) }.map(\.offset)
            guard let edge = step > 0 ? shown.max() : shown.min() else { return }
            let target = min(max(edge + step, 0), ids.count - 1)
            withAnimation(reduceMotion ? nil : .snappy) {
                position.scrollTo(id: ids[target], anchor: step > 0 ? .trailing : .leading)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(Text(step > 0 ? "disks.scroll_next" : "disks.scroll_previous", bundle: .oust))
        .accessibilityLabel(Text(step > 0 ? "disks.scroll_next" : "disks.scroll_previous", bundle: .oust))
    }
}

/// Un disque : son symbole, son nom, sa jauge, son espace libre, en toutes lettres.
struct DiskPastille: View {
    let model: AppModel
    let volume: VolumeDescriptor
    @State private var showsPanel = false
    @State private var formatting: FormatTarget?
    @State private var pruning: BackupsTarget?

    private var free: String { L10n.string("disks.free", Formatters.compactBytes(volume.capacity.availableForImportantUsage)) }

    var body: some View {
        Button { showsPanel.toggle() } label: {
            // Sur deux lignes, le nom puis la jauge et l'espace libre : deux fois
            // moins large, de quoi montrer trois ou quatre disques sans que la
            // barre d'outils en range dans « » » (Romain, 18/10/2026).
            HStack(spacing: 7) {
                Image(systemName: volume.symbol).font(.system(size: 13, weight: .medium))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: volume.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)
                    HStack(spacing: 6) {
                        MiniGauge(capacity: volume.capacity, selected: volume.isBoot ? model.cartTotal : 0)
                            .frame(width: 44, height: 5)
                        Text(verbatim: free)
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundStyle(DiskToolbar.isLow(volume.capacity) ? AnyShapeStyle(Color.orange)
                                                                               : AnyShapeStyle(.secondary))
                    }
                }
                .fixedSize()
            }
            // De l'air entre le texte et l'arrondi (Romain, 18/10/2026).
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .help(Text(verbatim: L10n.string("disks.pastille_help", volume.name, free)))
        .accessibilityLabel(Text(verbatim: L10n.string("disks.pastille_help", volume.name, free)))
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            DiskPanel(model: model, volume: volume, onFormat: { target in
                showsPanel = false
                formatting = target
            }, onPruneBackups: { target in
                showsPanel = false
                pruning = target
            })
        }
        .sheet(item: $formatting) { target in
            FormatSheet(model: model, target: target) { formatting = nil }
        }
        .sheet(item: $pruning) { target in
            PruneBackupsSheet(model: model, target: target) { pruning = nil }
        }
    }
}

/// Une jauge fine : l'utilisé, aux couleurs d'Oust!, la part que la corbeille
/// rendra (en Éclat), le libre en creux. Avec un liseré : sans lui, sur le verre
/// violet, on ne voyait pas où finissait la jauge (Romain, 18/10/2026).
struct MiniGauge: View {
    let capacity: Capacity
    let selected: Int64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let used = LinearGradient(colors: [Color(hex: 0xE0157F), Color(hex: 0x8E3CF7), Color(hex: 0x4FC3FF)],
                                     startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { proxy in
            let total = Double(max(1, capacity.total))
            let selectedPart = min(Double(selected), Double(capacity.occupied)) / total
            let usedPart = Double(capacity.occupied) / total - selectedPart
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.14))
                HStack(spacing: 0) {
                    Rectangle().fill(Self.used).frame(width: proxy.size.width * usedPart)
                    if selectedPart > 0 {
                        Rectangle().fill(Palette.eclat).frame(width: max(2, proxy.size.width * selectedPart))
                    }
                }
                .clipShape(Capsule())
                Capsule().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5)
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: selected)
        .accessibilityHidden(true)
    }
}

/// Le disque à formater, tel qu'on l'a montré.
struct FormatTarget: Identifiable {
    var id: String { volume.id }
    let volume: VolumeDescriptor
    let details: DiskDetails
}
