import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustScan

/// L'Explorateur, à la manière de TreeSize (SPEC §3.3) : l'arborescence d'un
/// volume en colonnes triables, avec la recherche, les types de fichiers,
/// leur âge, les plus gros fichiers et l'évolution depuis la dernière analyse.
public struct ExplorerView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            SectionBackground(.explorer)
            VStack(alignment: .leading, spacing: Spacing.large) {
                SectionHeader(.explorer, subtitle: "explorer.subtitle") {
                    HStack(spacing: Spacing.small) {
                        RescanButton(model: model)
                        VolumePicker(model: model)
                    }
                }
                switch model.explorer {
                case .idle:
                    VolumeChooser(model: model)
                    Spacer()
                case .running:
                    ScanningCard(model: model)
                    Spacer()
                case .done:
                    if let root = model.tree {
                        ExplorerContent(model: model, root: root, volumeName: model.treeVolume?.name ?? root.name)
                            .id(ObjectIdentifier(root))
                    }
                }
            }
            .padding(Spacing.xxLarge)
            .onSectionBackground()
        }
    }
}

// MARK: - Choix du volume et analyse

/// L'analyse d'un autre disque est gardée d'une fois sur l'autre : on dit de
/// quand elle date, et de quoi la refaire (Romain, 18/10/2026).
private struct RescanButton: View {
    let model: AppModel

    var body: some View {
        if case .done(let date) = model.explorer, let volume = model.treeVolume, !volume.isBoot,
           model.volumes.contains(where: { $0.id == volume.id }) {
            Button { model.reanalyze(volume) } label: {
                Label { Text("disks.reanalyze", bundle: .oust) } icon: { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(OnGradientButtonStyle())
            .help(Text(verbatim: L10n.string("disks.analyzed_at", Formatters.timestamp(date))))
        }
    }
}

private struct VolumePicker: View {
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(model.volumes) { volume in
                Button { model.explore(volume) } label: {
                    Label { Text(verbatim: volume.name) } icon: { Image(systemName: volume.symbol) }
                }
            }
            Divider()
            Button { chooseFolder() } label: {
                Label { Text("explorer.choose_folder", bundle: .oust) } icon: { Image(systemName: "folder") }
            }
        } label: {
            Text(model.explorer.isRunning ? "explorer.scanning" : "explorer.analyze", bundle: .oust)
        }
        .menuStyle(.button)
        .buttonStyle(OnGradientButtonStyle())
        .fixedSize()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.explore(folder: url) }
    }
}

/// Au départ, comme TreeSize : les disques, chacun avec sa jauge et un bouton
/// pour l'analyser, et de quoi choisir un dossier précis.
private struct VolumeChooser: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("explorer.empty_detail", bundle: .oust)
                .font(Typography.body)
                .foregroundStyle(Palette.onGradient)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Spacing.medium)], spacing: Spacing.medium) {
                ForEach(model.volumes) { volume in
                    GlassCard {
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            HStack {
                                Image(systemName: volume.symbol).font(.system(size: 22, weight: .semibold))
                                Text(verbatim: volume.name).font(Typography.headline)
                                Spacer()
                            }
                            StorageBar(capacity: volume.capacity, selected: 0)
                            Text(verbatim: L10n.string("overview.volume_usage", Formatters.compactBytes(volume.capacity.used),
                                                       Formatters.compactBytes(volume.capacity.total)))
                                .font(Typography.caption)
                            Button { model.explore(volume) } label: { Text("explorer.analyze_volume", bundle: .oust) }
                                .buttonStyle(PrimaryButtonStyle(section: .explorer))
                                .padding(.top, Spacing.tight)
                        }
                        .foregroundStyle(Palette.onGradient)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        HStack {
                            Image(systemName: "folder.badge.gearshape").font(.system(size: 22, weight: .semibold))
                            Text("explorer.choose_folder", bundle: .oust).font(Typography.headline)
                        }
                        Text("explorer.choose_folder_detail", bundle: .oust).font(Typography.caption)
                        Button { chooseFolder() } label: { Text("explorer.choose", bundle: .oust) }
                            .buttonStyle(OnGradientButtonStyle())
                            .padding(.top, Spacing.tight)
                    }
                    .foregroundStyle(Palette.onGradient)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.explore(folder: url) }
    }
}

