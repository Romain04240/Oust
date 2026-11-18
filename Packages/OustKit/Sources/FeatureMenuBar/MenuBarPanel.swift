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
    @State private var storageHeight: CGFloat = 182

    init(model: AppModel, navigation: MenuBarNavigation) {
        self.model = model
        self.navigation = navigation
    }

    static let width: CGFloat = 460

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if navigation.page == .storage {
                ScrollView {
                    storage
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { storageHeight = $0 }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: max(1, min(storageHeight, navigation.height - 40)))
            } else {
                BatteryMenuPanel(watch: model.watch, navigation: navigation)
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
                        Label { Text("menubar.manage_disks", bundle: .oust) } icon: {
                            Image(systemName: "externaldrive")
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, Spacing.small)
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
                VolumeLine(volume: volume, isLow: isLow(volume))
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
                Text("menubar.bin", bundle: .oust)
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
        navigation.close()
        if let section {
            model.searchText = ""
            model.section = section
        }
        MainWindow.show()
    }
}

private struct VolumeLine: View {
    let volume: VolumeDescriptor
    let isLow: Bool

    var body: some View {
        let free = Formatters.compactBytes(volume.capacity.availableForImportantUsage)
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.small) {
                Image(systemName: volume.symbol)
                    .foregroundStyle(volume.isBoot ? Palette.eclatSolid : Color.teal)
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
                HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                    Text(verbatim: free)
                        .font(Typography.size)
                    Text("watch.capsule.word", bundle: .oust)
                        .font(Typography.caption)
                }
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isLow ? AnyShapeStyle(Palette.color(for: .review)) : AnyShapeStyle(.primary))
            }
            if volume.capacity.total > 0 {
                DiskBar(used: volume.capacity.occupiedFraction, isLow: isLow)
                HStack(spacing: Spacing.small) {
                    Text(verbatim: L10n.string("menubar.disk_occupied", Formatters.compactBytes(volume.capacity.occupied),
                                              Formatters.compactBytes(volume.capacity.total)))
                    Spacer(minLength: 0)
                    if volume.capacity.purgeable > 0 {
                        Text(verbatim: L10n.string("menubar.disk_purgeable",
                                                  Formatters.compactBytes(volume.capacity.purgeable)))
                    }
                }
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .help(L10n.string("menubar.volume_free", free, Formatters.compactBytes(volume.capacity.total)))
        .accessibilityElement(children: .combine)
    }
}

/// La barre d'un disque, comme le contour de la pastille : l'occupé aux
/// couleurs de l'anneau, le libre en piste ; en orangé sous le seuil d'alerte.
private struct DiskBar: View {
    let used: Double
    let isLow: Bool
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

private extension View {
    func storageCard() -> some View {
        let card = RoundedRectangle(cornerRadius: Radius.medium + 2)
        return self
            .padding(Spacing.medium)
            .background(.quaternary.opacity(0.5), in: card)
            .overlay { card.strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false) }
    }
}
