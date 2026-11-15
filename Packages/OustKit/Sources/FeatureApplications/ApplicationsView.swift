import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustUninstall

/// Le désinstalleur (SPEC §10, phase 2) : une application, et tout ce qu'elle a
/// laissé dans `~/Library`, trouvé en correspondance stricte. Sous la liste, ce
/// qu'ont laissé les applications déjà jetées à la main.
public struct ApplicationsView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var showsOnlyUnused = false

    public init(model: AppModel) {
        self.model = model
    }

    private var applications: ApplicationsModel { model.applications }

    public var body: some View {
        let unusedCutoff = Calendar.current.date(byAdding: .month, value: -6, to: .now)
        let uninstallable = filtered(applications.uninstallable).filter { app in
            guard showsOnlyUnused else { return true }
            return !applications.isRunning(app) && (unusedCutoff.map { app.wasLastOpened(before: $0) } ?? false)
        }
        let excluded = showsOnlyUnused ? [] : filtered(applications.excluded)
        let visibleSelection = applications.selected.flatMap { selected in
            !showsOnlyUnused || uninstallable.contains(where: { $0.id == selected.id }) ? selected : nil
        }
        ZStack {
            SectionBackground(.applications)
            VStack(alignment: .leading, spacing: Spacing.large) {
                SectionHeader(.applications, subtitle: "applications.subtitle") {
                    Button { Task { await applications.load() } } label: {
                        Text(applications.phase.isRunning ? "applications.reading" : "applications.refresh", bundle: .oust)
                    }
                    .buttonStyle(OnGradientButtonStyle())
                    .disabled(applications.phase.isRunning)
                }
                if applications.apps.isEmpty {
                    if applications.phase.isRunning {
                        GlassCard(padding: Spacing.xLarge) {
                            HStack(spacing: Spacing.xLarge) {
                                PulseOrb(section: .applications, isActive: true, size: 120)
                                Text("applications.reading", bundle: .oust)
                                    .font(Typography.headline).foregroundStyle(Palette.onGradient)
                            }
                        }
                    } else {
                        EmptyState(symbol: "square.grid.2x2", title: "applications.empty_title",
                                   message: "applications.empty_detail")
                    }
                    Spacer()
                } else {
                    // Une liste de largeur fixe : le nom et la taille y tiennent,
                    // et le détail garde la place des pastilles de classe. À
                    // 1080 pt de fenêtre, une liste à 380 ne laissait au détail
                    // que 350 pt, et « À examiner » s'y repliait sur trois lignes.
                    HStack(alignment: .top, spacing: Spacing.large) {
                        AppList(model: model, query: $query, showsOnlyUnused: $showsOnlyUnused,
                                uninstallable: uninstallable, excluded: excluded, selected: visibleSelection)
                            .frame(width: 300)
                        AppDetail(model: model, selected: visibleSelection)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .padding(Spacing.xxLarge)
            .onSectionBackground()
        }
        .task {
            if applications.phase == .idle { await applications.load() }
        }
        .onAppear { applications.pruneMissing() }
    }

    private func filtered(_ apps: [InstalledApp]) -> [InstalledApp] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(needle) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(needle) }
    }
}

// MARK: - Liste

private struct AppList: View {
    let model: AppModel
    @Binding var query: String
    @Binding var showsOnlyUnused: Bool
    let uninstallable: [InstalledApp]
    let excluded: [InstalledApp]
    let selected: InstalledApp?

    private var applications: ApplicationsModel { model.applications }

