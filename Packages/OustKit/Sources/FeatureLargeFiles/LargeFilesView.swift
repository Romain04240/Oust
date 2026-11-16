import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLargeFiles
import OustLocalization
import OustModel
import OustScan

/// Gros et vieux fichiers (SPEC §10, phase 2) : un filtre sur l'arborescence que
/// l'Explorateur a déjà parcourue. Rien n'est coché d'office.
public struct LargeFilesView: View {
    @Bindable var model: AppModel
    @State private var limit = 200

    public init(model: AppModel) {
        self.model = model
    }

    private var largeFiles: LargeFilesModel { model.largeFiles }

    public var body: some View {
        SectionScaffold(.largeFiles, subtitle: "largefiles.subtitle") {
            VolumeMenu(model: model)
        } content: {
            switch model.explorer {
            case .idle:
                EmptyState(symbol: "scalemass", title: "largefiles.empty_title", message: "largefiles.empty_detail")
                if let boot = model.bootVolume {
                    Button { model.explore(boot) } label: {
                        Text(verbatim: L10n.string("largefiles.analyze", boot.name))
                    }
                    .buttonStyle(PrimaryButtonStyle(section: .largeFiles))
                    .frame(maxWidth: .infinity)
                }
            case .running:
                Scanning(model: model)
                // Pendant le premier parcours, l'aperçu de Spotlight : en une
                // fraction de seconde au lieu de vingt.
                if !model.disk.spotlightFiles.isEmpty {
                    Text("largefiles.spotlight_preview", bundle: .oust)
                        .font(Typography.body).foregroundStyle(Palette.onGradient)
                        .fixedSize(horizontal: false, vertical: true)
                    Filters(largeFiles: largeFiles)
                    Results(model: model, limit: $limit)
                }
            case .done:
                Filters(largeFiles: largeFiles)
                Results(model: model, limit: $limit)
            }
        }
        .onAppear { largeFiles.refreshIfNeeded() }
        .task {
            while !Task.isCancelled {
                await largeFiles.revalidateGains()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
        .onChange(of: model.tree.map(ObjectIdentifier.init)) { largeFiles.refreshIfNeeded() }
        .onChange(of: model.disk.spotlightFiles) { largeFiles.refresh() }
    }
}

private struct VolumeMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(model.volumes) { volume in
                Button { model.explore(volume) } label: {
                    Label { Text(verbatim: volume.name) } icon: { Image(systemName: volume.symbol) }
                }
            }
        } label: {
            if let volume = model.treeVolume, model.explorer.hasRun {
                Text(verbatim: volume.name)
            } else {
                Text("explorer.analyze", bundle: .oust)
            }
        }
        .menuStyle(.button)
        .buttonStyle(OnGradientButtonStyle())
        .fixedSize()
        .disabled(model.explorer.isRunning)
    }
}

private struct Scanning: View {
    let model: AppModel

    var body: some View {
        GlassCard(padding: Spacing.xLarge) {
            HStack(spacing: Spacing.xLarge) {
                PulseOrb(section: .largeFiles, isActive: true, size: 140)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text(verbatim: L10n.string("explorer.scanning_volume", model.treeVolume?.name ?? ""))
                            .font(Typography.headline).foregroundStyle(Palette.onGradient)
                        Text(verbatim: L10n.string("explorer.scanning_counts", Formatters.count(model.scanProgress.fileCount),
                                                   Formatters.count(model.scanProgress.directoryCount)))
                            .font(Typography.body).foregroundStyle(Palette.onGradient)
                        Button { model.cancelExploration() } label: { Text("common.cancel", bundle: .oust) }
                            .buttonStyle(OnGradientButtonStyle())
                    }
                }
            }
        }
    }
}

