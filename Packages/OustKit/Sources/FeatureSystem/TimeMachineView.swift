import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Les snapshots du disque de démarrage ont leur parcours et leur autorisation,
/// indépendamment du volume actuellement ouvert dans l'Explorateur.
public struct TimeMachineView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        SectionScaffold(.timeMachine, subtitle: "time_machine.subtitle") {
            Button { Task { await refresh() } } label: {
                Text("system.snapshots_refresh", bundle: .oust)
            }
            .buttonStyle(OnGradientButtonStyle())
            .disabled(isRefreshing || model.cleaning == .running)
        } content: {
            snapshotCard
            if !snapshots.isEmpty {
                ItemGroup(title: L10n.string("time_machine.local_snapshots"), symbol: "clock.arrow.circlepath",
                          tint: Palette.color(for: .snapshots), total: model.snapshotRetainedBytes ?? 0,
                          totalLabel: model.snapshotRetainedBytes.map(Formatters.bytes) ?? L10n.string("snapshot.size_unknown")) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshots) { item in
                            ItemRow(item, isSelected: model.isInCart(item.id)) { model.toggle(item) }
                                .disabled(model.snapshotReadFailed || model.cleaning == .running)
                            Divider().opacity(0.25)
                        }
                    }
                }
            }
        }
        .task { await refresh() }
    }

    private var snapshots: [CleanupItem] {
        model.items(in: [.snapshots]).sorted {
            let left = $0.lastActivity ?? .distantPast, right = $1.lastActivity ?? .distantPast
            return left == right ? $0.id > $1.id : left > right
        }
    }
    private var isRefreshing: Bool { model.snapshotsRefreshing || model.snapshotSizing }

    private func refresh() async {
        guard !model.snapshotsRefreshing, model.cleaning != .running else { return }
        await model.refreshSnapshots()
    }

    private var snapshotCard: some View {
        let deletable = model.deletableSnapshots
        return GlassCard(padding: Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text("system.snapshots_title", bundle: .oust)
                    .font(Typography.title).foregroundStyle(Palette.onGradient)
                Text(verbatim: model.snapshotReadFailed ? L10n.string("snapshot.error.listing") : deletable.isEmpty
                     ? L10n.string("system.snapshots_none")
                     : L10n.string("system.snapshots_number", Formatters.count(deletable.count)))
                    .font(Typography.headline).foregroundStyle(Palette.onGradientSecondary)
                if let bytes = model.snapshotRetainedBytes {
                    Text(verbatim: L10n.string("snapshot.retained_total", Formatters.bytes(bytes)))
                        .font(Typography.headline.monospacedDigit()).foregroundStyle(Palette.onGradient)
                } else if model.snapshotSizing {
                    Label { Text("snapshot.measuring", bundle: .oust) } icon: {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    .foregroundStyle(Palette.onGradientSecondary)
                }
                Text("system.snapshots_detail", bundle: .oust)
                Text("system.snapshots_size_unknown", bundle: .oust).font(Typography.caption)
                Text("snapshot.irreversible", bundle: .oust).font(Typography.caption)
                if !deletable.isEmpty {
                    Button {
                        model.add(deletable)
                        model.section = .cart
                    } label: { Text("system.snapshots_add", bundle: .oust) }
                    .buttonStyle(PrimaryButtonStyle(section: .timeMachine, eclat: true))
                    .disabled(model.snapshotReadFailed || model.cleaning == .running)
                }
            }
            .foregroundStyle(Palette.onGradientSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
