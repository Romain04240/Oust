import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustDuplicates
import OustLocalization
import OustModel

// MARK: - Onglets

/// Identiques ou similaires : deux recherches, une section.
struct DuplicatesTabs: View {
    let model: AppModel

    private var similar: SimilarImagesModel { model.similarImages }

    var body: some View {
        HStack(spacing: Spacing.small) {
            tab(on: !similar.isSelected, symbol: ItemCategory.duplicates.symbol, title: "duplicates.tab.identical",
                summary: identicalSummary) { similar.isSelected = false }
            tab(on: similar.isSelected, symbol: ItemCategory.similarImages.symbol, title: "duplicates.tab.similar",
                summary: similarSummary) { similar.isSelected = true }
        }
    }

    private var identicalSummary: String {
        guard model.duplicates.hasRun else { return L10n.string("duplicates.tab.on_demand") }
        return summary(model.duplicateGroups.count, model.reclaimableDuplicateBytes)
    }

    private var similarSummary: String {
        guard similar.phase.hasRun else { return L10n.string("duplicates.tab.on_demand") }
        return summary(similar.groups.count, similar.potential)
    }

    private func summary(_ count: Int, _ size: Int64) -> String {
        switch count {
        case 0: L10n.string("duplicates.tab.none")
        case 1: L10n.string("duplicates.tab.groups_one", Formatters.compactBytes(size))
        default: L10n.string("duplicates.tab.groups", Formatters.count(count), Formatters.compactBytes(size))
        }
    }

    /// Comme les onglets de Photos : le profond de la section pour l'onglet
    /// choisi, qui fonce le fond au lieu de l'éclaircir (IDENTITE §4, règle 3).
    private func tab(on: Bool, symbol: String, title: LocalizedStringKey, summary: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.small) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title, bundle: .oust).font(Typography.body.weight(.semibold))
                    Text(verbatim: summary).font(Typography.caption).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .foregroundStyle(Palette.onGradient)
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.small)
            .frame(maxWidth: 260)
            .background(on ? AnyShapeStyle(Palette.colors(for: .duplicates).deep.opacity(0.6))
                           : AnyShapeStyle(Color.black.opacity(0.18)),
                        in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(.white.opacity(on ? 0.75 : 0.18), lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Le bouton d'en-tête de l'onglet « Similaires » : absent avant la première
/// recherche, que la carte de départ propose avec ses dossiers.
struct SimilarSearchButton: View {
    let similar: SimilarImagesModel

    var body: some View {
        if similar.phase != .idle {
            Button { Task { await similar.search() } } label: {
                Text(similar.phase.isRunning ? "duplicates.searching" : "similar.again", bundle: .oust)
            }
            .buttonStyle(OnGradientButtonStyle())
            .disabled(similar.phase.isRunning || similar.folders.isEmpty)
        }
    }
}

// MARK: - Contenu

/// Les images qui se ressemblent dans les dossiers, hors photothèque : sur
/// demande, puis groupe par groupe, la meilleure marquée d'une étoile et rien
/// de coché (RULES.md, règle 4).
struct SimilarImagesContent: View {
    let model: AppModel
    let preview: FilePreview

    private var similar: SimilarImagesModel { model.similarImages }

    var body: some View {
        switch similar.phase {
        case .idle:
            SimilarStart(similar: similar)
        case .running:
            SimilarWorking(progress: similar.progress, onCancel: similar.cancel)
        case .done:
            SimilarResults(model: model, preview: preview)
        }
    }
}

private struct SimilarStart: View {
    let similar: SimilarImagesModel

    var body: some View {
        GlassCard(padding: Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text("similar.title", bundle: .oust).font(Typography.headline).foregroundStyle(Palette.onGradient)
                Text("similar.detail", bundle: .oust).font(Typography.body).foregroundStyle(Palette.onGradient)
                    .fixedSize(horizontal: false, vertical: true)
                FolderList(similar: similar)
                Promises()
                HStack {
                    Spacer()
                    Button { Task { await similar.search() } } label: { Text("similar.search", bundle: .oust) }
                        .buttonStyle(PrimaryButtonStyle(section: .duplicates))
                        .disabled(similar.folders.isEmpty)
                }
            }
        }
    }
}

/// Ce qui est parcouru, et de quoi en ajouter ou en retirer.
private struct FolderList: View {
    let similar: SimilarImagesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("similar.folders", bundle: .oust).font(Typography.body.weight(.semibold)).foregroundStyle(Palette.onGradient)
            if similar.folders.isEmpty {
                Text("similar.no_folder", bundle: .oust).font(Typography.caption).foregroundStyle(Palette.onGradient)
            }
            ForEach(similar.folders, id: \.self) { folder in
                HStack(spacing: Spacing.small) {
                    Image(systemName: "folder.fill").foregroundStyle(Palette.onGradient).frame(width: 18)
                    Text(verbatim: (folder.path as NSString).abbreviatingWithTildeInPath)
                        .font(Typography.body).foregroundStyle(Palette.onGradient)
                        .lineLimit(1).truncationMode(.head)
                    Spacer(minLength: Spacing.small)
                    Button { similar.removeFolder(folder) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.onGradient.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .disabled(similar.phase.isRunning)
                    .help(Text("similar.remove_folder", bundle: .oust))
                    .accessibilityLabel(Text("similar.remove_folder", bundle: .oust))
                }
                .padding(.vertical, Spacing.hair)
            }
            Button(action: chooseFolders) {
                Label { Text("similar.add_folder", bundle: .oust) } icon: { Image(systemName: "plus") }
            }
            .buttonStyle(OnGradientButtonStyle())
            .disabled(similar.phase.isRunning)
            .padding(.top, Spacing.tight)
        }
    }

    /// Le panneau de macOS : on n'y choisit que des dossiers, jamais créés ni modifiés.
    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = L10n.string("similar.add_folder_prompt")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { similar.addFolder(url) }
    }
}

