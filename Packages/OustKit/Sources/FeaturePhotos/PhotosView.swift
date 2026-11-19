import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustPhotos

/// La photothèque : les plus grosses vidéos, les vieilles captures d'écran, les
/// doublons exacts et, à part, les photos qui se ressemblent.
///
/// Tout passe par PhotoKit, jamais par le paquet `.photoslibrary`. Rien n'est
/// coché d'office (RULES.md, règle 4), et chaque chiffre est ce que la
/// suppression rendrait sur ce Mac, pas ce que compte iCloud (règle 9).
public struct PhotosView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) {
        self.model = model
    }

    private var photos: PhotosModel { model.photos }

    public var body: some View {
        SectionScaffold(.photos, subtitle: "photos.subtitle") {
            if photos.access.canRead, photos.phase.hasRun {
                Button { Task { await photos.analyze() } } label: { Text("photos.reanalyze", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
                    .disabled(photos.phase.isRunning)
            }
        } content: {
            switch photos.access {
            case .notDetermined:
                AccessRequest(photos: photos)
            case .denied, .restricted:
                AccessDenied()
            case .authorized, .limited:
                if photos.access == .limited {
                    Note(symbol: "photo.badge.exclamationmark", text: L10n.string("photos.limited_note"))
                }
                switch photos.phase {
                case .idle:
                    EmptyState(symbol: "photo.on.rectangle.angled", title: "photos.empty_title", message: "photos.empty_detail")
                    Button { Task { await photos.analyze() } } label: { Text("photos.analyze", bundle: .oust) }
                        .buttonStyle(PrimaryButtonStyle(section: .photos))
                        .frame(maxWidth: .infinity)
                case .running:
                    Working(progress: photos.progress, onCancel: photos.cancel)
                case .done:
                    Results(model: model)
                }
            }
        }
        .onAppear { photos.refreshAccess() }
        .overlay {
            if let preview = photos.preview {
                PhotoPreview(model: model, preview: preview)
            }
        }
        // Avec « Réduire les animations », l'aperçu paraît et disparaît d'un coup.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: photos.preview == nil)
    }
}

// MARK: - Autorisation

private struct AccessRequest: View {
    let photos: PhotosModel

    var body: some View {
        EmptyState(symbol: "photo.on.rectangle.angled", title: "photos.access_title", message: "photos.access_detail")
        Button { Task { await photos.requestAccess() } } label: { Text("photos.access_allow", bundle: .oust) }
            .buttonStyle(PrimaryButtonStyle(section: .photos))
            .frame(maxWidth: .infinity)
    }
}

private struct AccessDenied: View {
    var body: some View {
        EmptyState(symbol: "lock.rectangle.on.rectangle", title: "photos.denied_title", message: "photos.denied_detail")
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                NSWorkspace.shared.open(url)
            }
        } label: { Text("access.open", bundle: .oust) }
            .buttonStyle(PrimaryButtonStyle(section: .photos))
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Analyse en cours

private struct Working: View {
    let progress: PhotoProgress
    let onCancel: () -> Void

    var body: some View {
        GlassCard(padding: Spacing.xLarge) {
            HStack(spacing: Spacing.xLarge) {
                PulseOrb(section: .photos, isActive: true, size: 140)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text(verbatim: StageText.describe(progress))
                            .font(Typography.headline).foregroundStyle(Palette.onGradient)
                            .monospacedDigit()
                        Button(action: onCancel) { Text("common.cancel", bundle: .oust) }
                            .buttonStyle(OnGradientButtonStyle())
                    }
                }
            }
        }
    }
}

private enum StageText {
    static func describe(_ progress: PhotoProgress) -> String {
        let done = Formatters.count(progress.done)
        let total = Formatters.count(progress.total)
        switch progress.stage {
        case .listing: return L10n.string("photos.stage.listing")
        case .measuring: return L10n.string("photos.stage.measuring", done, total)
        case .comparing: return L10n.string("photos.stage.comparing", done, total)
        case .printing: return L10n.string("photos.stage.printing", done, total)
        case .classifying: return L10n.string("photos.stage.classifying", done, total)
        }
    }
}