private struct ScanningCard: View {
    let model: AppModel

    var body: some View {
        GlassCard(padding: Spacing.xLarge) {
            HStack(spacing: Spacing.xLarge) {
                PulseOrb(section: .explorer, isActive: true, size: 160)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text(verbatim: L10n.string("explorer.scanning_volume", model.treeVolume?.name ?? ""))
                            .font(Typography.headline).foregroundStyle(Palette.onGradient)
                        Text(verbatim: Formatters.compactBytes(model.scanProgress.allocatedBytes))
                            .font(Typography.hero).foregroundStyle(Palette.onGradient)
                            .contentTransition(.numericText(value: Double(model.scanProgress.allocatedBytes)))
                        Text(verbatim: L10n.string("explorer.scanning_counts", Formatters.count(model.scanProgress.fileCount),
                                                   Formatters.count(model.scanProgress.directoryCount)))
                            .font(Typography.body).foregroundStyle(Palette.onGradientSecondary)
                        Button { model.cancelExploration() } label: { Text("common.cancel", bundle: .oust) }
                            .buttonStyle(OnGradientButtonStyle())
                    }
                }
            }
        }
    }
}

// MARK: - Contenu

private struct ExplorerContent: View {
    let model: AppModel
    let root: TreeNode
    let volumeName: String
    // Créé une fois par arbre, dans `.task`. Construit dans `init`, il l'était à
    // chaque rendu du parent, et chaque instance relançait les statistiques sur
    // tout le disque : 100 % d'un cœur tant que l'Explorateur restait affiché
    // (vérification du 18/10/2026).
    @State private var state: ExplorerState?

    init(model: AppModel, root: TreeNode, volumeName: String) {
        self.model = model
        self.root = root
        self.volumeName = volumeName
    }

    var body: some View {
        Group {
            if let state { content(state) } else { Color.clear }
        }
        .task(id: ObjectIdentifier(root)) {
            let state = ExplorerState(root: root, volumeName: volumeName)
            self.state = state
            await state.prepare()
        }
    }