/// Ce qui n'est jamais lu, et ce qui ne sort jamais du Mac.
private struct Promises: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            line("lock.shield", "similar.privacy")
            line("nosign", "similar.never")
            line("exclamationmark.triangle", "similar.catalog_warning")
        }
    }

    private func line(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        Label {
            Text(key, bundle: .oust).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).frame(width: 20)
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.onGradient)
    }
}

private struct SimilarWorking: View {
    let progress: SimilarImageProgress
    let onCancel: () -> Void

    var body: some View {
        GlassCard(padding: Spacing.xLarge) {
            HStack(spacing: Spacing.xLarge) {
                PulseOrb(section: .duplicates, isActive: true, size: 140)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text(verbatim: stage)
                            .font(Typography.headline).foregroundStyle(Palette.onGradient)
                            .monospacedDigit()
                        Text("similar.privacy", bundle: .oust)
                            .font(Typography.caption).foregroundStyle(Palette.onGradient)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: onCancel) { Text("common.cancel", bundle: .oust) }
                            .buttonStyle(OnGradientButtonStyle())
                    }
                }
            }
        }
    }

    private var stage: String {
        let done = Formatters.count(progress.done)
        let total = Formatters.count(progress.total)
        switch progress.stage {
        case .listing: return L10n.string("similar.stage.listing", done)
        case .reading: return L10n.string("similar.stage.reading", done, total)
        case .printing: return L10n.string("similar.stage.printing", done, total)
        case .comparing: return L10n.string("similar.stage.comparing")
        }
    }
}

// MARK: - Résultats

private struct SimilarResults: View {
    let model: AppModel
    @State private var limit = 40
    @State private var editingFolders = false
    let preview: FilePreview
    @State private var selection: SimilarImage.ID?

    private var similar: SimilarImagesModel { model.similarImages }

