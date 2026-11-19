import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustDuplicates
import OustLocalization
import OustModel

@MainActor
func requestDuplicateQuickLook(_ url: URL, neighbors: [URL], similar: Bool, model: AppModel, preview: FilePreview) {
    preview.showPrepared(url, among: neighbors) {
        guard let prepared = await model.prepareDuplicatePreview(url, similar: similar) else { return nil }
        return (prepared.urls, prepared)
    }
}

/// Les doublons, conscients des clones APFS (SPEC §7).
public struct DuplicatesView: View {
    @Bindable var model: AppModel
    @State private var limit = 60
    @State private var preview = FilePreview()
    @State private var previewOwner = UUID()
    @State private var selection: DuplicateFile.ID?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let similar = model.similarImages.isSelected
        SectionScaffold(.duplicates, subtitle: similar ? "duplicates.subtitle_similar" : "duplicates.subtitle") {
            HStack(spacing: Spacing.small) {
                if similar {
                    SimilarSearchButton(similar: model.similarImages)
                } else {
                    if let volume = model.analyzedVolume, !volume.isBoot {
                        VolumeBadge(name: volume.name, symbol: volume.symbol)
                    }
                    Button { Task { await model.findDuplicates() } } label: {
                        Text(model.duplicates.isRunning ? "duplicates.searching" : "duplicates.search", bundle: .oust)
                    }
                    .buttonStyle(OnGradientButtonStyle())
                    .disabled(model.duplicates.isRunning)
                }
            }
        } content: {
            // Identiques ou similaires (Romain, 18/10/2026 : les images hors de
            // la photothèque aussi).
            DuplicatesTabs(model: model)
            DuplicateExclusionsView(model: model)
            if similar {
                SimilarImagesContent(model: model, preview: preview)
            } else {
                identical
            }
        }
        .onAppear {
            model.setDuplicatePreviewRevoker(for: previewOwner) { [weak preview] in preview?.revoke() }
        }
        .onDisappear {
            preview.revoke()
            model.setDuplicatePreviewRevoker(for: previewOwner, nil)
        }
        .alert(Text("quicklook.unavailable", bundle: .oust), isPresented: $preview.preparedPreviewUnavailable) {}
    }

    /// Les doublons octet pour octet, sur le disque analysé.
    @ViewBuilder
    private var identical: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.small) {
                    Toggle(isOn: $model.duplicatesAsClones) {
                        Text("duplicates.as_clones", bundle: .oust).font(Typography.headline).foregroundStyle(Palette.onGradient)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .disabled(model.duplicatesAsClones ? !model.canMoveFiles : !model.canCloneDuplicates)
                    ContextHelpButton("duplicates.as_clones_detail")
                        .foregroundStyle(Palette.onGradient)
                }
                Divider().overlay(Color.white.opacity(0.2))
                // Rien n'est coché sans cette case (RULES.md, règle 4) ;
                // cochée, Oust! garde un exemplaire par groupe et coche le reste.
                HStack(spacing: Spacing.small) {
                    Toggle(isOn: Binding(get: { model.preferences.duplicateAutoSelect },
                                         set: { model.setDuplicateAutoSelect($0) })) {
                        Text("duplicates.auto_select", bundle: .oust).font(Typography.headline).foregroundStyle(Palette.onGradient)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .disabled(!model.canCleanDuplicates)
                    ContextHelpButton("duplicates.auto_select_detail")
                        .foregroundStyle(Palette.onGradient)
                }
            }
        }
        // Les groupes d'un autre disque que celui choisi ne se montrent pas :
        // on cherche sur celui-ci.
        switch model.duplicates.isRunning || model.duplicatesMatchAnalyzedVolume ? model.duplicates : .idle {
        case .idle:
            EmptyState(symbol: "doc.on.doc", title: "duplicates.empty_title", message: "duplicates.empty_detail")
        case .running:
            GlassCard(padding: Spacing.xLarge) {
                HStack(spacing: Spacing.xLarge) {
                    PulseOrb(section: .duplicates, isActive: true, size: 140)
                    TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                        Text(verbatim: L10n.string("duplicates.progress", Formatters.count(model.duplicateProgress.filesExamined),
                                                   Formatters.count(model.duplicateProgress.filesHashed)))
                            .font(Typography.headline).foregroundStyle(Palette.onGradient)
                    }
                }
            }
        case .done:
            let suggestions = model.availableDuplicateSuggestions
            HStack(alignment: .bottom) {
                HeroSize(model.reclaimableDuplicateBytes, caption: "duplicates.total_caption")
                Spacer()
                Button {
                    model.add(suggestions)
                } label: { Text("duplicates.add_suggested", bundle: .oust) }
                    .buttonStyle(PrimaryButtonStyle(section: .duplicates))
                    .disabled(suggestions.isEmpty)
            }
            if model.duplicateGroups.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: "duplicates.none_title", message: "duplicates.none_detail")
            }
            let shown = Array(model.duplicateGroups.prefix(limit))
            // Le clavier va au VStack : posé sur la pile paresseuse, il ne
            // le recevait pas, et Espace faisait défiler la page (essai du
            // 18/10/2026).
            VStack(spacing: 0) {
                LazyVStack(spacing: Spacing.medium) {
                    ForEach(shown) { group in
                        GroupCard(model: model, group: group, selection: $selection) { file in
                            guard model.canUseDuplicateQuickLook else { return }
                            openPreview(file.url, neighbors: group.files.map(\.url))
                        }
                    }
                }
            }
            .previewKeys(selection: $selection, order: shown.flatMap { $0.files.map(\.id) }) { id in
                guard model.canUseDuplicateQuickLook else { return }
                if preview.isOpen || preview.isPreparing { preview.close() }
                else if case let (group, file)? = copy(id, in: shown) { openPreview(file.url, neighbors: group.files.map(\.url)) }
            }
            .filePreview(preview)
            // Le panneau montre les copies d'un groupe ; il suit la sélection
            // d'un groupe à l'autre, et la sélection suit ses flèches.
            .onChange(of: selection) {
                guard model.canUseDuplicateQuickLook, let selection, case let (group, file)? = copy(selection, in: shown) else { return }
                if (preview.isOpen || preview.isPreparing), preview.current != file.url, preview.preparingURL != file.url {
                    openPreview(file.url, neighbors: group.files.map(\.url))
                }
            }
            .onChange(of: model.duplicateExclusionRevision) {
                selection = nil
                preview.close()
            }
            .onChange(of: preview.current) { if let current = preview.current { selection = current.path } }
            if model.duplicateGroups.count > limit {
                Button { limit += 60 } label: { Text("group.show_more", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
        }
    }

    private func openPreview(_ url: URL, neighbors: [URL]) {
        requestDuplicateQuickLook(url, neighbors: neighbors, similar: false, model: model, preview: preview)
    }

    /// La copie d'un identifiant, et son groupe.
    private func copy(_ id: DuplicateFile.ID, in groups: [DuplicateGroup]) -> (DuplicateGroup, DuplicateFile)? {
        for group in groups {
            if let file = group.files.first(where: { $0.id == id }) { return (group, file) }
        }
        return nil
    }
}