    var body: some View {
        ListSurface {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    TextField(text: $query) { Text("applications.search", bundle: .oust) }
                        .textFieldStyle(.roundedBorder)
                    Toggle(isOn: $showsOnlyUnused) {
                        Text("applications.unused_filter", bundle: .oust)
                    }
                    .toggleStyle(.checkbox)
                    .help(L10n.string("applications.unused_filter_help"))
                }
                .padding(Spacing.medium)
                if applications.phase.isRunning {
                    Text(verbatim: L10n.string("applications.measuring", Formatters.count(applications.measuredCount),
                                               Formatters.count(applications.apps.count)))
                        .font(Typography.caption)
                        .padding(.bottom, Spacing.small)
                }
                List(selection: Binding(
                    get: { selected?.id },
                    set: { id in
                        guard let id, id != applications.selectedID,
                              let app = uninstallable.first(where: { $0.id == id })
                                ?? excluded.first(where: { $0.id == id }) else { return }
                        Task { await applications.select(app) }
                    }
                )) {
                    Section {
                        ForEach(uninstallable) { app in
                            AppRow(app: app, running: applications.isRunning(app)).tag(app.id)
                        }
                        if showsOnlyUnused && uninstallable.isEmpty && !applications.phase.isRunning {
                            Text("applications.unused_no_matches", bundle: .oust)
                                .font(Typography.caption)
                        }
                    }
                    if !excluded.isEmpty {
                        Section(isExpanded: Binding(get: { applications.showsProtected },
                                                    set: { applications.showsProtected = $0 })) {
                            ForEach(excluded) { app in
                                AppRow(app: app, running: applications.isRunning(app)).tag(app.id)
                            }
                        } header: {
                            Text(verbatim: L10n.string("applications.protected_header", Formatters.count(excluded.count)))
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                Divider().opacity(0.4)
                // Les applications qu'on vient de mettre à la corbeille du Mac.
                TrashedAppsEntry(model: model)
                OrphanEntry(applications: applications)
            }
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let running: Bool

    var body: some View {
        HStack(spacing: Spacing.medium) {
            AppIcon(url: app.url, size: 32)
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(verbatim: app.name).font(Typography.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: Spacing.tight) {
                    if let exclusion = app.exclusion {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                        Text(LocalizedStringKey(exclusion.localizationKey + "_short"), bundle: .oust)
                    } else if running {
                        Image(systemName: "play.circle.fill").font(.system(size: 9, weight: .bold))
                        Text("applications.running", bundle: .oust)
                    } else if let used = app.lastUsed {
                        Text(verbatim: L10n.string("applications.last_used", Formatters.relative(used)))
                    } else if let version = app.version {
                        Text(verbatim: version)
                    }
                }
                .font(Typography.caption)
                .lineLimit(1)
            }
            Spacer(minLength: Spacing.small)
            Text(verbatim: Formatters.compactBytes(app.sizes.allocated)).font(Typography.size)
        }
        .padding(.vertical, Spacing.hair)
        .opacity(app.isUninstallable ? 1 : 0.75)
    }
}

/// Les restes d'applications disparues, épinglés sous la liste : elle peut
/// compter deux cents applications, une ligne de plus tout en bas passerait
/// inaperçue.
private struct OrphanEntry: View {
    let applications: ApplicationsModel

    var body: some View {
        Button { applications.showOrphans() } label: {
            HStack(spacing: Spacing.medium) {
                Image(systemName: ItemCategory.appLeftovers.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Palette.color(for: .appLeftovers).gradient,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text("category.appLeftovers", bundle: .oust).font(Typography.body.weight(.semibold)).lineLimit(1)
                    Group {
                        if applications.orphanPhase.isRunning {
                            Text("orphans.searching", bundle: .oust)
                        } else {
                            Text(verbatim: L10n.string("orphans.entry_count",
                                                       Formatters.count(applications.proposedOrphans.count)))
                        }
                    }
                    .font(Typography.caption)
                    .lineLimit(1)
                }
                Spacer(minLength: Spacing.small)
                if applications.orphanPhase.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Text(verbatim: Formatters.compactBytes(applications.orphanBytes)).font(Typography.size)
                }
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.small)
            .background(applications.showsOrphans ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(Spacing.small)
        .accessibilityAddTraits(applications.showsOrphans ? .isSelected : [])
    }
}

/// L'icône d'une application, telle que le Finder la montre.
private struct AppIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Détail

private struct AppDetail: View {
    let model: AppModel
    let selected: InstalledApp?

    private var applications: ApplicationsModel { model.applications }

    var body: some View {
        if let trashed = applications.trashedReviewID {
            TrashedAppDetail(model: model, id: trashed)
        } else if applications.showsOrphans {
            OrphanDetail(model: model)
        } else if let app = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    Header(app: app, applications: applications)
                    if let exclusion = app.exclusion {
                        GlassCard {
                            Label {
                                Text(LocalizedStringKey(exclusion.localizationKey), bundle: .oust)
                                    .font(Typography.body).foregroundStyle(Palette.onGradient)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "lock.fill").foregroundStyle(Palette.vivid(for: .protected))
                            }
                        }
                    } else {
                        Items(applications: applications)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .stopsUnderToolbar()
        } else {
            EmptyState(symbol: "hand.point.left", title: "applications.pick_title", message: "applications.pick_detail")
        }
    }
}

private struct Header: View {
    let app: InstalledApp
    let applications: ApplicationsModel

    var body: some View {
        // Deux rangées : l'identité de l'application en haut, ce qui est coché et
        // le bouton en bas. Sur une seule ligne, le nom se coupait en deux, le
        // chiffre géant n'affichait qu'un tiret et le bouton finissait écrasé en
        // colonne, une syllabe par ligne (signalé par Romain le 18/10/2026).
        GlassCard(padding: Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Spacing.large) {
                HStack(alignment: .center, spacing: Spacing.large) {
                    AppIcon(url: app.url, size: 72)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(verbatim: app.name).font(Typography.title)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(verbatim: [app.version, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(Typography.caption).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: app.url.deletingLastPathComponent().path)
                            .font(Typography.caption).lineLimit(1).truncationMode(.middle)
                        if app.isAppStore {
                            Text("applications.app_store", bundle: .oust).font(Typography.caption)
                        }
                    }
                    .foregroundStyle(Palette.onGradient)
                    Spacer(minLength: 0)
                }
                if app.isUninstallable {
                    Divider().overlay(Color.white.opacity(0.25))
                    HStack(alignment: .center, spacing: Spacing.medium) {
                        VStack(alignment: .leading, spacing: 0) {
                            if applications.chosenItems.isEmpty {
                                // Un tiret au-dessus de « cochés » ne disait rien.
                                Text("applications.nothing_chosen", bundle: .oust).font(Typography.headline)
                            } else {
                                Text(verbatim: Formatters.compactBytes(applications.chosenBytes))
                                    .font(Typography.title.monospacedDigit())
                                    .contentTransition(.numericText(value: Double(applications.chosenBytes)))
                                Text("applications.chosen_caption", bundle: .oust).font(Typography.caption)
                            }
                        }
                        .foregroundStyle(Palette.onGradient)
                        .fixedSize()
                        Spacer(minLength: Spacing.medium)
                        Button { applications.sendToBin() } label: {
                            Label { Text("applications.uninstall", bundle: .oust) } icon: { Image(systemName: "trash") }
                                .lineLimit(1)
                        }
                        .buttonStyle(PrimaryButtonStyle(section: .applications))
                        .fixedSize()
                        .disabled(applications.chosenItems.isEmpty || applications.leftoversLoading)
                    }
                }
            }
        }
        if applications.isRunning(app) {
            GlassCard {
                Label {
                    Text("applications.running_detail", bundle: .oust).font(Typography.body).foregroundStyle(Palette.onGradient)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.vivid(for: .review))
                }
            }
        }
    }
}