    var body: some View {
        let groups = similar.groups
        let reclaimable = similar.potential
        if reclaimable > 0 {
            HStack(alignment: .bottom) {
                HeroSize(reclaimable, caption: "similar.total_caption")
                Spacer()
            }
        }
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.small) {
                note("star.fill", L10n.string("similar.never_checked"))
                note("photo.stack", similar.examined == 1 ? L10n.string("similar.examined_one")
                     : L10n.string("similar.examined", Formatters.count(similar.examined)))
                if similar.skippedInCloud > 0 {
                    note("icloud", similar.skippedInCloud == 1 ? L10n.string("similar.in_cloud_one")
                         : L10n.string("similar.in_cloud", Formatters.count(similar.skippedInCloud)))
                }
                if similar.hiddenCloneGroups > 0 {
                    note("square.on.square", similar.hiddenCloneGroups == 1 ? L10n.string("similar.clones_one")
                         : L10n.string("similar.clones", Formatters.count(similar.hiddenCloneGroups)))
                }
                if similar.unreadable > 0 {
                    note("questionmark.circle", similar.unreadable == 1 ? L10n.string("similar.unreadable_one")
                         : L10n.string("similar.unreadable", Formatters.count(similar.unreadable)))
                }
                Button { editingFolders.toggle() } label: {
                    Label { Text("similar.folders", bundle: .oust) } icon: {
                        Image(systemName: editingFolders ? "chevron.down" : "chevron.right")
                    }
                }
                .buttonStyle(OnGradientButtonStyle())
                if editingFolders {
                    FolderList(similar: similar)
                    Promises()
                }
            }
        }
        if groups.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: "similar.none_title", message: "similar.none_detail")
        }
        let shown = Array(groups.prefix(limit))
        // Le clavier va au VStack, comme pour les identiques : posé sur la pile
        // paresseuse, il ne le recevait pas.
        VStack(spacing: 0) {
            LazyVStack(spacing: Spacing.medium) {
                ForEach(shown) { group in
                    SimilarGroupCard(model: model, group: group, selection: $selection) { image in
                        guard model.canUseDuplicateQuickLook else { return }
                        selection = image.id
                        openPreview(image.url, neighbors: group.images.map(\.url))
                    }
                }
            }
        }
        .previewKeys(selection: $selection, order: shown.flatMap { $0.images.map(\.id) }) { id in
            guard model.canUseDuplicateQuickLook else { return }
            if preview.isOpen || preview.isPreparing { preview.close() }
            else if case let (group, image)? = find(id, in: shown) { openPreview(image.url, neighbors: group.images.map(\.url)) }
        }
        .filePreview(preview)
        // Le panneau montre les images d'un groupe ; il suit la sélection d'un
        // groupe à l'autre, et la sélection suit ses flèches.
        .onChange(of: selection) {
            guard model.canUseDuplicateQuickLook, let selection, case let (group, image)? = find(selection, in: shown) else { return }
            if (preview.isOpen || preview.isPreparing), preview.current != image.url, preview.preparingURL != image.url {
                openPreview(image.url, neighbors: group.images.map(\.url))
            }
        }
        .onChange(of: preview.current) { if let current = preview.current { selection = current.path } }
        if groups.count > limit {
            Button { limit += 40 } label: { Text("group.show_more", bundle: .oust) }
                .buttonStyle(OnGradientButtonStyle())
        }
    }

    private func openPreview(_ url: URL, neighbors: [URL]) {
        requestDuplicateQuickLook(url, neighbors: neighbors, similar: true, model: model, preview: preview)
    }

    /// L'image d'un identifiant, et son groupe.
    private func find(_ id: SimilarImage.ID, in groups: [SimilarImageGroup]) -> (SimilarImageGroup, SimilarImage)? {
        for group in groups {
            if let image = group.images.first(where: { $0.id == id }) { return (group, image) }
        }
        return nil
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).frame(width: 20)
        }
        .font(Typography.body)
        .foregroundStyle(Palette.onGradient)
    }
}

private struct SimilarGroupCard: View {
    let model: AppModel
    let group: SimilarImageGroup
    @Binding var selection: SimilarImage.ID?
    let open: (SimilarImage) -> Void

    private var similar: SimilarImagesModel { model.similarImages }

    var body: some View {
        let paths = similar.cartPaths()
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.small) {
                Image(systemName: ItemCategory.similarImages.symbol).foregroundStyle(Palette.color(for: .similarImages))
                Text(verbatim: group.best?.url.lastPathComponent ?? "").font(Typography.headline).lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(verbatim: L10n.string("similar.group_detail", Formatters.count(group.images.count),
                                           Formatters.compactBytes(similar.reclaimableBytes(in: group))))
                    .font(Typography.caption).foregroundStyle(.secondary).monospacedDigit()
                // Un geste de l'utilisateur, groupe par groupe : jamais fait d'office.
                Button { similar.keepBest(in: group) } label: { Text("similar.keep_best", bundle: .oust).font(Typography.caption) }
                    .buttonStyle(.borderless)
                    .help(Text(model.canMoveFiles ? "similar.keep_best_help" : "agent.refusal.unavailable", bundle: .oust))
                    .disabled(!similar.canKeepBest(in: group, paths: paths))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: Spacing.medium, alignment: .top)],
                      alignment: .leading, spacing: Spacing.medium) {
                ForEach(group.images) { image in
                    SimilarTile(model: model, group: group, image: image, paths: paths,
                                isSelected: selection == image.id, open: { open(image) })
                        .id(image.id)
                }
            }
        }
        .padding(Spacing.large)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }

}

/// Une image d'un groupe : la voir avant de choisir.
private struct SimilarTile: View {
    let model: AppModel
    let group: SimilarImageGroup
    let image: SimilarImage
    let paths: Set<String>
    let isSelected: Bool
    let open: () -> Void
    @State private var explaining = false