// MARK: - Résultats

private struct Results: View {
    let model: AppModel
    @FocusState private var focused: Bool

    private var photos: PhotosModel { model.photos }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xLarge) { content }
            // La barre d'espace ouvre l'élément choisi en grand, comme dans le
            // Finder ; les flèches changent de choix.
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.space) {
                guard photos.selection != nil else { return .ignored }
                photos.previewSelection()
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .leftArrow]) { _ in
                photos.moveSelection(-1)
                return .handled
            }
            .onKeyPress(keys: [.downArrow, .rightArrow]) { _ in
                photos.moveSelection(1)
                return .handled
            }
            .onChange(of: photos.selection) { if photos.selection != nil, photos.preview == nil { focused = true } }
            .onChange(of: photos.preview == nil) { if photos.preview == nil { focused = true } }
    }

    @ViewBuilder
    private var content: some View {
        // Rien à rendre : pas de grand chiffre, un « — » de 64 pt ressemblerait à
        // une barre blanche posée sur le fond (vu dans Gros et vieux fichiers).
        VStack(alignment: .leading, spacing: Spacing.small) {
            if photos.reclaimableTotal > 0 {
                HStack(alignment: .bottom) {
                    HeroSize(photos.reclaimableTotal, caption: "photos.total_caption")
                    Spacer()
                }
            }
            Honesty(photos: photos)
        }
        TabBar(photos: photos)
        switch photos.tab {
        case .videos:
            EntryList(model: model, entries: photos.videos, tab: .videos, emptyTitle: "photos.videos_none",
                      allowsSelectAll: false)
        case .screenshots:
            EntryList(model: model, entries: photos.screenshots, tab: .screenshots, emptyTitle: "photos.screenshots_none",
                      allowsSelectAll: true)
        case .duplicates:
            if photos.unverifiableDuplicates == 1 {
                Note(symbol: "icloud", text: L10n.string("photos.unverifiable_note_one"))
            } else if photos.unverifiableDuplicates > 1 {
                Note(symbol: "icloud", text: L10n.string("photos.unverifiable_note",
                                                         Formatters.count(photos.unverifiableDuplicates)))
            }
            Groups(model: model, groups: photos.duplicates, tab: .duplicates, emptyTitle: "photos.duplicates_none")
        case .similar:
            SimilarSection(model: model)
        case .utilities:
            UtilitySection(model: model)
        }
    }
}

/// Ce que la suppression rend vraiment, et quand (RULES.md, règle 9).
private struct Honesty: View {
    let photos: PhotosModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .top, spacing: Spacing.small) {
                line("arrow.triangle.2.circlepath.icloud", L10n.string("photos.sync_warning_short"))
                Spacer(minLength: Spacing.small)
                ContextHelpButton(text: L10n.string("photos.recently_deleted_note") + "\n\n"
                                  + L10n.string("photos.sync_note"))
                    .foregroundStyle(Palette.onGradient)
            }
            line("trash.square", L10n.string("photos.recovery_short"))
            if photos.cloudOnlyTotal > 0 {
                line("icloud", L10n.string("photos.cloud_note", Formatters.compactBytes(photos.cloudOnlyTotal)))
            }
            if photos.hasIncompleteSizes {
                line("questionmark.circle", L10n.string("photos.incomplete_note"))
            }
        }
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).frame(width: 20)
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.onGradient)
    }
}

/// Les quatre listes, d'un clic : nombre et ce qu'elles rendraient.
private struct TabBar: View {
    @Bindable var photos: PhotosModel

