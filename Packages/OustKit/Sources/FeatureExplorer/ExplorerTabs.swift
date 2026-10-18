import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustScan

/// En attendant les statistiques (une à deux secondes sur un grand disque).
private struct Computing: View {
    var body: some View {
        VStack(spacing: Spacing.medium) {
            ProgressView()
            Text("explorer.computing", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Une ligne de statistique : symbole, libellé, barre, taille, nombre.
private struct StatRow: View {
    let symbol: String
    let title: String
    let detail: String?
    let fraction: Double
    let bytes: Int64
    let count: Int?
    let tint: Color

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).font(Typography.body.weight(.semibold)).lineLimit(1)
                if let detail { Text(verbatim: detail).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(minWidth: 180, alignment: .leading)
            SizeBar(fraction: fraction, tint: tint)
            Text(verbatim: Formatters.percent(fraction)).font(Typography.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
            if let count {
                Text(verbatim: L10n.string("explorer.files", Formatters.count(count)))
                    .font(Typography.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            }
            Text(verbatim: Formatters.compactBytes(bytes)).font(Typography.size).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Types de fichiers

/// Quelles familles de fichiers occupent le disque, et quelles extensions.
struct TypesTab: View {
    let state: ExplorerState
    @State private var expanded: Set<FileKind> = []

    var body: some View {
        if let analytics = state.analytics {
            let total = Double(max(1, analytics.kinds.reduce(analytics.smallFiles.bytes) { $0 + $1.tally.bytes }))
            List {
                Section {
                    ForEach(analytics.kinds, id: \.kind) { entry in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(entry.kind) },
                            set: { if $0 { expanded.insert(entry.kind) } else { expanded.remove(entry.kind) } }
                        )) {
                            ForEach(analytics.extensions.filter { $0.kind == entry.kind }, id: \.ext) { ext in
                                StatRow(symbol: "smallcircle.filled.circle", title: "." + ext.ext, detail: nil,
                                        fraction: Double(ext.tally.bytes) / total, bytes: ext.tally.bytes,
                                        count: ext.tally.count, tint: tint(entry.kind).opacity(0.8))
                            }
                        } label: {
                            StatRow(symbol: entry.kind.symbol, title: L10n.string(entry.kind.localizationKey), detail: nil,
                                    fraction: Double(entry.tally.bytes) / total, bytes: entry.tally.bytes,
                                    count: entry.tally.count, tint: tint(entry.kind))
                        }
                    }
                    if analytics.smallFiles.count > 0 {
                        StatRow(symbol: "square.grid.3x3.fill", title: L10n.string("explorer.small_files_kind"),
                                detail: L10n.string("explorer.small_files_kind_detail"),
                                fraction: Double(analytics.smallFiles.bytes) / total, bytes: analytics.smallFiles.bytes,
                                count: analytics.smallFiles.count, tint: .secondary)
                    }
                } header: {
                    Text("explorer.types_header", bundle: .oust)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        } else {
            Computing()
        }
    }

    private func tint(_ kind: FileKind) -> Color {
        switch kind {
        case .video: Palette.colors(for: .overview).glow
        case .image: Palette.colors(for: .browsers).glow
        case .audio: Palette.colors(for: .history).glow
        case .archive, .diskImage: Palette.colors(for: .system).glow
        case .application: Palette.colors(for: .developer).glow
        case .model: Palette.color(for: .aiModels)
        case .code: Palette.colors(for: .duplicates).glow
        case .document: Palette.colors(for: .explorer).glow
        case .data: Palette.vivid(for: .rebuilds)
        case .other: Color(hex: 0xD9D4EC)
        }
    }
}

// MARK: - Âge

/// Depuis quand les fichiers n'ont pas bougé : ce qui dort depuis des années
/// est le premier candidat à l'archivage.
struct AgesTab: View {
    let state: ExplorerState

    var body: some View {
        if let analytics = state.analytics {
            let total = Double(max(1, analytics.ages.reduce(analytics.smallFiles.bytes) { $0 + $1.tally.bytes }))
            let dormant = analytics.ages.filter { $0.range == .twoYears || $0.range == .older }.reduce(Int64(0)) { $0 + $1.tally.bytes }
            List {
                Section {
                    ForEach(analytics.ages, id: \.range) { entry in
                        StatRow(symbol: symbol(entry.range), title: L10n.string(entry.range.localizationKey), detail: nil,
                                fraction: Double(entry.tally.bytes) / total, bytes: entry.tally.bytes,
                                count: entry.tally.count, tint: tint(entry.range))
                    }
                } header: {
                    Text(verbatim: L10n.string("explorer.ages_header", Formatters.compactBytes(dormant)))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        } else {
            Computing()
        }
    }

    private func symbol(_ range: AgeRange) -> String {
        switch range {
        case .month: "sparkles"
        case .halfYear: "calendar"
        case .year: "calendar.badge.clock"
        case .twoYears: "moon"
        case .older: "moon.zzz"
        case .unknown: "questionmark.circle"
        }
    }

    private func tint(_ range: AgeRange) -> Color {
        switch range {
        case .month: Palette.vivid(for: .safe)
        case .halfYear: Palette.colors(for: .explorer).glow
        case .year: Palette.vivid(for: .rebuilds)
        case .twoYears: Palette.vivid(for: .protected)
        case .older: Palette.vivid(for: .review)
        case .unknown: .secondary
        }
    }
}

// MARK: - Plus gros fichiers

/// Les 200 plus gros fichiers du dossier analysé, où qu'ils soient.
struct LargestTab: View {
    let state: ExplorerState
    let model: AppModel
    @State private var preview = FilePreview()
    @State private var selection: LargeFile.ID?
    /// Le clic choisit la ligne sans donner le clavier à la liste (essai du
    /// 18/10/2026 : sélection grise, Espace et ↓ sans effet) : on le lui donne.
    @FocusState private var focused: Bool

    var body: some View {
        if let analytics = state.analytics {
            // Les voisins du coup d'œil : la liste entière, dans son ordre.
            let urls = analytics.largest.map { URL(fileURLWithPath: $0.path) }
            List(analytics.largest, selection: $selection) { file in
                LargestRow(file: file, model: model, isSelected: selection == file.id) {
                    preview.show(URL(fileURLWithPath: file.path), among: urls)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .onKeyPress(.space) {
                if preview.isOpen {
                    preview.close()
                    return .handled
                }
                guard let selection else { return .ignored }
                preview.show(URL(fileURLWithPath: selection), among: urls)
                return .handled
            }
            .filePreview(preview)
            .onChange(of: selection) {
                if selection != nil { focused = true }
                preview.follow(selection.map { URL(fileURLWithPath: $0) }, among: urls)
            }
            .onChange(of: preview.current) {
                guard let current = preview.current, let index = urls.firstIndex(of: current) else { return }
                selection = analytics.largest[index].id
            }
        } else {
            Computing()
        }
    }
}

private struct LargestRow: View {
    let file: LargeFile
    let model: AppModel
    let isSelected: Bool
    let preview: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Image(systemName: FileKind.of(file.name).symbol).foregroundStyle(Palette.colors(for: .explorer).glow).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: file.name).font(Typography.body.weight(.semibold)).lineLimit(1)
                Text(verbatim: PathDisplay.short(file.folder)).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(verbatim: file.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                .font(Typography.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(verbatim: Formatters.compactBytes(file.sizes.allocated)).font(Typography.size).frame(width: 80, alignment: .trailing)
            PreviewButton(isVisible: hovering || isSelected, action: preview)
            BinButton(item: model.item(for: file.leaf, in: file.parent), model: model).frame(width: Column.action)
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
        .accessibilityAction(named: Text("quicklook.action", bundle: .oust), preview)
        .contextMenu {
            PreviewMenuItem(action: preview)
            CommonMenu(item: model.item(for: file.leaf, in: file.parent), path: file.path, model: model)
        }
    }
}

// MARK: - Évolution

/// Ce qui a grossi ou maigri depuis la dernière analyse de ce disque.
struct GrowthTab: View {
    let state: ExplorerState

    var body: some View {
        if state.analytics == nil {
            Computing()
        } else if let previous = state.previous {
            if state.changes.isEmpty {
                EmptyState(symbol: "equal.circle", title: "explorer.growth_none_title",
                           message: "explorer.growth_none_detail")
            } else {
                let largest = Double(max(1, state.changes.map { abs($0.delta) }.max() ?? 1))
                List {
                    Section {
                        ForEach(state.changes) { change in
                            HStack(spacing: Spacing.medium) {
                                Image(systemName: change.delta > 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                                    .foregroundStyle(Growth.color(change.delta)).frame(width: 22)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: (change.path as NSString).lastPathComponent).font(Typography.body.weight(.semibold))
                                    Text(verbatim: relative(change.path)).font(Typography.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                .frame(minWidth: 200, alignment: .leading)
                                SizeBar(fraction: Double(abs(change.delta)) / largest, tint: Growth.color(change.delta))
                                Text(verbatim: "\(change.before.map(Formatters.compactBytes) ?? "—") → \(change.after.map(Formatters.compactBytes) ?? "—")")
                                    .font(Typography.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
                                Text(verbatim: Growth.text(change.delta)).font(Typography.size).foregroundStyle(Growth.color(change.delta))
                                    .frame(width: 80, alignment: .trailing)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                state.open(path: change.path)
                                state.tab = .tree
                            }
                        }
                    } header: {
                        Text(verbatim: L10n.string("explorer.growth_header", Formatters.timestamp(previous.date)))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        } else {
            EmptyState(symbol: "chart.line.uptrend.xyaxis", title: "explorer.growth_first_title",
                       message: "explorer.growth_first_detail")
        }
    }

    private func relative(_ path: String) -> String {
        let base = state.root.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}