    private func content(_ state: ExplorerState) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Summary(state: state)
            Toolbar(state: state, model: model)
            Group {
                switch state.tab {
                case .tree:
                    if state.query.trimmingCharacters(in: .whitespaces).count >= 2 {
                        SearchResults(state: state, model: model)
                    } else {
                        TreeTable(state: state, model: model)
                    }
                case .sunburst:
                    // Le même dossier ouvert que l'arborescence : entrer dans un
                    // anneau, c'est ouvrir le dossier.
                    SunburstView(focus: state.focus, model: model) { state.open($0) }
                        .padding(Spacing.large)
                case .types: TypesTab(state: state)
                case .ages: AgesTab(state: state)
                case .largest: LargestTab(state: state, model: model)
                case .growth: GrowthTab(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Le chiffre du volume, ses comptes, et ce qui a changé depuis la dernière fois.
private struct Summary: View {
    let state: ExplorerState

    var body: some View {
        let root = state.root
        HStack(alignment: .center, spacing: Spacing.large) {
            HeroSize(state.focus.total.allocated, caption: nil)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(verbatim: state.focus === root ? state.volumeName : state.focus.name)
                    .font(Typography.headline).foregroundStyle(Palette.onGradient)
                // Les dossiers ne sont comptés qu'une fois les statistiques prêtes :
                // avant, l'en-tête annonçait « 0 dossiers » pendant deux ou trois
                // secondes après chaque arbre neuf (vérification du 18/10/2026).
                Text(verbatim: state.analytics == nil
                     ? L10n.string("explorer.summary", Formatters.count(state.focus.fileCount),
                                   Formatters.compactBytes(state.focus.total.freeable))
                     : L10n.string("explorer.summary_full", Formatters.count(state.focus.fileCount),
                                   Formatters.count(state.folders(in: state.focus)),
                                   Formatters.compactBytes(state.focus.total.freeable)))
                    .font(Typography.body).foregroundStyle(Palette.onGradient)
                HStack(spacing: Spacing.large) {
                    if root.inaccessibleCount > 0 {
                        Label { Text(verbatim: L10n.string("explorer.inaccessible", Formatters.count(root.inaccessibleCount))) }
                            icon: { Image(systemName: "lock.fill") }
                    }
                    if let previous = state.previous, let delta = state.delta(for: state.focus) {
                        Label {
                            Text(verbatim: L10n.string("explorer.since_last", Growth.text(delta), Formatters.timestamp(previous.date)))
                        } icon: { Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right") }
                    }
                }
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Palette.onGradient)
            }
            Spacer()
        }
    }
}

/// Onglets et export sur la première ligne ; fil d'Ariane, recherche et
/// options du tableau sur la seconde. D'un seul tenant, la barre débordait de
/// la fenêtre et repliait la barre latérale.
private struct Toolbar: View {
    @Bindable var state: ExplorerState
    let model: AppModel

    // La barre s'adapte à la place disponible au lieu de déborder : avec six
    // onglets, la version d'un seul tenant écrasait « Exporter » en haute colonne,
    // ce qui creusait de grands vides verticaux et poussait la recherche hors de
    // la fenêtre (Romain, 18/10/2026). `ViewThatFits` prend la première variante
    // qui tient : onglets en toutes lettres, puis en icônes, puis en menu.
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ViewThatFits(in: .horizontal) {
                firstRow(tabs: .text, compactButtons: false)
                firstRow(tabs: .text, compactButtons: true)
                firstRow(tabs: .icons, compactButtons: true)
                firstRow(tabs: .menu, compactButtons: true)
            }
            if state.tab == .tree {
                HStack(spacing: Spacing.medium) {
                    // Le fil d'Ariane défile plutôt que de pousser le reste dehors.
                    ScrollView(.horizontal, showsIndicators: false) {
                        Breadcrumb(state: state).fixedSize()
                    }
                    .frame(minWidth: 80)
                    .layoutPriority(0)
                    HStack(spacing: Spacing.tight) {
                        Image(systemName: "magnifyingglass")
                        TextField(text: $state.query) { Text("explorer.search_prompt", bundle: .oust) }
                            .textFieldStyle(.plain)
                            .frame(minWidth: 90, idealWidth: 180, maxWidth: 200)
                        if state.searching { ProgressView().controlSize(.mini) }
                    }
                    .padding(.horizontal, Spacing.small)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .layoutPriority(1)
                    Picker(selection: $state.metric) {
                        Text("explorer.metric.size", bundle: .oust).tag(ExplorerState.Metric.size)
                        Text("explorer.metric.files", bundle: .oust).tag(ExplorerState.Metric.files)
                    } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .layoutPriority(2)
                    Toggle(isOn: $state.showFiles) { Text("explorer.show_files", bundle: .oust) }
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .layoutPriority(2)
                }
                .controlSize(.small)
            }
        }
    }

    private enum TabStyle { case text, icons, menu }

    /// Onglets à gauche, actions à droite, dans la forme demandée.
    private func firstRow(tabs style: TabStyle, compactButtons: Bool) -> some View {
        HStack(spacing: Spacing.medium) {
            switch style {
            case .text:
                Picker(selection: $state.tab) {
                    ForEach(ExplorerState.Tab.allCases) { tab in
                        Text(LocalizedStringKey(tab.localizationKey), bundle: .oust).tag(tab)
                    }
                } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            case .icons:
                Picker(selection: $state.tab) {
                    ForEach(ExplorerState.Tab.allCases) { tab in
                        Image(systemName: tab.symbol)
                            .help(Text(LocalizedStringKey(tab.localizationKey), bundle: .oust))
                            .accessibilityLabel(Text(LocalizedStringKey(tab.localizationKey), bundle: .oust))
                            .tag(tab)
                    }
                } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            case .menu:
                Picker(selection: $state.tab) {
                    ForEach(ExplorerState.Tab.allCases) { tab in
                        Label { Text(LocalizedStringKey(tab.localizationKey), bundle: .oust) } icon: { Image(systemName: tab.symbol) }
                            .tag(tab)
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 0)
            if !state.selection.isEmpty {
                Button { throwSelection() } label: {
                    Label { Text(verbatim: L10n.string("explorer.throw_selection", Formatters.count(state.selection.count))) }
                        icon: { Image(systemName: "trash") }
                        .lineLimit(1)
                }
                .buttonStyle(OnGradientButtonStyle())
                .fixedSize()
            }
            Button { export() } label: {
                if compactButtons {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityLabel(Text("explorer.export", bundle: .oust))
                } else {
                    Label { Text("explorer.export", bundle: .oust) } icon: { Image(systemName: "square.and.arrow.up") }
                        .lineLimit(1)
                }
            }
            .buttonStyle(OnGradientButtonStyle())
            .fixedSize()
            .help(Text("explorer.export", bundle: .oust))
            .disabled(state.analytics == nil)
        }
    }

    /// Tout ce qui est sélectionné dans le tableau part dans la corbeille d'Oust!.
    private func throwSelection() {
        let items = state.selection.compactMap { state.row($0) }.compactMap { row -> CleanupItem? in
            switch row.kind {
            case .folder(let node): model.item(for: node)
            case .file(let file, let parent): model.item(for: file, in: parent)
            case .smallFiles: nil
            }
        }
        model.add(items)
        state.selection.removeAll()
    }

    /// Le contenu du dossier ouvert, en CSV.
    private func export() {
        guard let csv = state.csv() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Oust - \(state.focus.name).csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// « Data › Users › romain » : chaque étape rouvre ce dossier.
private struct Breadcrumb: View {
    let state: ExplorerState

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if state.focus !== state.root, let parent = state.focus.parent {
                Button { state.open(parent) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .help(Text("explorer.go_up", bundle: .oust))
            }
            ForEach(Array(state.trail.enumerated()), id: \.offset) { index, node in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7)) }
                Button { state.open(node) } label: {
                    Text(verbatim: index == 0 ? state.volumeName : node.name)
                        .fontWeight(node === state.focus ? .bold : .regular)
                }
                .buttonStyle(.plain)
            }
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.onGradient)
    }
}

// MARK: - Arborescence en colonnes

/// Le tableau hiérarchique de macOS : en-tête fixe, tri au clic, colonnes
/// redimensionnables et masquables (clic droit sur l'en-tête), sélection
/// multiple, double-clic pour ouvrir un dossier. C'est ce que fait TreeSize, et
/// la première version, dessinée à la main, n'y arrivait pas : son en-tête
/// prenait une hauteur absurde et ses colonnes sortaient de la fenêtre.
private struct TreeTable: View {
    @Bindable var state: ExplorerState
    let model: AppModel
    @State private var columns = TableColumnCustomization<ExplorerRow>()
    @State private var preview = FilePreview()
    /// Les lignes des fichiers montrés au coup d'œil, pour que la sélection
    /// suive les flèches du panneau.
    @State private var previewRows: [URL: ExplorerRow.ID] = [:]
    /// Après un changement d'onglet, le clic choisit la ligne sans donner le
    /// clavier au tableau (essai du 18/10/2026 : sélection grise, Espace sans
    /// effet) : on le lui donne.
    @FocusState private var focused: Bool