private struct Filters: View {
    @Bindable var largeFiles: LargeFilesModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                HStack(spacing: Spacing.large) {
                    Picker(selection: $largeFiles.size) {
                        ForEach(LargeFilesModel.SizePreset.allCases) { preset in
                            Text(verbatim: L10n.string("largefiles.at_least", Formatters.compactBytes(preset.rawValue))).tag(preset)
                        }
                    } label: {
                        Text("largefiles.size", bundle: .oust)
                    }
                    .fixedSize()
                    Picker(selection: $largeFiles.age) {
                        ForEach(LargeFilesModel.AgePreset.allCases) { preset in
                            Text(LocalizedStringKey(preset.localizationKey), bundle: .oust).tag(preset)
                        }
                    } label: {
                        Text("largefiles.unused", bundle: .oust)
                    }
                    .fixedSize()
                    Spacer()
                    if largeFiles.computing { ProgressView().controlSize(.small) }
                }
                // La famille d'un fichier, d'un clic ; aucune cochée : toutes.
                // Colonnes de 170 pt et une seule ligne : à 140, « Images disque
                // et VM » passait sur deux lignes et dépassait des autres puces.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Spacing.small, alignment: .leading)],
                          alignment: .leading, spacing: Spacing.small) {
                    ForEach(FileKind.allCases) { kind in
                        let on = largeFiles.kinds.contains(kind)
                        Button { largeFiles.toggleKind(kind) } label: {
                            Label { Text(LocalizedStringKey(kind.localizationKey), bundle: .oust) } icon: {
                                Image(systemName: kind.symbol)
                            }
                            .lineLimit(1)
                            .font(Typography.caption.weight(.semibold))
                            .padding(.horizontal, Spacing.small)
                            .padding(.vertical, Spacing.tight)
                            .foregroundStyle(Palette.onGradient)
                            .background(on ? AnyShapeStyle(Palette.color(for: .largeFiles).opacity(0.55))
                                           : AnyShapeStyle(Color.black.opacity(0.25)), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(on ? 0.6 : 0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                Text("largefiles.dates_note", bundle: .oust)
                    .font(Typography.caption).foregroundStyle(Palette.onGradient)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Results: View {
    let model: AppModel
    @Binding var limit: Int
    @State private var preview = FilePreview()
    @State private var selection: LargeFileMatch.ID?

    private var largeFiles: LargeFilesModel { model.largeFiles }

    var body: some View {
        if let result = largeFiles.result {
            // Sans résultat, l'état vide suffit : le « 0 » géant, rendu en tiret
            // de 64 pt, ressemblait à une barre blanche posée sur le dégradé.
            if !result.files.isEmpty {
                HStack(alignment: .bottom) {
                    HeroSize(result.matchBytes, caption: nil)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(verbatim: L10n.string("largefiles.count", Formatters.count(result.matchCount)))
                            .font(Typography.headline).foregroundStyle(Palette.onGradient)
                        if result.matchCount > result.files.count {
                            Text(verbatim: L10n.string("largefiles.capped", Formatters.count(result.files.count)))
                                .font(Typography.caption).foregroundStyle(Palette.onGradient)
                        }
                    }
                    Spacer()
                }
            }
            if result.files.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: "largefiles.none_title", message: "largefiles.none_detail")
            } else {
                // Les lignes affichées, dans l'ordre : les voisins du coup d'œil.
                let shown = Array(result.files.prefix(limit))
                let urls = shown.map(\.url)
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { file in
                            FileRow(file: file, item: largeFiles.item(for: file), model: model,
                                    isSelected: selection == file.id,
                                    select: { selection = file.id },
                                    preview: { preview.show(file.url, among: urls) })
                                .id(file.id)
                            Divider().opacity(0.25)
                        }
                    }
                    if result.files.count > limit {
                        Button { limit += 200 } label: { Text("group.show_more", bundle: .oust) }
                            .buttonStyle(.borderless)
                            .padding(.vertical, Spacing.small)
                    }
                }
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.small)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .previewKeys(selection: $selection, order: shown.map(\.id)) { id in
                    if let file = shown.first(where: { $0.id == id }) { preview.toggle(file.url, among: urls) }
                }
                .filePreview(preview)
                // Le panneau et la liste se suivent : les flèches de l'un
                // déplacent la sélection de l'autre.
                .onChange(of: selection) { preview.follow(shown.first { $0.id == selection }?.url, among: urls) }
                .onChange(of: preview.current) { if let current = preview.current { selection = current.path } }
            }
        }
    }
}

private struct FileRow: View {
    let file: LargeFileMatch
    let item: CleanupItem
    let model: AppModel
    let isSelected: Bool
    let select: () -> Void
    let preview: () -> Void
    @State private var hovering = false

    var body: some View {
        let inCart = model.isInCart(item.id)
        HStack(spacing: Spacing.medium) {
            Button { model.toggle(item) } label: {
                Image(systemName: !model.canSelectForCleanup(item) ? "lock.circle" : (inCart ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(inCart ? Palette.color(for: .largeFiles) : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSelectForCleanup(item))
            .accessibilityLabel(Text(inCart ? "row.remove_from_cart" : "row.add_to_cart", bundle: .oust))
            .help(Text(verbatim: item.protections.first.map(Describe.protection) ?? L10n.string("row.add_to_cart")))

            Image(systemName: file.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Palette.color(for: .largeFiles).gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(verbatim: file.url.lastPathComponent).font(Typography.body.weight(.semibold)).lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: file.url.deletingLastPathComponent().path)
                    .font(Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: Spacing.medium)
            if let reason = item.protections.first {
                // Le nom du fichier se tronque d'abord ; la raison, elle, a une
                // largeur plafonnée. Sans plafond, celle d'un paquet .mlmodelc au nom
                // de 120 caractères débordait de la carte (vérification du
                // 18/10/2026). Coupée au milieu, elle garde son début et sa fin.
                Tag(Describe.protection(reason), symbol: "lock.fill", tint: Palette.vivid(for: .protected), truncation: .middle)
                    .frame(maxWidth: 320, alignment: .trailing)
                    .layoutPriority(1)
            }
            Text(verbatim: file.lastUse.map { L10n.string("largefiles.last_use", Formatters.relative($0)) }
                 ?? L10n.string("largefiles.no_date"))
                .font(Typography.caption).foregroundStyle(.secondary)
                .frame(width: 170, alignment: .trailing)
            Text(verbatim: Formatters.compactBytes(file.sizes.allocated)).font(Typography.size)
                .frame(width: 80, alignment: .trailing)
            PreviewButton(isVisible: hovering || isSelected, action: preview)
        }
        .padding(.vertical, Spacing.tight)
        .onHover { hovering = $0 }
        .previewRow(isSelected: isSelected, select: select, preview: preview)
        .onTapGesture(count: 2) { model.toggle(item) }
        .contextMenu {
            PreviewMenuItem(action: preview)
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                Label { Text("row.reveal", bundle: .oust) } icon: { Image(systemName: "folder") }
            }
            Button {
                model.transfer.present(sources: [file.url])
                model.searchText = ""
                model.section = .transfer
            } label: {
                Label { Text("advice.prepare_transfer", bundle: .oust) } icon: { Image(systemName: "externaldrive") }
            }
            .disabled(!model.canSelectForCleanup(item) || model.transfer.isRunning)
            Button { model.toggle(item) } label: {
                Label { Text(inCart ? "row.remove_from_cart" : "row.add_to_cart", bundle: .oust) } icon: { Image(systemName: "trash") }
            }
            .disabled(!model.canSelectForCleanup(item))
        }
    }
}