    var body: some View {
        // 170 points : les cinq onglets tiennent sur une ligne dans la largeur de la section.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Spacing.small)], spacing: Spacing.small) {
            ForEach(PhotosModel.Tab.allCases) { tab in
                let on = photos.tab == tab
                Button { photos.tab = tab } label: {
                    HStack(spacing: Spacing.small) {
                        Image(systemName: tab.finding.category.symbol).font(.system(size: 15, weight: .semibold))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(LocalizedStringKey(tab.localizationKey), bundle: .oust).font(Typography.body.weight(.semibold))
                            Text(verbatim: summary(tab)).font(Typography.caption).monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .foregroundStyle(Palette.onGradient)
                    .padding(.horizontal, Spacing.medium)
                    .padding(.vertical, Spacing.small)
                    // Choisi : le profond de la section, qui fonce le fond au lieu
                    // de l'éclaircir. Un voile blanc aurait fait repasser le texte
                    // blanc sous 4,5:1 sur le dégradé vif (IDENTITE §4, règle 3).
                    .background(on ? AnyShapeStyle(Palette.colors(for: .photos).deep.opacity(0.6))
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
    }

    private func summary(_ tab: PhotosModel.Tab) -> String {
        if tab == .similar, !photos.similarPhase.hasRun { return L10n.string("photos.similar_on_demand") }
        if tab == .utilities, !photos.utilityPhase.hasRun { return L10n.string("photos.similar_on_demand") }
        let count = photos.count(tab)
        let size = Formatters.compactBytes(photos.reclaimable(tab))
        let groups = tab == .duplicates || tab == .similar
        // « 1 groupes » se lisait sur le premier essai (18/10/2026) : le singulier a sa clé.
        if count == 1 { return L10n.string(groups ? "photos.tab_groups_one" : "photos.tab_items_one", size) }
        return L10n.string(groups ? "photos.tab_groups" : "photos.tab_items", Formatters.count(count), size)
    }
}

// MARK: - Listes

private struct EntryList: View {
    let model: AppModel
    let entries: [PhotoEntry]
    let tab: PhotosModel.Tab
    let emptyTitle: LocalizedStringKey
    let allowsSelectAll: Bool
    @State private var limit = 100

    private var photos: PhotosModel { model.photos }

    var body: some View {
        if entries.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: emptyTitle)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if allowsSelectAll {
                    let counts = photos.selectionCount(entries, in: tab)
                    let state: SelectAllRow.State = counts.selected == 0 ? .none
                        : (counts.selected == counts.selectable ? .all : .some)
                    SelectAllRow(state: state, count: counts.selectable, tint: Palette.color(for: tab.finding.category)) {
                        photos.toggleAll(entries, in: tab)
                    }
                    Divider().opacity(0.25)
                }
                LazyVStack(spacing: 0) {
                    ForEach(entries.prefix(limit)) { entry in
                        PhotoRow(model: model, entry: entry, tab: tab)
                        Divider().opacity(0.25)
                    }
                }
                if entries.count > limit {
                    Button { limit += 100 } label: { Text("group.show_more", bundle: .oust) }
                        .buttonStyle(.borderless)
                        .padding(.vertical, Spacing.small)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.small)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }
}

private struct PhotoRow: View {
    let model: AppModel
    let entry: PhotoEntry
    let tab: PhotosModel.Tab
    @State private var explaining = false

    private var photos: PhotosModel { model.photos }

    var body: some View {
        let item = photos.item(for: entry, in: tab)
        let inCart = photos.isInCart(entry)
        HStack(spacing: Spacing.medium) {
            CheckButton(item: item, inCart: inCart, enabled: item.isSelectable) { photos.toggle(entry, in: tab) }
            // Un bouton, hors de la zone des gestes de la ligne : sous le double-clic
            // (cocher) et le clic (choisir), un vrai clic de souris sur la vignette ne
            // faisait que choisir la ligne (revue du 18/10/2026).
            Button { photos.openPreview(entry, in: tab) } label: {
                Thumbnail(photos: photos, entry: entry, side: 96)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(Text("photos.preview.open", bundle: .oust))
            .accessibilityLabel(Text("photos.preview.open", bundle: .oust))
            // Le reste de la ligne : un clic la choisit (la barre d'espace l'ouvre
            // ensuite), un double-clic la coche.
            HStack(spacing: Spacing.medium) {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(verbatim: entry.title).font(Typography.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: Spacing.tight) {
                        if let detail = item.detail {
                            Text(verbatim: detail).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Badges(item: item)
                    }
                }
                Spacer(minLength: Spacing.medium)
                SizeColumn(size: entry.size)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if item.isSelectable { photos.toggle(entry, in: tab) } }
            .simultaneousGesture(TapGesture().onEnded { photos.selection = entry.id })
            Button { explaining.toggle() } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $explaining, arrowEdge: .trailing) { Explanation(item: item) }
            .accessibilityLabel(Text("row.why", bundle: .oust))
        }
        .padding(.vertical, Spacing.tight)
        .padding(.horizontal, Spacing.tight)
        .background(photos.selection == entry.id ? Color.white.opacity(0.1) : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .accessibilityAction(named: Text("photos.preview.open", bundle: .oust)) { photos.openPreview(entry, in: tab) }
    }
}

/// Ce que rend la suppression, et ce qui n'est que dans iCloud.
private struct SizeColumn: View {
    let size: PhotoSize

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.hair) {
            Text(verbatim: Formatters.compactBytes(size.local)).font(Typography.size)
            if size.inCloudOnly > 0 {
                Text(verbatim: L10n.string("photos.in_icloud", Formatters.compactBytes(size.inCloudOnly)))
                    .font(Typography.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(minWidth: 90, alignment: .trailing)
    }
}

private struct Badges: View {
    let item: CleanupItem

    var body: some View {
        if let reason = item.protections.first {
            Tag(Describe.protection(reason), symbol: "lock.fill", tint: Palette.vivid(for: .protected))
        }
        if item.notes.contains(.photoInCloud) {
            Tag(L10n.string("photos.in_icloud_tag"), symbol: "icloud", tint: Palette.vivid(for: .rebuilds))
        }
    }
}

private struct CheckButton: View {
    let item: CleanupItem
    let inCart: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: !item.isSelectable ? "lock.circle" : (inCart ? "checkmark.circle.fill" : "circle"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(inCart ? AnyShapeStyle(Palette.color(for: item.category)) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(inCart ? "row.remove_from_cart" : "row.add_to_cart", bundle: .oust))
        .help(Text(verbatim: item.protections.first.map(Describe.protection) ?? L10n.string("row.add_to_cart")))
    }
}

// MARK: - Groupes

private struct Groups: View {
    let model: AppModel
    let groups: [PhotoGroup]
    let tab: PhotosModel.Tab
    let emptyTitle: LocalizedStringKey
    @State private var limit = 40

    var body: some View {
        if groups.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: emptyTitle)
        } else {
            LazyVStack(spacing: Spacing.medium) {
                ForEach(groups.prefix(limit)) { group in
                    GroupCard(model: model, group: group, tab: tab)
                }
            }
            if groups.count > limit {
                Button { limit += 40 } label: { Text("group.show_more", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
        }
    }
}

private struct GroupCard: View {
    let model: AppModel
    let group: PhotoGroup
    let tab: PhotosModel.Tab

    private var photos: PhotosModel { model.photos }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.small) {
                Image(systemName: tab.finding.category.symbol).foregroundStyle(Palette.color(for: tab.finding.category))
                Text(verbatim: group.entries.first?.asset.created?.formatted(date: .long, time: .shortened) ?? "")
                    .font(Typography.headline).lineLimit(1)
                Spacer()
                Text(verbatim: L10n.string("photos.group_detail", Formatters.count(group.entries.count),
                                           Formatters.compactBytes(group.potential)))
                    .font(Typography.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if tab == .similar {
                Text("photos.similar_hint", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: Spacing.medium, alignment: .top)],
                      alignment: .leading, spacing: Spacing.medium) {
                ForEach(group.entries) { entry in
                    Tile(model: model, entry: entry, group: group, tab: tab)
                }
            }
        }
        .padding(Spacing.large)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }
}

/// Une photo d'un groupe : la voir avant de choisir.
private struct Tile: View {
    let model: AppModel
    let entry: PhotoEntry
    let group: PhotoGroup
    let tab: PhotosModel.Tab
    @State private var explaining = false

    private var photos: PhotosModel { model.photos }

    var body: some View {
        let item = photos.item(for: entry, in: tab)
        let inCart = photos.isInCart(entry)
        let enabled = photos.canToggle(entry, in: group, tab: tab)
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Button { photos.openPreview(entry, in: tab, group: group) } label: {
                Thumbnail(photos: photos, entry: entry, side: 360)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("photos.preview.open", bundle: .oust))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(inCart ? Palette.color(for: item.category) : .clear, lineWidth: 3))
            .overlay(alignment: .topLeading) {
                CheckButton(item: item, inCart: inCart, enabled: enabled) { photos.toggle(entry, in: tab) }
                    .padding(Spacing.tight)
                    .background(.black.opacity(0.35), in: Circle())
                    .padding(Spacing.tight)
            }
            // Choisie : un liseré blanc autour, distinct de celui de la corbeille.
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: Radius.small + 3, style: .continuous)
                .strokeBorder(.white.opacity(photos.selection == entry.id ? 0.9 : 0), lineWidth: 2))
            // Aucun geste ici : sur le bouton, il retiendrait le clic. L'ouvrir choisit la tuile.
            .help(Text("photos.preview.open", bundle: .oust))
            .accessibilityAction(named: Text("photos.preview.open", bundle: .oust)) {
                photos.openPreview(entry, in: tab, group: group)
            }
            HStack(spacing: Spacing.tight) {
                Text(verbatim: entry.title).font(Typography.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { explaining.toggle() } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $explaining, arrowEdge: .trailing) { Explanation(item: item) }
                .accessibilityLabel(Text("row.why", bundle: .oust))
            }
            HStack(spacing: Spacing.tight) {
                Text(verbatim: Formatters.compactBytes(entry.size.local)).font(Typography.size)
                if entry.size.inCloudOnly > 0 {
                    Image(systemName: "icloud").font(Typography.caption).foregroundStyle(.secondary)
                        .help(Text(verbatim: L10n.string("photos.in_icloud", Formatters.compactBytes(entry.size.inCloudOnly))))
                }
            }
            if let reason = item.protections.first {
                Tag(Describe.protection(reason), symbol: "lock.fill", tint: Palette.vivid(for: .protected))
            } else if tab == .duplicates, !inCart, !enabled {
                // Le dernier exemplaire d'un groupe reste (SPEC §7).
                Tag(L10n.string("photos.kept"), symbol: "star.fill", tint: Palette.vivid(for: .safe))
            }
        }
    }
}

