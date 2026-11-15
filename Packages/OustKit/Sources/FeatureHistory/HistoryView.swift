import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// L'historique local : ce qui a été viré, quand, comment, et où c'est parti
/// (SPEC §6.3).
public struct HistoryView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        SectionScaffold(.history, subtitle: "history.subtitle") {
            let total = model.historyEntries.filter(\.result.succeeded).reduce(Int64(0)) { $0 + $1.bytes }
            if total > 0 {
                Text(verbatim: L10n.string("history.total", Formatters.compactBytes(total)))
                    .font(Typography.headline).foregroundStyle(Palette.onGradient)
            }
        } content: {
            if model.historyEntries.isEmpty {
                EmptyState(symbol: "clock", title: "history.empty_title", message: "history.empty_detail")
            }
            ForEach(sessions, id: \.0) { _, entries in
                SessionCard(model: model, entries: entries)
            }
        }
        .task { await model.loadHistory() }
    }

    private var sessions: [(UUID, [CleanupOutcome])] {
        var order: [UUID] = []
        var groups: [UUID: [CleanupOutcome]] = [:]
        for entry in model.historyEntries {
            if groups[entry.sessionID] == nil { order.append(entry.sessionID) }
            groups[entry.sessionID, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

private struct SessionCard: View {
    let model: AppModel
    let entries: [CleanupOutcome]
    @State private var expanded = false

    var body: some View {
        let freed = entries.filter(\.result.succeeded).reduce(Int64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: Spacing.small) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.secondary).frame(width: 14)
                    Text(verbatim: entries.first.map { Formatters.timestamp($0.date) } ?? "").font(Typography.headline)
                    Text(verbatim: L10n.string("history.session_count", Formatters.count(entries.count)))
                        .font(Typography.caption).foregroundStyle(.secondary)
                    if case .agent(let name)? = entries.first?.origin {
                        AgentBadge(name: name)
                    }
                    Spacer()
                    Text(verbatim: Formatters.compactBytes(freed)).font(Typography.size)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(entries) { entry in
                    EntryRow(model: model, entry: entry)
                    Divider().opacity(0.25)
                }
            }
        }
        .padding(Spacing.large)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }
}

/// « par un agent » : ce nettoyage-là, un agent IA l'a fait par `oust`.
///
/// Le style de `Tag`, mais pas `Tag` : il pose sa propre bulle d'aide, et
/// celle-ci doit nommer l'agent.
private struct AgentBadge: View {
    let name: String?

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "sparkles")
            Text("history.by_agent", bundle: .oust).lineLimit(1)
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.hair)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .help(Text(verbatim: name.map { L10n.string("history.by_agent_help_named", $0) }
            ?? L10n.string("history.by_agent_help")))
    }
}

private struct EntryRow: View {
    let model: AppModel
    let entry: CleanupOutcome

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Image(systemName: Describe.symbol(entry.method))
                .foregroundStyle(entry.result.succeeded ? Palette.color(for: entry.category) : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: Spacing.hair) {
                HStack {
                    Text(verbatim: entry.title).font(Typography.body.weight(.semibold)).lineLimit(1)
                    Text(verbatim: entry.owner).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(verbatim: Describe.outcome(entry.result)).font(Typography.caption).foregroundStyle(.secondary)
                Text(verbatim: destination).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                // Un projet archivé : la copie vérifiée vit sur le disque d'archive.
                if case .archive(let copy) = entry.method, entry.result.succeeded {
                    Text(verbatim: L10n.string("history.archived_to", copy)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer()
            Text(verbatim: Formatters.compactBytes(entry.bytes)).font(Typography.size)
            if model.restoredIDs.contains(entry.id) {
                Tag(L10n.string("history.restored"), symbol: "arrow.uturn.backward", tint: Palette.vivid(for: .safe))
            }
        }
        .contextMenu {
            if case .archive(let copy) = entry.method, FileManager.default.fileExists(atPath: copy) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy)]) } label: {
                    Label { Text("archive.reveal_copy", bundle: .oust) } icon: { Image(systemName: "externaldrive") }
                }
            }
            if let trashed = entry.trashedTo.first {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashed)]) } label: {
                    Label { Text("history.reveal_trash", bundle: .oust) } icon: { Image(systemName: "trash.square") }
                }
            }
        }
    }

    /// Où c'est parti : la corbeille, ou « supprimé définitivement ».
    private var destination: String {
        // Une photo n'a pas de chemin : elle est dans « Supprimés récemment » de Photos.
        if entry.method.photoAssetID != nil { return L10n.string("history.photos_recently_deleted") }
        if let trashed = entry.trashedTo.first { return L10n.string("history.went_to", trashed) }
        return L10n.string("history.was_at", entry.paths.first ?? "")
    }
}