    private var similar: SimilarImagesModel { model.similarImages }

    var body: some View {
        let inCart = similar.isInCart(image, paths: paths)
        let item = similar.item(for: image, in: group)
        let restriction = similar.selectionRestriction(for: image, in: group, paths: paths)
        let enabled = restriction == nil
        let selectionLabel = restriction?.localizationKey ?? (inCart ? "row.remove_from_cart" : "row.add_to_cart")
        let isBest = group.best == image
        VStack(alignment: .leading, spacing: Spacing.tight) {
            // Un bouton : l'ouvrir choisit aussi la tuile (la barre d'espace et
            // les flèches prennent ensuite le relais).
            Button(action: open) {
                Thumbnail(similar: similar, url: image.url)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!model.canUseDuplicateQuickLook)
            .help(Text(model.canUseDuplicateQuickLook ? "quicklook.help" : "duplicates.exclusions_preview", bundle: .oust))
            .accessibilityLabel(Text(verbatim: image.url.lastPathComponent))
            .accessibilityHint(Text("quicklook.action", bundle: .oust))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(inCart ? Palette.color(for: .similarImages) : .clear, lineWidth: 3))
            .overlay(alignment: .topLeading) {
                Button { similar.toggle(image, in: group) } label: {
                    Image(systemName: inCart ? "checkmark.circle.fill" : (enabled ? "circle" : "lock.circle"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(inCart ? AnyShapeStyle(Palette.color(for: .similarImages)) : AnyShapeStyle(.white))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .padding(Spacing.tight)
                .background(.black.opacity(0.35), in: Circle())
                .padding(Spacing.tight)
                .help(Text(verbatim: L10n.string(selectionLabel)))
                .accessibilityLabel(Text(verbatim: L10n.string(selectionLabel)))
            }
            .overlay(alignment: .topTrailing) {
                if isBest {
                    Image(systemName: "star.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: 0xFFC233))
                        .padding(6)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(Spacing.tight)
                        .help(Text("similar.best_help", bundle: .oust))
                        .accessibilityLabel(Text("similar.best", bundle: .oust))
                }
            }
            // Choisie : un liseré blanc autour, distinct de celui de la corbeille.
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: Radius.small + 3, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2))
            HStack(spacing: Spacing.tight) {
                Text(verbatim: image.url.lastPathComponent).font(Typography.caption.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { explaining.toggle() } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $explaining, arrowEdge: .trailing) { Explanation(item: item) }
                .accessibilityLabel(Text("row.why", bundle: .oust))
            }
            HStack(spacing: Spacing.tight) {
                Text(verbatim: L10n.string("similar.dimensions", Formatters.count(image.pixelWidth),
                                           Formatters.count(image.pixelHeight)))
                    .font(Typography.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
                Text(verbatim: Formatters.compactBytes(item.sizes.freeable)).font(Typography.size)
            }
            Text(verbatim: (image.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                .font(Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            if let date = image.captured ?? image.modified {
                Text(verbatim: date.formatted(date: .abbreviated, time: .shortened))
                    .font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !image.privateSizeKnown {
                Tag(L10n.string("duplicates.private_size_unknown"), symbol: "questionmark.circle", tint: .secondary)
            } else if image.isClone {
                Tag(L10n.string("similar.clone_tag"), symbol: "square.on.square", tint: .secondary)
                    .help(Text("similar.clone_help", bundle: .oust))
            }
            if isBest {
                Tag(L10n.string("similar.best"), symbol: "star.fill", tint: Palette.vivid(for: .safe))
            } else if let restriction {
                Tag(L10n.string(restriction.localizationKey), symbol: "lock.fill", tint: Palette.vivid(for: .review))
            }
        }
        .contextMenu {
            if model.canUseDuplicateQuickLook { PreviewMenuItem(action: open) }
            Button { NSWorkspace.shared.activateFileViewerSelecting([image.url]) } label: {
                Label { Text("row.reveal", bundle: .oust) } icon: { Image(systemName: "folder") }
            }
        }
    }
}

/// Une vignette décodée à la demande, sans réseau : un fichier iCloud non
/// téléchargé n'est jamais dans un groupe. En attendant, un pictogramme.
private struct Thumbnail: View {
    let similar: SimilarImagesModel
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        // La couleur prend la place proposée ; l'image la remplit en surimpression,
        // rognée à ce cadre (dans un ZStack, elle débordait de la carte).
        Color.white.opacity(0.08)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: url) { image = await similar.thumbnail(for: url, side: 360) }
    }
}
