import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustWatch

/// Les panneaux Stockage et Batterie partagent la navigation du menu.
public struct MenuBarPanel: View {
    @Bindable var model: AppModel
    @Bindable var navigation: MenuBarNavigation
    @Environment(\.openSettings) private var openSettings

    init(model: AppModel, navigation: MenuBarNavigation) {
        self.model = model
        self.navigation = navigation
    }

    static let width: CGFloat = 360

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if navigation.page == .storage {
                MenuPanelViewport(maximumHeight: navigation.height - 40) {
                    storage
                }
            } else {
                BatteryMenuPanel(watch: model.watch, navigation: navigation)
                if !model.watch.menuBarContents.showsStorage {
                    HStack {
                        Button { open(.overview) } label: {
                            Label { Text("menubar.open_short", bundle: .oust) } icon: { Image(systemName: "macwindow").foregroundStyle(.purple) }
                        }
                        Spacer()
                        Button(action: navigation.quit) {
                            Label { Text("menubar.quit_short", bundle: .oust) } icon: { Image(systemName: "power").foregroundStyle(.pink) }
                        }
                    }
                    .font(Typography.caption).buttonStyle(.borderless)
                }
            }
        }
        .padding(Spacing.large)
        .frame(width: Self.width)
        // À chaque ouverture : la veille ne relit que le disque de démarrage
        // (un disque réseau endormi pourrait faire attendre), les autres
        // disques sont relus ici, quand on les regarde.
        .onAppear {
            // Lancé à la connexion, sans fenêtre : le panneau est la première
            // vue à connaître l'ouverture des Réglages.
            if SettingsWindow.opener == nil { SettingsWindow.opener = openSettings }
        }
        .task(id: navigation.presented && navigation.page == .storage) {
            guard navigation.presented, navigation.page == .storage else { return }
            await model.refreshVolumesInBackground()
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            let disks = menuVolumes
            if !disks.isEmpty {
                volumes(disks)
                if disks.contains(where: {
                    WatchedVolumes.isEjectable(isBoot: $0.isBoot, isInternal: $0.isInternal, isRemovable: $0.isRemovable)
                }) {
                    Button { open(.overview) } label: {
                        Label { Text("menubar.manage_disks", bundle: .oust) } icon: { Image(systemName: "externaldrive") }
                    }
                    .buttonStyle(.borderless)
                }
            }
            bin
            if let retention = retentionLine {
                Label { Text(verbatim: retention) } icon: { Image(systemName: "calendar.badge.clock") }
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.small)
                    .padding(.vertical, Spacing.tight)
            }
        }
    }

    // MARK: Disques

    private var menuVolumes: [VolumeDescriptor] {
        let external = model.volumes.filter { !$0.isBoot }
        return (model.watch.boot ?? model.bootVolume).map { [$0] + external } ?? external
    }

    private func volumes(_ disks: [VolumeDescriptor]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(disks) { volume in
                if volume.id != disks.first?.id {
                    Divider()
                }
                VolumeLine(volume: volume, isLow: isLow(volume), presented: navigation.presented, quit: navigation.quit) {
                    let current = volume.isBoot ? (model.watch.boot ?? model.bootVolume)
                        : model.volumes.first(where: { $0.id == volume.id })
                    if let current, model.canAnalyzeVolume(current) { model.selectAnalysisVolume(current) }
                    open(.overview)
                }
            }
            if model.watch.isLow, let threshold = model.watch.thresholdBytes {
                Label { Text(verbatim: L10n.string("menubar.low", Formatters.compactBytes(threshold))) }
                    icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.color(for: .review))
            }
        }
        .storageCard()
    }

    private func isLow(_ volume: VolumeDescriptor) -> Bool {
        model.watch.settings.alertsLowDisk
            && LowDiskAlarm.isLow(available: volume.capacity.availableForImportantUsage, total: volume.capacity.total,
                                  threshold: model.watch.settings.threshold)
    }

    // MARK: Corbeille

    /// Le bouton ouvre la corbeille d'Oust! dans la fenêtre pour la confirmation.
    private var bin: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                Label { Text("menubar.bin", bundle: .oust) } icon: { Image(systemName: "trash.fill").foregroundStyle(.pink) }
                    .font(Typography.body.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text(verbatim: binContent)
                    .font(Typography.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button { open(.cart) } label: {
                Label { Text("menubar.bin_review", bundle: .oust) } icon: { Image(systemName: "trash") }
                    .font(Typography.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(model.cart.isEmpty)
        }
        .storageCard()
    }

    private var binContent: String {
        let count = model.cart.count
        if model.cartOnlySnapshots && !model.cartSnapshotSizesKnown {
            return L10n.string("cart.snapshot_count", Formatters.count(model.cartSnapshotCount))
        }
        let size = Formatters.bytes(model.cartTotal)
        switch count {
        case 0: return L10n.string("menubar.bin_empty")
        case 1: return L10n.string("watch.items_one", size)
        default: return L10n.string("watch.items_other", Formatters.count(count), size)
        }
    }

    // MARK: Règles planifiées

    private var retentionLine: String? {
        let watch = model.watch
        if let running = watch.runningFamily {
            return L10n.string("menubar.retention_running", L10n.string(running.localizationKey))
        }
        let next = RetentionFamily.allCases.compactMap { family in watch.nextRun(family).map { (family, $0) } }
            .min { $0.1 < $1.1 }
        guard let next else { return nil }
        return L10n.string("menubar.retention_next", L10n.string(next.0.localizationKey), Formatters.relative(next.1))
    }

    private func open(_ section: AppSection?) {
        navigation.openMainWindow(section)
    }
}

struct VolumeLine: View {
    let volume: VolumeDescriptor
    let isLow: Bool
    let presented: Bool
    let quit: () -> Void
    let open: () -> Void

    var body: some View {
        let free = Formatters.compactBytes(volume.capacity.availableForImportantUsage)
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.small) {
                Image(systemName: volume.symbol)
                    .foregroundStyle(volume.isBoot ? Color.purple : Color.blue)
                    .frame(width: 25, height: 25)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.small))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(verbatim: volume.name)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if volume.isBoot {
                        Text("menubar.boot_disk", bundle: .oust)
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Spacing.hair)
                VStack(alignment: .trailing, spacing: Spacing.tight) {
                    Button(action: open) {
                        Label { Text("menubar.open_short", bundle: .oust) } icon: { Image(systemName: "macwindow").foregroundStyle(.purple) }
                    }
                    .accessibilityLabel(Text("menubar.open", bundle: .oust))
                    .help(Text("menubar.open", bundle: .oust))
                    Button(action: quit) {
                        Label { Text("menubar.quit_short", bundle: .oust) } icon: { Image(systemName: "power").foregroundStyle(.pink) }
                    }
                    .accessibilityLabel(Text("menubar.quit", bundle: .oust))
                }
                .font(Typography.caption)
                .lineLimit(1)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                Text(verbatim: free)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isLow ? Palette.color(for: .review) : .purple)
                    .contentTransition(.numericText())
                Text("menubar.storage_available", bundle: .oust)
                    .font(Typography.caption)
            }
            .fixedSize(horizontal: true, vertical: false)
            if volume.capacity.total > 0 {
                DiskBar(used: volume.capacity.occupiedFraction, isLow: isLow, presented: presented)
                VStack(spacing: Spacing.small) {
                    HStack(spacing: Spacing.small) {
                        storageMetric("menubar.storage_immediate", volume.capacity.available, symbol: "arrow.up.right.circle.fill", tint: .blue)
                        storageMetric("menubar.storage_purgeable", volume.capacity.purgeable, symbol: "sparkles", tint: .purple)
                    }
                    HStack(spacing: Spacing.small) {
                        storageMetric("menubar.storage_occupied", volume.capacity.occupied, symbol: "internaldrive.fill", tint: .orange)
                        storageMetric("menubar.storage_total", volume.capacity.total, symbol: "externaldrive.fill", tint: .indigo)
                    }
                }
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .help(L10n.string("menubar.volume_free", free, Formatters.compactBytes(volume.capacity.total)))
        .accessibilityElement(children: .combine)
    }

    private func storageMetric(_ title: String, _ bytes: Int64, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                Text(LocalizedStringKey(title), bundle: .oust).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(.system(size: 11)).frame(height: 16, alignment: .leading)
            Text(verbatim: Formatters.compactBytes(bytes))
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(Spacing.small)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small))
        .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(.primary.opacity(0.08)) }
        .accessibilityElement(children: .combine)
    }
}