private struct Items: View {
    let applications: ApplicationsModel

    var body: some View {
        let items = applications.items
        let selectable = items.filter(applications.canSelectForCleanup)
        let checked = selectable.filter { applications.chosen.contains($0.id) }.count
        ItemGroup(title: L10n.string("applications.leftovers_title"), symbol: "shippingbox", tint: Palette.color(for: .applications),
                  total: applications.leftoverBytes) {
            LazyVStack(spacing: 0) {
                // Une case « tout cocher » au-dessus des autres, alignée sur elles :
                // un bouton texte dans l'en-tête passait inaperçu (Romain, 18/10/2026).
                if selectable.count > 1 {
                    SelectAllRow(
                        state: checked == 0 ? .none : (checked == selectable.count ? .all : .some),
                        count: selectable.count,
                        tint: Palette.color(for: .applications)
                    ) { applications.toggleAll() }
                    Divider().opacity(0.4)
                }
                ForEach(items) { item in
                    ItemRow(item, enabled: applications.canSelectForCleanup(item), isSelected: applications.chosen.contains(item.id)) { applications.toggle(item) }
                    Divider().opacity(0.25)
                }
                if applications.leftoversLoading {
                    HStack(spacing: Spacing.small) {
                        ProgressView().controlSize(.small)
                        Text("applications.looking", bundle: .oust).font(Typography.caption)
                    }
                    .padding(.vertical, Spacing.small)
                } else if items.count == 1 {
                    Text("applications.no_leftovers", bundle: .oust).font(Typography.caption)
                        .padding(.vertical, Spacing.small)
                }
            }
        }
        Text("applications.strict_note", bundle: .oust)
            .font(Typography.caption).foregroundStyle(Palette.onGradient)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Restes d'applications disparues

/// Ce qu'ont laissé des applications qui ne sont plus installées. Chaque reste
/// se coche à la main et entre dans la corbeille d'Oust!, comme dans Système :
/// rien n'est coché d'office, un dossier d'application peut garder des
/// documents ou des parties sauvegardées (RULES.md, règle 4).
private struct OrphanDetail: View {
    let model: AppModel
    @State private var showsProtected = false

    private var applications: ApplicationsModel { model.applications }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                header
                if !applications.orphansReadContainers {
                    GlassCard {
                        Label {
                            Text("orphans.containers_note", bundle: .oust)
                                .font(Typography.body).foregroundStyle(Palette.onGradient)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "lock.fill").foregroundStyle(Palette.vivid(for: .protected))
                        }
                    }
                }
                if applications.orphanPhase.isRunning && applications.orphans.isEmpty {
                    HStack(spacing: Spacing.small) {
                        ProgressView().controlSize(.small)
                        Text("orphans.searching", bundle: .oust).font(Typography.caption)
                    }
                    .foregroundStyle(Palette.onGradient)
                } else if applications.orphanPhase.hasRun && applications.proposedOrphans.isEmpty {
                    EmptyState(symbol: "checkmark.seal", title: "orphans.none_title", message: "orphans.none_detail")
                }
                ForEach(applications.proposedOrphans) { group in
                    OrphanGroupCard(model: model, group: group)
                }
                let kept = applications.protectedOrphans
                if !kept.isEmpty {
                    Button { showsProtected.toggle() } label: {
                        Label {
                            Text(verbatim: L10n.string("orphans.protected_header", Formatters.count(kept.count)))
                        } icon: {
                            Image(systemName: showsProtected ? "chevron.down" : "chevron.right")
                        }
                        .font(Typography.headline)
                        .foregroundStyle(Palette.onGradient)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showsProtected {
                        ForEach(kept) { group in
                            OrphanGroupCard(model: model, group: group)
                        }
                    }
                }
                Text("orphans.strict_note", bundle: .oust)
                    .font(Typography.caption).foregroundStyle(Palette.onGradient)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .scrollContentBackground(.hidden)
        .stopsUnderToolbar()
    }

    private var header: some View {
        GlassCard(padding: Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Spacing.large) {
                HStack(alignment: .center, spacing: Spacing.large) {
                    Image(systemName: ItemCategory.appLeftovers.symbol)
                        .font(.system(size: 44, weight: .semibold))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text("category.appLeftovers", bundle: .oust).font(Typography.title)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("orphans.subtitle", bundle: .oust).font(Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.onGradient)
                Divider().overlay(Color.white.opacity(0.25))
                HStack(alignment: .center, spacing: Spacing.medium) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: Formatters.compactBytes(applications.orphanBytes))
                            .font(Typography.title.monospacedDigit())
                            .contentTransition(.numericText(value: Double(applications.orphanBytes)))
                        Text("orphans.total_caption", bundle: .oust).font(Typography.caption)
                    }
                    .foregroundStyle(Palette.onGradient)
                    .fixedSize()
                    Spacer(minLength: Spacing.medium)
                    Button { Task { await applications.findOrphans() } } label: {
                        Text(applications.orphanPhase.isRunning ? "orphans.searching" : "applications.refresh", bundle: .oust)
                            .lineLimit(1)
                    }
                    .buttonStyle(OnGradientButtonStyle())
                    .fixedSize()
                    .disabled(applications.orphanPhase.isRunning)
                }
            }
        }
    }
}