private struct GroupCard: View {
    let model: AppModel
    let group: DuplicateGroup
    @Binding var selection: DuplicateFile.ID?
    /// Un coup d'œil sur une copie, les autres copies du groupe en voisines.
    let preview: (DuplicateFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Image(systemName: "doc.on.doc.fill").foregroundStyle(Palette.color(for: .duplicates))
                Text(verbatim: group.files.first?.url.lastPathComponent ?? "").font(Typography.headline).lineLimit(1)
                Spacer()
                Text(verbatim: L10n.string("duplicates.group_detail", Formatters.count(group.files.count),
                                           Formatters.compactBytes(group.size)))
                    .font(Typography.caption).foregroundStyle(.secondary)
                if group.keep == nil {
                    if model.duplicateKeep(group) != nil {
                        Tag(L10n.string("duplicates.auto_tie"), symbol: "wand.and.stars", tint: Palette.vivid(for: .review))
                    } else {
                        Tag(L10n.string("duplicates.tie"), symbol: "equal.circle", tint: Palette.vivid(for: .review))
                    }
                }
            }
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                CopyRow(model: model, group: group, index: index, file: file,
                        isSelected: selection == file.id,
                        select: { selection = file.id },
                        preview: { preview(file) })
                    .id(file.id)
            }
        }
        .padding(Spacing.large)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }
}

/// Une copie : la garder, la cocher, la voir.
private struct CopyRow: View {
    let model: AppModel
    let group: DuplicateGroup
    let index: Int
    let file: DuplicateFile
    let isSelected: Bool
    let select: () -> Void
    let preview: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.medium) {
            if model.duplicateKeep(group) == index {
                Image(systemName: "star.fill").foregroundStyle(Color(hex: 0xFFC233)).frame(width: 20)
                    .help(Text("duplicates.kept", bundle: .oust))
            } else if let item = model.duplicateItem(group: group, file: index) {
                let selectable = model.canSelectForCleanup(item)
                Button { model.toggle(item) } label: {
                    Image(systemName: !selectable ? "lock.circle" : (model.isInCart(item.id) ? "checkmark.circle.fill" : "circle"))
                        .foregroundStyle(model.isInCart(item.id) ? Palette.color(for: .duplicates) : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!selectable)
                .frame(width: 20)
            } else {
                Color.clear.frame(width: 20)
            }
            Text(verbatim: file.url.deletingLastPathComponent().path).font(Typography.caption)
                .lineLimit(1).truncationMode(.head)
            Spacer()
            if let modified = file.modified {
                Text(verbatim: Formatters.relative(modified)).font(Typography.caption).foregroundStyle(.secondary)
            }
            if file.privateSizeKnown {
                Text(verbatim: Formatters.compactBytes(file.privateSize))
                    .font(Typography.size).frame(width: 70, alignment: .trailing)
            } else {
                Image(systemName: "questionmark.circle")
                    .frame(width: 70, alignment: .trailing)
                    .help(Text("duplicates.private_size_unknown", bundle: .oust))
                    .accessibilityLabel(Text("duplicates.private_size_unknown", bundle: .oust))
            }
            if model.canUseDuplicateQuickLook {
                PreviewButton(isVisible: hovering || isSelected, action: preview)
            }
        }
        .padding(.vertical, Spacing.hair)
        .onHover { hovering = $0 }
        .previewRow(isSelected: isSelected, select: select, preview: preview)
        .contextMenu {
            if model.canUseDuplicateQuickLook { PreviewMenuItem(action: preview) }
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                Label { Text("row.reveal", bundle: .oust) } icon: { Image(systemName: "folder") }
            }
        }
    }
}