// MARK: - Similaires

private struct SimilarSection: View {
    let model: AppModel

    private var photos: PhotosModel { model.photos }

    var body: some View {
        switch photos.similarPhase {
        case .idle:
            SimilarStart(photos: photos)
        case .running:
            Working(progress: photos.similarProgress, onCancel: photos.cancel)
        case .done:
            HStack(spacing: Spacing.medium) {
                Text("photos.similar_never_checked", bundle: .oust)
                    .font(Typography.body).foregroundStyle(Palette.onGradient)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { Task { await photos.findSimilar() } } label: { Text("photos.similar_again", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
            Groups(model: model, groups: photos.similar, tab: .similar, emptyTitle: "photos.similar_none")
        }
    }
}

private struct SimilarStart: View {
    @Bindable var photos: PhotosModel

    var body: some View {
        GlassCard(padding: Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text("photos.similar_title", bundle: .oust).font(Typography.headline).foregroundStyle(Palette.onGradient)
                Text("photos.similar_detail", bundle: .oust).font(Typography.body).foregroundStyle(Palette.onGradient)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.large) {
                    PeriodPicker(period: $photos.similarPeriod)
                    Spacer()
                    Button { Task { await photos.findSimilar() } } label: { Text("photos.similar_search", bundle: .oust) }
                        .buttonStyle(PrimaryButtonStyle(section: .photos))
                }
            }
        }
    }
}

// MARK: - Photos utiles

/// Codes-barres, documents, tickets, cartes, écrans, étiquettes : les photos
/// prises pour garder une information (Romain, 18/10/2026). Sur demande, famille
/// par famille, jamais cochées d'office ; une photo avec un visage n'y est pas.
private struct UtilitySection: View {
    let model: AppModel