/// Une application disparue et ce qu'elle a laissé.
private struct OrphanGroupCard: View {
    let model: AppModel
    let group: OrphanGroup

    var body: some View {
        let items = model.applications.items(of: group)
        let selectable = items.filter(model.canSelectForCleanup)
        let allIn = !selectable.isEmpty && selectable.allSatisfy { model.isInCart($0.id) }
        ItemGroup(title: group.title, symbol: ItemCategory.appLeftovers.symbol, tint: Palette.color(for: .appLeftovers),
                  total: group.freeable, selectAllTitle: allIn ? "group.deselect_all" : "group.select_all",
                  selectAll: selectable.count > 1 ? { model.applications.toggleAll(of: group) } : nil) {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Le nom vient d'un agent de lancement : l'identifiant dit le reste.
                if group.appName != nil {
                    Text(verbatim: group.identifier)
                        .font(Typography.caption).foregroundStyle(.secondary)
                        .padding(.vertical, Spacing.tight)
                }
                if group.ownerInTrash {
                    Label {
                        Text("orphans.in_trash", bundle: .oust)
                    } icon: {
                        Image(systemName: "trash.square")
                    }
                    .font(Typography.caption).foregroundStyle(.secondary)
                    .padding(.vertical, Spacing.tight)
                }
                ForEach(items) { item in
                    ItemRow(item, enabled: model.canSelectForCleanup(item), isSelected: model.isInCart(item.id)) { model.toggle(item) }
                    Divider().opacity(0.25)
                }
            }
        }
    }
}