    var body: some View {
        Table(state.rows, children: \.children, selection: $state.selection, sortOrder: $state.sortOrder,
              columnCustomization: $columns) {
            TableColumn(Text("explorer.col.name", bundle: .oust), value: \.name) { row in
                NameCell(row: row, isSelected: state.selection.contains(row.id),
                         preview: canPreview(row) ? { show(row) } : nil)
            }
            .width(min: 160, ideal: 260)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(Text(LocalizedStringKey(state.metric == .size ? "explorer.col.share" : "explorer.col.share_files"),
                             bundle: .oust), value: \.share) { row in
                HStack(spacing: Spacing.small) {
                    SizeBar(fraction: row.share, tint: Palette.colors(for: .explorer).glow)
                    Text(verbatim: Formatters.percent(row.share)).font(Typography.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .width(min: 90, ideal: 140)
            .customizationID("share")

            TableColumn(Text("explorer.col.size", bundle: .oust), value: \.size) { row in
                Text(verbatim: Formatters.compactBytes(row.size)).font(Typography.size)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 78)
            .customizationID("size")

            TableColumn(Text("explorer.col.files", bundle: .oust), value: \.files) { row in
                Text(verbatim: row.files > 0 ? Formatters.count(row.files) : "")
                    .font(Typography.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 84)
            .customizationID("files")

            TableColumn(Text("explorer.col.folders", bundle: .oust), value: \.folders) { row in
                Text(verbatim: row.folders > 0 ? Formatters.count(row.folders) : "")
                    .font(Typography.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70)
            .customizationID("folders")

            TableColumn(Text("explorer.col.modified", bundle: .oust), value: \.modified) { row in
                Text(verbatim: row.modified == .distantPast ? "" : row.modified.formatted(date: .abbreviated, time: .omitted))
                    .font(Typography.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 96)
            .customizationID("modified")

            TableColumn(Text("explorer.col.growth", bundle: .oust), value: \.growth) { row in
                Text(verbatim: state.previous == nil || row.node == nil ? "" : Growth.text(row.growth))
                    .font(Typography.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Growth.color(row.growth))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 76)
            .customizationID("growth")

            TableColumn(Text(verbatim: "")) { row in
                if let item = item(for: row) { BinButton(item: item, model: model) }
            }
            .width(28)
            .customizationID("bin")
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: ExplorerRow.ID.self) { ids in
            if let id = ids.first, let row = state.row(id) {
                if canPreview(row) {
                    PreviewMenuItem(kind: previewKind(row)) { show(row) }
                }
                if let node = row.node, node.status == .ok {
                    Button { state.open(node) } label: {
                        Label { Text("explorer.open_here", bundle: .oust) } icon: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    }
                }
                if let item = item(for: row) {
                    CommonMenu(item: item, path: row.path, model: model)
                }
            }
        } primaryAction: { ids in
            // Double-clic : on entre dans le dossier, comme dans le Finder.
            if let id = ids.first, let node = state.row(id)?.node, node.status == .ok { state.open(node) }
        }
        // La barre d'espace, comme dans le Finder : coup d'œil sur un fichier,
        // le Finder pour un dossier ; une seconde fois, le panneau se ferme.
        .onKeyPress(.space) {
            if preview.isOpen {
                preview.close()
                return .handled
            }
            guard state.selection.count == 1, let id = state.selection.first, let row = state.row(id),
                  canPreview(row) else { return .ignored }
            show(row)
            return .handled
        }
        .focused($focused)
        .filePreview(preview)
        .onChange(of: state.selection) {
            if !state.selection.isEmpty { focused = true }
            guard state.selection.count == 1, let id = state.selection.first, let row = state.row(id),
                  case .file = row.kind else { return }
            let neighbors = neighbors(of: row)
            preview.follow(URL(fileURLWithPath: row.path), among: neighbors.map(\.url))
            if preview.isOpen { previewRows = Dictionary(neighbors.map { ($0.url, $0.id) }) { first, _ in first } }
        }
        .onChange(of: preview.current) {
            if let current = preview.current, let id = previewRows[current] { state.selection = [id] }
        }
    }

    /// Rien à voir dans les petits fichiers regroupés ni dans un dossier
    /// illisible. Sans lecture du disque : le tableau le demande à chaque ligne.
    private func canPreview(_ row: ExplorerRow) -> Bool {
        switch row.kind {
        case .file: true
        case .folder(let node): node.status == .ok
        case .smallFiles: false
        }
    }

    private func show(_ row: ExplorerRow) {
        let neighbors = neighbors(of: row)
        previewRows = Dictionary(neighbors.map { ($0.url, $0.id) }) { first, _ in first }
        preview.show(URL(fileURLWithPath: row.path), among: neighbors.map(\.url))
    }

    /// Les fichiers du même dossier, dans l'ordre du tableau : ceux entre
    /// lesquels les flèches du panneau circulent.
    private func neighbors(of row: ExplorerRow) -> [(url: URL, id: ExplorerRow.ID)] {
        guard case .file(_, let parent) = row.kind else { return [] }
        let siblings = parent === state.focus ? state.rows : (state.row("d:" + parent.path)?.loadedChildren ?? [])
        return siblings.compactMap { sibling in
            guard case .file = sibling.kind else { return nil }
            return (URL(fileURLWithPath: sibling.path), sibling.id)
        }
    }

    private func item(for row: ExplorerRow) -> CleanupItem? {
        switch row.kind {
        case .folder(let node): model.item(for: node)
        case .file(let file, let parent): model.item(for: file, in: parent)
        case .smallFiles: nil
        }
    }
}

/// Le nom, avec le symbole de son état ou de sa sorte de fichier, et l'œil du
/// coup d'œil au survol.
private struct NameCell: View {
    let row: ExplorerRow
    let isSelected: Bool
    let preview: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            Text(verbatim: title).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(isSecondary ? .secondary : .primary)
            if let status = statusText {
                Text(verbatim: status).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let preview {
                Spacer(minLength: 0)
                // La sorte d'un dossier (paquet ou non) n'est lue que sur la
                // ligne survolée ou choisie, pas sur chacune.
                let visible = hovering || isSelected
                PreviewButton(kind: visible ? previewKind(row) : .file, isVisible: visible, action: preview)
            }
        }
        .onHover { hovering = $0 }
    }

    private var title: String {
        if case .smallFiles(let node) = row.kind {
            return L10n.string("explorer.small_files", Formatters.count(node.smallFileCount))
        }
        return row.name
    }

    private var isSecondary: Bool {
        if case .smallFiles = row.kind { return true }
        return false
    }

    private var symbol: String {
        switch row.kind {
        case .smallFiles: return "square.grid.3x3.fill"
        case .file(let file, _): return FileKind.of(file.name).symbol
        case .folder(let node):
            switch node.status {
            case .inaccessible: return "lock.fill"
            case .otherVolume: return "externaldrive"
            case .firmlink: return "link"
            case .dataless: return "icloud"
            case .excluded: return "eye.slash"
            case .ok: return node.name.hasSuffix(".app") ? "app.dashed" : "folder.fill"
            }
        }
    }

    private var tint: Color {
        switch row.kind {
        case .smallFiles: .secondary
        case .file: .white.opacity(0.75)
        case .folder(let node): node.status.isInaccessible ? Palette.vivid(for: .inaccessible) : Palette.colors(for: .explorer).glow
        }
    }

    private var statusText: String? {
        guard case .folder(let node) = row.kind else { return nil }
        switch node.status {
        case .ok: return nil
        // EPERM vient de TCC : l'Accès complet au disque l'ouvre. EACCES, ce sont
        // les droits du fichier (.Spotlight-V100, .fseventsd, à root) : l'accès
        // n'y change rien, et le dire faisait croire qu'il ne marchait pas
        // (vérification du 18/10/2026).
        case .inaccessible(let code):
            return L10n.string(code == EPERM ? "explorer.status_inaccessible" : "explorer.status_system_only")
        case .otherVolume: return L10n.string("explorer.status_other_volume")
        case .firmlink: return L10n.string("explorer.status_firmlink")
        case .dataless: return L10n.string("explorer.status_dataless")
        case .excluded: return L10n.string("explorer.status_excluded")
        }
    }
}

/// Ce que donne le coup d'œil sur une ligne : le panneau pour un fichier, le
/// Finder pour un dossier ou un paquet.
@MainActor
private func previewKind(_ row: ExplorerRow) -> PreviewKind {
    guard case .folder(let node) = row.kind else { return .file }
    return PreviewKind.of(URL(fileURLWithPath: node.path))
}

/// Largeurs communes aux listes des onglets.
enum Column {
    static let action: CGFloat = 24
}

/// Un chemin tel qu'on le connaît : `/Users/…` plutôt que
/// `/System/Volumes/Data/Users/…`, le nom par lequel le parcours l'a atteint.
enum PathDisplay {
    static func short(_ path: String) -> String {
        path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
    }
}

/// Mettre à la corbeille d'Oust!, ou l'en retirer.
struct BinButton: View {
    let item: CleanupItem
    let model: AppModel

    var body: some View {
        Button { model.toggle(item) } label: {
            Image(systemName: !model.canSelectForCleanup(item) ? "lock" : (model.isInCart(item.id) ? "trash.fill" : "trash"))
                .foregroundStyle(model.canSelectForCleanup(item) ? Palette.colors(for: .explorer).glow : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(!model.canSelectForCleanup(item))
        .help(Text(model.canSelectForCleanup(item) ? (model.isInCart(item.id) ? "row.remove_from_cart" : "row.add_to_cart") : "explorer.protected_help",
                   bundle: .oust))
    }
}

/// Révéler, copier le chemin, jeter : le menu commun à toutes les lignes.
struct CommonMenu: View {
    let item: CleanupItem
    let path: String
    let model: AppModel

    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
            Label { Text("row.reveal", bundle: .oust) } icon: { Image(systemName: "folder") }
        }
        Button {
            model.transfer.present(sources: [URL(fileURLWithPath: path)])
            model.searchText = ""
            model.section = .transfer
        } label: {
            Label { Text("advice.prepare_transfer", bundle: .oust) } icon: { Image(systemName: "externaldrive") }
        }
        .disabled(!model.canSelectForCleanup(item) || model.transfer.isRunning)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        } label: {
            Label { Text("explorer.copy_path", bundle: .oust) } icon: { Image(systemName: "doc.on.clipboard") }
        }
        Divider()
        Button { model.toggle(item) } label: {
            Label { Text(model.isInCart(item.id) ? "row.remove_from_cart" : "row.add_to_cart", bundle: .oust) }
                icon: { Image(systemName: model.isInCart(item.id) ? "trash.slash" : "trash") }
        }
        .disabled(!model.canSelectForCleanup(item))
    }
}

/// L'écart depuis la dernière analyse, en texte et en couleur.
enum Growth {
    static func text(_ delta: Int64) -> String {
        if abs(delta) < 1_000_000 { return "=" }
        return (delta > 0 ? "+" : "−") + Formatters.compactBytes(abs(delta))
    }

    /// Ce qui grossit attire l'œil (orangé « à examiner ») ; ce qui maigrit est
    /// une bonne nouvelle (vert « sûr »). Jamais l'Éclat, réservé au vide.
    static func color(_ delta: Int64?) -> Color {
        guard let delta, abs(delta) >= 1_000_000 else { return .secondary }
        return delta > 0 ? Palette.vivid(for: .review) : Palette.vivid(for: .safe)
    }
}

// MARK: - Résultats de recherche

private struct SearchResults: View {
    let state: ExplorerState
    let model: AppModel

    var body: some View {
        if state.hits.isEmpty && !state.searching {
            EmptyState(symbol: "magnifyingglass", title: "explorer.search_empty", message: nil)
        } else {
            List(state.hits) { hit in
                HStack(spacing: Spacing.medium) {
                    switch hit {
                    case .folder(let node):
                        Image(systemName: "folder.fill").foregroundStyle(Palette.colors(for: .explorer).glow).frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: node.name).lineLimit(1)
                            Text(verbatim: PathDisplay.short(node.path)).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text(verbatim: Formatters.compactBytes(node.total.allocated)).font(Typography.size)
                        BinButton(item: model.item(for: node), model: model).frame(width: Column.action)
                    case .file(let file, let parent):
                        Image(systemName: FileKind.of(file.name).symbol).foregroundStyle(.white.opacity(0.75)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: file.name).lineLimit(1)
                            Text(verbatim: PathDisplay.short(parent.path)).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text(verbatim: Formatters.compactBytes(file.sizes.allocated)).font(Typography.size)
                        BinButton(item: model.item(for: file, in: parent), model: model).frame(width: Column.action)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if case .folder(let node) = hit { state.open(node) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}