/// La barre d'un disque, comme le contour de la pastille : l'occupé aux
/// couleurs de l'anneau, le libre en piste ; en orangé sous le seuil d'alerte.
private struct DiskBar: View {
    let used: Double
    let isLow: Bool
    let presented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private static let ring = LinearGradient(
        colors: [Color(hex: 0xFF3D8B), Color(hex: 0xB23BFF), Color(hex: 0x4F5BFF), Color(hex: 0x1FD1FF)],
        startPoint: .leading, endPoint: .trailing
    )

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(isLow ? AnyShapeStyle(Palette.vivid(for: .review)) : AnyShapeStyle(Self.ring))
                    .overlay { MenuSheen(active: presented && !reduceMotion) }
                    .clipShape(Capsule())
                    .frame(width: proxy.size.width * min(1, max(0, used)))
                    .opacity(appeared || reduceMotion ? 1 : 0.35)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: used)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: appeared)
            }
        }
        .frame(height: 8)
        .onAppear { appeared = true }
        .accessibilityHidden(true)
    }
}

/// Normal panels have a fixed natural height, regardless of the height left
/// by the previously displayed page. Only genuine overflow uses scrolling.
struct MenuPanelViewport<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var naturalHeight: CGFloat = 0

    private var limit: CGFloat { max(1, maximumHeight) }

    var body: some View {
        Group {
            if naturalHeight > limit {
                ScrollView { measuredContent }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: limit)
            } else {
                MenuNaturalHeightLayout(maximumHeight: limit) { measuredContent }
                    .clipped()
            }
        }
    }

    private var measuredContent: some View {
        content.fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard height.isFinite, height >= 0, abs(height - naturalHeight) > 0.25 else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { naturalHeight = height }
            }
    }
}

/// Do not accept the native window's old vertical proposal as extra space.
/// ViewThatFits + maxHeight can report a compact ideal size while filling that
/// old proposal when placed, so fittingSize alone did not expose the defect.
private struct MenuNaturalHeightLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: min(maximumHeight, natural.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

struct MenuSheen: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelling = false

    var body: some View {
        if active && !reduceMotion {
            GeometryReader { proxy in
                let width = min(75, proxy.size.width * 0.4)
                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width, height: proxy.size.height)
                    .offset(x: travelling ? proxy.size.width + width : -width)
                    .animation(.linear(duration: 3.2).repeatForever(autoreverses: false), value: travelling)
                    .onAppear { travelling = true }
                    .onDisappear {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { travelling = false }
                    }
            }
            .transition(.identity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private extension View {
    func storageCard() -> some View {
        let card = RoundedRectangle(cornerRadius: Radius.medium + 2)
        return self
            .padding(Spacing.medium)
            .background(.quaternary.opacity(0.5), in: card)
            .overlay { card.strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false) }
    }
}
