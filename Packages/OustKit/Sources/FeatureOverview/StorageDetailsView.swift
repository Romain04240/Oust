import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustVolume

/// Le reste de la jauge n'est pas une catégorie de fichiers effaçables. On
/// distingue la soustraction de l'analyse des mesures APFS qui l'expliquent.
struct StorageDetailsView: View {
    let model: AppModel
    let volume: VolumeDescriptor
    let breakdown: StorageBreakdown
    let classificationDate: Date?
    let hasClassification: Bool
    @State private var reader = StorageDetailsModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var residual: Int64 { breakdown.parts(capacity: volume.capacity).first { $0.category == .system }?.bytes ?? 0 }
    private var treeCount: Int { model.analyzedTree(for: volume)?.inaccessibleCount ?? 0 }
    private var unreadable: [String] { model.analyzedTree(for: volume)?.inaccessiblePaths(limit: 20) ?? [] }
    private var loading: Bool { reader.isLoading(for: volume) }
    private var container: APFSContainerUsage? { reader.usage(for: volume) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("storage.details.title", bundle: .oust).font(Typography.title)
                    Text(verbatim: volume.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Text("common.ok", bundle: .oust) }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    Text(verbatim: Formatters.bytes(residual)).font(Typography.title.monospacedDigit())
                    Text("storage.details.explanation", bundle: .oust)
                        .fixedSize(horizontal: false, vertical: true)
                    GroupBox {
                        VStack(spacing: Spacing.small) {
                            amount("storage.details.occupied", volume.capacity.occupied)
                            amount("storage.details.classified", max(0, volume.capacity.occupied - residual))
                            Divider()
                            amount("storage.details.remainder", residual)
                        }.padding(Spacing.small)
                    }
                    if let date = classificationDate {
                        Text(verbatim: L10n.string("storage.based_on_scan", Formatters.timestamp(date)))
                            .font(Typography.caption).foregroundStyle(.secondary)
                    } else if hasClassification {
                        Text("storage.classification_date_unknown", bundle: .oust)
                            .font(Typography.caption).foregroundStyle(.secondary)
                    } else {
                        Text("storage.needs_scan", bundle: .oust)
                            .font(Typography.caption).foregroundStyle(.secondary)
                    }
                    if model.isRefreshingStorageClassification(for: volume) {
                        HStack(spacing: Spacing.small) {
                            ProgressView().controlSize(.small)
                            Text("storage.classification_refreshing", bundle: .oust).font(Typography.caption)
                        }
                    }
                    Divider()
                    Text("storage.details.volumes", bundle: .oust).font(Typography.headline)
                    if reduceMotion {
                        apfsContent
                    } else {
                        // Seul le relevé apparaît en fondu, sans conserver les
                        // anciens chiffres sous le titre d'un autre volume.
                        apfsContent.keyframeAnimator(initialValue: CGFloat(1), trigger: loading) { content, opacity in
                            content.opacity(Double(opacity))
                        } keyframes: { _ in
                            MoveKeyframe(CGFloat(0))
                            LinearKeyframe(CGFloat(1), duration: 0.2)
                        }
                    }
                    if volume.isBoot, let snapshots = model.snapshotRetainedBytes {
                        Divider()
                        amount("storage.details.snapshots", snapshots)
                        Text("storage.details.snapshots_note", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                        Button {
                            model.searchText = ""
                            model.section = .timeMachine
                            dismiss()
                        } label: { Text("overview.see_snapshots", bundle: .oust) }
                    }
                    Divider()
                    Text("storage.details.unreadable", bundle: .oust).font(Typography.headline)
                    if model.analyzedTree(for: volume) == nil {
                        Text("storage.needs_scan", bundle: .oust)
                    } else if treeCount == 0 {
                        Text("storage.details.no_unreadable", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: L10n.string("storage.details.unreadable_count", Formatters.count(treeCount)))
                        ForEach(unreadable, id: \.self) { path in
                            Text(verbatim: path).font(Typography.caption).textSelection(.enabled)
                        }
                        if treeCount > unreadable.count {
                            Text(verbatim: L10n.string("storage.details.unreadable_limit", Formatters.count(unreadable.count)))
                                .font(Typography.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("storage.details.unknown_note", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            model.reanalyze(volume)
                            dismiss()
                        } label: { Text("disks.reanalyze", bundle: .oust) }
                        .disabled(model.isAnalyzing(volume))
                        if volume.isBoot, model.fullDiskAccess == false {
                            Button {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: { Text("access.open", bundle: .oust) }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 550)
        }
        .padding(Spacing.xLarge)
        .frame(width: 720)
        .task(id: reader.identity(for: volume)) {
            await reader.load(for: volume)
        }
    }

    private var apfsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            if loading {
                ProgressView().controlSize(.small)
            } else if let container {
                Text("storage.details.volumes_note", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                ForEach(container.volumes.filter { $0.id != container.selectedVolume }) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: Spacing.hair) {
                            Text(verbatim: L10n.string(entry.roleKey)).fontWeight(.medium)
                            Text(verbatim: entry.name).font(Typography.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(verbatim: Formatters.bytes(entry.used)).monospacedDigit()
                    }
                }
                if let metadata = container.metadataBytes { amount("storage.details.metadata", metadata) }
            } else {
                Text("storage.details.apfs_unavailable", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func amount(_ key: LocalizedStringKey, _ bytes: Int64) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key, bundle: .oust)
            Spacer()
            Text(verbatim: Formatters.bytes(bytes)).monospacedDigit()
        }
    }
}