    private var photos: PhotosModel { model.photos }

    var body: some View {
        switch photos.utilityPhase {
        case .idle:
            UtilityStart(photos: photos)
        case .running:
            Working(progress: photos.utilityProgress, onCancel: photos.cancel)
        case .done:
            HStack(spacing: Spacing.medium) {
                Text("photos.utilities_note", bundle: .oust)
                    .font(Typography.body).foregroundStyle(Palette.onGradient)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { Task { await photos.findUtilities() } } label: { Text("photos.similar_again", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
            if photos.utilities.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: "photos.utilities_none")
            }
            ForEach(PhotoUtilityKind.allCases) { kind in
                let entries = photos.utilities(kind)
                if !entries.isEmpty {
                    Label {
                        Text(verbatim: L10n.string(kind.localizationKey) + " · "
                             + (entries.count == 1 ? L10n.string("photos.tab_items_one", size(entries))
                                : L10n.string("photos.tab_items", Formatters.count(entries.count), size(entries))))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: kind.symbol)
                    }
                    .font(Typography.headline)
                    .foregroundStyle(Palette.onGradient)
                    EntryList(model: model, entries: entries, tab: .utilities, emptyTitle: "photos.utilities_none",
                              allowsSelectAll: kind.allowsSelectAll)
                }
            }
        }
    }

    private func size(_ entries: [PhotoEntry]) -> String {
        Formatters.compactBytes(entries.filter(\.isFreeable).reduce(0) { $0 + $1.size.local })
    }
}

private struct UtilityStart: View {
    @Bindable var photos: PhotosModel

    var body: some View {
        GlassCard(padding: Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text("photos.utilities_title", bundle: .oust).font(Typography.headline).foregroundStyle(Palette.onGradient)
                Text("photos.utilities_detail", bundle: .oust).font(Typography.body).foregroundStyle(Palette.onGradient)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.large) {
                    PeriodPicker(period: $photos.utilityPeriod)
                    Spacer()
                    Button { Task { await photos.findUtilities() } } label: { Text("photos.utilities_search", bundle: .oust) }
                        .buttonStyle(PrimaryButtonStyle(section: .photos))
                }
            }
        }
    }
}

/// La période à examiner : les 3 derniers mois, les 12 derniers, ou tout.
private struct PeriodPicker: View {
    @Binding var period: PhotosModel.Period

    var body: some View {
        Picker(selection: $period) {
            ForEach(PhotosModel.Period.allCases) { period in
                Text(LocalizedStringKey(period.localizationKey), bundle: .oust).tag(period)
            }
        } label: {
            Text("photos.period", bundle: .oust)
        }
        .fixedSize()
    }
}

// MARK: - Petites pièces

/// Une ligne d'information sur le fond de la section, en verre.
private struct Note: View {
    let symbol: String
    let text: String

    var body: some View {
        GlassCard {
            Label {
                Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol)
            }
            .font(Typography.body)
            .foregroundStyle(Palette.onGradient)
        }
    }
}

/// Une vignette locale, demandée à Photos sans réseau. En attendant, ou si
/// Photos n'en a pas, un pictogramme.
private struct Thumbnail: View {
    let photos: PhotosModel
    let entry: PhotoEntry
    let side: Int
    @State private var image: CGImage?

    var body: some View {
        // La couleur prend la place proposée ; l'image la remplit en surimpression,
        // rognée à ce cadre. Dans un ZStack, une image en `scaledToFill` imposait
        // sa propre largeur et débordait de la carte (revue du 18/10/2026).
        Color.white.opacity(0.08)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: entry.asset.media == .video ? "video" : "photo")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if entry.asset.media == .video, entry.asset.duration > 0 {
                    // « 24:01 » : « 24 min et 1 s » ne tenait pas sur une vignette.
                    Text(verbatim: Duration.seconds(entry.asset.duration.rounded())
                        .formatted(.time(pattern: entry.asset.duration >= 3_600 ? .hourMinuteSecond : .minuteSecond)))
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .padding(2)
                }
            }
            .accessibilityHidden(true)
            .task(id: entry.id) { image = await photos.thumbnail(for: entry.id, side: side)?.image }
    }
}
