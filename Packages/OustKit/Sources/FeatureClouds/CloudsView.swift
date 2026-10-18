import AppKit
import SwiftUI
import OustClouds
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustScan

/// Les nuages vus depuis ce Mac : les plus gros fichiers, les plus vieux, les
/// doublons évidents et ce qui occupe de la place ici, par service et par compte.
///
/// Tout vient des fichiers fantômes que les services laissent sur le disque :
/// aucune connexion, aucun téléchargement (RULES.md, règle 11). Rien n'est
/// coché d'office (règle 4) ; ce qu'on jette part aussi du nuage et des autres
/// appareils, et l'écran le dit avant.
public struct CloudsView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var clouds: CloudsModel { model.clouds }

    public var body: some View {
        SectionScaffold(.clouds, subtitle: "clouds.subtitle") {
            if clouds.phase.hasRun {
                Button { Task { await clouds.scan() } } label: { Text("clouds.rescan", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
                    .disabled(clouds.phase.isRunning)
            }
        } content: {
            switch clouds.phase {
            case .idle:
                EmptyState(symbol: "cloud", title: "clouds.empty_title", message: "clouds.empty_detail")
                Button { Task { await clouds.scan() } } label: { Text("clouds.analyze", bundle: .oust) }
                    .buttonStyle(PrimaryButtonStyle(section: .clouds))
                    .frame(maxWidth: .infinity)
            case .running:
                Working(clouds: clouds)
            case .done:
                if clouds.inventory?.accounts.isEmpty ?? true {
                    EmptyState(symbol: "icloud.slash", title: "clouds.none_title", message: "clouds.none_detail")
                } else {
                    Results(model: model)
                }
            }
        }
        // Lire les nuages ne télécharge rien et prend une seconde ou deux : on le
        // fait dès la première visite.
        .task { if clouds.phase == .idle { await clouds.scan() } }
        .onAppear { clouds.applyFinishedCleaning() }
        .onChange(of: model.cleaning) { clouds.applyFinishedCleaning() }
    }
}

// MARK: - Parcours

private struct Working: View {
    let clouds: CloudsModel

    var body: some View {
        GlassCard(padding: Spacing.xLarge) {
            HStack(spacing: Spacing.xLarge) {
                PulseOrb(section: .clouds, isActive: true, size: 140)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text(verbatim: L10n.string("clouds.scanning", Formatters.count(clouds.progress.files)))
                            .font(Typography.headline).foregroundStyle(Palette.onGradient).monospacedDigit()
                        Text("clouds.scanning_detail", bundle: .oust)
                            .font(Typography.body).foregroundStyle(Palette.onGradient)
                        Button { clouds.cancel() } label: { Text("common.cancel", bundle: .oust) }
                            .buttonStyle(OnGradientButtonStyle())
                    }
                }
            }
        }
    }
}

// MARK: - Résultats

private struct Results: View {
    let model: AppModel

    private var clouds: CloudsModel { model.clouds }

    var body: some View {
        let summary = clouds.summary
        HStack(alignment: .bottom, spacing: Spacing.large) {
            HeroSize(summary.cloudBytes, caption: "clouds.total_caption")
            // « 7 fichiers · — sur ce Mac » pour un compte tout en ligne (essai du
            // 18/10/2026) : en toutes lettres, comme sur les cartes.
            Text(verbatim: summary.localBytes > 0
                 ? L10n.string("clouds.total_detail", Formatters.count(summary.files), Formatters.compactBytes(summary.localBytes))
                 : L10n.string("clouds.total_detail_none", Formatters.count(summary.files)))
                .font(Typography.headline).foregroundStyle(Palette.onGradient).monospacedDigit()
                .padding(.bottom, Spacing.small)
            Spacer()
            // Ce qu'Oust! voit et ce que fait la suppression : derrière un « ? ».
            // Toujours affiché, c'était trop de texte pour rien (Romain,
            // 18/10/2026) ; la suppression reste annoncée dans la corbeille et
            // à la confirmation.
            InfoButton(help: "clouds.info_help") { Honesty(clouds: clouds) }
                .padding(.bottom, Spacing.small)
        }
        Accounts(clouds: clouds)
        SearchField(clouds: clouds)
        TabBar(clouds: clouds)
        switch clouds.tab {
        case .largest:
            SizeFilter(clouds: clouds)
            FileList(model: model, files: clouds.largest, emptyTitle: clouds.isSearching ? "clouds.search_none" : "clouds.largest_none")
        case .oldest:
            HStack(spacing: Spacing.large) {
                AgeFilter(clouds: clouds)
                SizeFilter(clouds: clouds)
            }
            FileList(model: model, files: clouds.oldest, emptyTitle: clouds.isSearching ? "clouds.search_none" : "clouds.oldest_none")
        case .duplicates:
            HStack(spacing: Spacing.small) {
                Text("clouds.duplicates_short", bundle: .oust)
                    .font(Typography.body).foregroundStyle(Palette.onGradient)
                InfoButton(help: "clouds.duplicates_short") {
                    Text("clouds.duplicates_note", bundle: .oust)
                        .font(Typography.body).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Groups(model: model, groups: clouds.duplicates, emptyTitle: clouds.isSearching ? "clouds.search_none" : "clouds.duplicates_none")
        case .onThisMac:
            EvictHint(model: model)
            FileList(model: model, files: clouds.onThisMac, emptyTitle: clouds.isSearching ? "clouds.search_none" : "clouds.on_mac_none")
        }
    }
}

/// Un compte par carte, sur une seule rangée : d'un clic, la liste ne montre
/// plus que lui. Les cartes se partagent la largeur ; quand elles ne tiennent
/// plus, elles défilent de côté comme les disques de la barre d'outils, au
/// trackpad ou par les flèches qui apparaissent aux bords (Romain, 18/10/2026).
private struct Accounts: View {
    let clouds: CloudsModel
    @State private var available: CGFloat = 0
    @State private var position = ScrollPosition(idType: String.self)
    @State private var visible: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// De quoi tenir « Google Drive jeanne.martin@example.com », « 72,35 Go
    /// dans le cloud · 50 745 fichiers » et « Déconnecté : Google Drive est
    /// fermé » sur une ligne chacun. Dans une grille à 240 pt, les deux derniers
    /// passaient à la ligne (Romain : « étaler un peu plus le texte »).
    private static let minimumWidth: CGFloat = 300

    var body: some View {
        if let inventory = clouds.inventory {
            let ids = inventory.accounts.map(\.id)
            let count = CGFloat(max(ids.count, 1))
            let shared = (available - (count - 1) * Spacing.small) / count
            let overflows = shared < Self.minimumWidth
            ScrollView(.horizontal) {
                // Toutes à la hauteur de la plus haute, le contenu en haut à gauche :
                // une grille adaptative centrait chacune à sa hauteur, trois hauteurs
                // côte à côte dès qu'un compte est déconnecté (Romain : « c'est pas
                // de la même taille et aligné »).
                HStack(alignment: .top, spacing: Spacing.small) {
                    ForEach(inventory.accounts) { account in
                        card(account, inventory.summaries[account.id] ?? CloudAccountSummary())
                            .frame(width: max(shared, Self.minimumWidth))
                            .id(account.id)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            .scrollDisabled(!overflows)
            .scrollPosition($position)
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { visible = Set($0) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
            // Un fondu au bord dit qu'il y a d'autres comptes plus loin.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [hidden(ids.first, overflows) ? .clear : .black, .black],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 28)
                    Rectangle()
                    LinearGradient(colors: [.black, hidden(ids.last, overflows) ? .clear : .black],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 28)
                }
            }
            .overlay(alignment: .leading) {
                if hidden(ids.first, overflows) { arrow("chevron.left", step: -1, ids: ids) }
            }
            .overlay(alignment: .trailing) {
                if hidden(ids.last, overflows) { arrow("chevron.right", step: 1, ids: ids) }
            }
        }
    }

    private func hidden(_ id: String?, _ overflows: Bool) -> Bool {
        overflows && id.map { !visible.contains($0) } == true
    }

    /// Fait venir le compte suivant (ou précédent) caché, comme `DiskStrip`.
    private func arrow(_ symbol: String, step: Int, ids: [String]) -> some View {
        Button {
            let shown = ids.enumerated().filter { visible.contains($0.element) }.map(\.offset)
            guard let edge = step > 0 ? shown.max() : shown.min() else { return }
            let target = min(max(edge + step, 0), ids.count - 1)
            withAnimation(reduceMotion ? nil : .snappy) {
                position.scrollTo(id: ids[target], anchor: step > 0 ? .trailing : .leading)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(Text(step > 0 ? "clouds.scroll_next" : "clouds.scroll_previous", bundle: .oust))
        .accessibilityLabel(Text(step > 0 ? "clouds.scroll_next" : "clouds.scroll_previous", bundle: .oust))
    }

    private func card(_ account: CloudAccount, _ summary: CloudAccountSummary) -> some View {
        let on = clouds.selectedAccounts.contains(account.id)
        return Button { clouds.toggleAccount(account.id) } label: {
            HStack(alignment: .top, spacing: Spacing.small) {
                Image(systemName: account.service.symbol).font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    // Le compte à côté du service, une ligne de moins (Romain : « que
                    // ça prenne moins de lignes ») ; c'est lui qui cède s'il manque de place.
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                        Text(verbatim: account.service.displayName).font(Typography.body.weight(.semibold))
                            .layoutPriority(1)
                        if let name = account.account {
                            Text(verbatim: name).font(Typography.caption)
                                .foregroundStyle(Palette.onGradientSecondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .lineLimit(1)
                    // `bytes` et non `compactBytes` : un compte vide affichait « — dans le
                    // cloud » (Google Drive en mode flux, revue du 18/10/2026).
                    Text(verbatim: L10n.string("clouds.account_cloud", Formatters.bytes(summary.cloudBytes),
                                               Formatters.count(summary.files)))
                        .font(Typography.caption).monospacedDigit()
                    Text(verbatim: summary.localBytes > 0
                         ? L10n.string("clouds.account_mac", Formatters.compactBytes(summary.localBytes))
                         : L10n.string("clouds.account_mac_none"))
                        .font(Typography.caption).monospacedDigit()
                    if summary.unlistedFolders > 0 {
                        Label {
                            Text(verbatim: summary.unlistedFolders == 1 ? L10n.string("clouds.account_unlisted_one")
                                 : L10n.string("clouds.account_unlisted", Formatters.count(summary.unlistedFolders)))
                        } icon: { Image(systemName: "folder.badge.questionmark") }
                            .font(Typography.caption)
                    }
                    // Ses fichiers restent listés, verrouillés (Romain, 18/10/2026) ;
                    // le pourquoi au survol.
                    switch account.connection {
                    case .connected:
                        EmptyView()
                    case .appClosed:
                        Label {
                            Text(verbatim: L10n.string("clouds.account_app_closed", account.service.displayName))
                        } icon: { Image(systemName: "icloud.slash") }
                            .font(Typography.caption.weight(.semibold))
                            .help(Text(verbatim: L10n.string("clouds.account_app_closed_help", account.service.displayName)))
                    case .disconnected:
                        Label { Text("clouds.account_disconnected", bundle: .oust) } icon: { Image(systemName: "icloud.slash") }
                            .font(Typography.caption.weight(.semibold))
                            .help(Text("clouds.account_disconnected_help", bundle: .oust))
                    }
                }
                Spacer(minLength: 0)
            }
            // La hauteur de la plus haute carte, le contenu en haut à gauche.
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(Palette.onGradient)
            .padding(Spacing.medium)
            // Choisi : le profond de la section, qui fonce le fond au lieu de
            // l'éclaircir (IDENTITE §4, règle 3), comme les onglets de Photos.
            .background(on ? AnyShapeStyle(Palette.colors(for: .clouds).deep.opacity(0.6))
                           : AnyShapeStyle(Color.black.opacity(0.18)),
                        in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(.white.opacity(on ? 0.75 : 0.18), lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text("clouds.account_filter_help", bundle: .oust))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Ce qu'Oust! voit, ce qu'il ne voit pas, et ce que la suppression fait
/// vraiment (RULES.md, règle 9). Le contenu de la bulle du « ? ».
private struct Honesty: View {
    let clouds: CloudsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            line("network.slash", L10n.string("clouds.honesty.offline"))
            line("folder.badge.questionmark", L10n.string("clouds.honesty.listed"))
            if clouds.summary.unreadableFolders > 0 {
                line("exclamationmark.triangle", L10n.string("clouds.honesty.unreadable",
                                                             Formatters.count(clouds.summary.unreadableFolders)))
            }
            line("trash.square", L10n.string("clouds.honesty.delete"))
        }
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).frame(width: 20)
        }
        .font(Typography.body)
    }
}

/// Un « ? » dans un cercle, sur le fond de la section : l'explication s'ouvre
/// dans une bulle au lieu de rester affichée.
private struct InfoButton<Content: View>: View {
    let help: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.onGradient)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text(help, bundle: .oust))
        .accessibilityLabel(Text(help, bundle: .oust))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            content()
                .padding(Spacing.large)
                .frame(width: 420, alignment: .leading)
        }
    }
}

/// Les quatre listes, d'un clic : combien, et ce qu'elles pèsent.
private struct TabBar: View {
    @Bindable var clouds: CloudsModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.small)], spacing: Spacing.small) {
            ForEach(CloudsModel.Tab.allCases) { tab in
                let on = clouds.tab == tab
                Button { clouds.tab = tab } label: {
                    HStack(spacing: Spacing.small) {
                        Image(systemName: tab.symbol).font(.system(size: 15, weight: .semibold))
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
                    .background(on ? AnyShapeStyle(Palette.colors(for: .clouds).deep.opacity(0.6))
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

    private func summary(_ tab: CloudsModel.Tab) -> String {
        let count = clouds.count(tab)
        let size = Formatters.compactBytes(clouds.cloudBytes(tab))
        switch tab {
        case .duplicates:
            return count == 1 ? L10n.string("clouds.tab_groups_one", size)
                : L10n.string("clouds.tab_groups", Formatters.count(count), size)
        case .onThisMac:
            return count == 1 ? L10n.string("clouds.tab_on_mac_one", size)
                : L10n.string("clouds.tab_on_mac", Formatters.count(count), size)
        case .largest, .oldest:
            return count == 1 ? L10n.string("clouds.tab_files_one", size)
                : L10n.string("clouds.tab_files", Formatters.count(count), size)
        }
    }
}

/// Par nom ou par dossier, dans l'onglet ouvert : les comptes choisis et
/// l'âge comptent encore, le seuil de taille non.
private struct SearchField: View {
    @Bindable var clouds: CloudsModel

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "magnifyingglass")
            TextField(text: $clouds.query) { Text("clouds.search_prompt", bundle: .oust) }
                .textFieldStyle(.plain)
            if !clouds.query.isEmpty {
                Button { clouds.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("clouds.search_clear", bundle: .oust))
            }
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SizeFilter: View {
    @Bindable var clouds: CloudsModel

    var body: some View {
        Picker(selection: $clouds.minimumSize) {
            ForEach(CloudsModel.SizePreset.allCases) { preset in
                Text(verbatim: L10n.string("clouds.at_least", Formatters.compactBytes(preset.rawValue))).tag(preset)
            }
        } label: {
            Text("clouds.size", bundle: .oust).foregroundStyle(Palette.onGradient)
        }
        .fixedSize()
        // Un fichier cherché par son nom ne doit pas être caché par sa taille.
        .disabled(clouds.isSearching)
        .help(clouds.isSearching ? Text("clouds.search_all_sizes", bundle: .oust) : Text(verbatim: ""))
    }
}

private struct AgeFilter: View {
    @Bindable var clouds: CloudsModel

    var body: some View {
        Picker(selection: $clouds.age) {
            ForEach(CloudsModel.AgePreset.allCases) { preset in
                Text(LocalizedStringKey(preset.localizationKey), bundle: .oust).tag(preset)
            }
        } label: {
            Text("clouds.unchanged_since", bundle: .oust).foregroundStyle(Palette.onGradient)
        }
        .fixedSize()
    }
}

/// Pour gagner de la place ici sans rien supprimer, l'éviction existe déjà.
private struct EvictHint: View {
    let model: AppModel

    var body: some View {
        GlassCard {
            HStack(alignment: .center, spacing: Spacing.medium) {
                Label {
                    Text("clouds.on_mac_note", bundle: .oust).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "icloud.and.arrow.up")
                }
                .font(Typography.body)
                .foregroundStyle(Palette.onGradient)
                Spacer(minLength: Spacing.small)
                Button {
                    model.searchText = ""
                    model.section = .system
                } label: { Text("clouds.evict_instead", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
        }
    }
}

// MARK: - Listes

/// Les titres des colonnes, à la largeur de celles des lignes.
private struct ColumnHeader: View {
    var body: some View {
        HStack(spacing: Spacing.medium) {
            Text("clouds.column.file", bundle: .oust).padding(.leading, 20 + Spacing.medium + 28 + Spacing.medium)
            Spacer(minLength: Spacing.medium)
            Text("clouds.column.modified", bundle: .oust).frame(width: Columns.date, alignment: .trailing)
            Text("clouds.column.cloud", bundle: .oust).frame(width: Columns.size, alignment: .trailing)
            Text("clouds.column.mac", bundle: .oust).frame(width: Columns.size, alignment: .trailing)
            Color.clear.frame(width: Columns.info)
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.vertical, Spacing.small)
    }
}

private enum Columns {
    static let date: CGFloat = 104
    static let size: CGFloat = 84
    static let info: CGFloat = 18
}

private struct FileList: View {
    let model: AppModel
    let files: [CloudEntry]
    let emptyTitle: LocalizedStringKey
    @State private var limit = 200

    var body: some View {
        if files.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: emptyTitle)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ColumnHeader()
                Divider().opacity(0.25)
                LazyVStack(spacing: 0) {
                    ForEach(files.prefix(limit)) { file in
                        FileRow(model: model, file: file, showsService: model.clouds.selectedAccounts.count != 1)
                        Divider().opacity(0.25)
                    }
                }
                if files.count > limit {
                    Button { limit += 200 } label: { Text("group.show_more", bundle: .oust) }
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

/// Un fichier : nom, où il est, sa date, ce qu'il pèse dans le nuage et ici.
private struct FileRow: View {
    let model: AppModel
    let file: CloudEntry
    let showsService: Bool
    var group: CloudDuplicateGroup?
    @State private var explaining = false

    private var clouds: CloudsModel { model.clouds }

    var body: some View {
        let item = clouds.item(for: file)
        let inCart = clouds.isInCart(file)
        let enabled = group.map { clouds.canToggle(file, in: $0) } ?? item.isSelectable
        HStack(spacing: Spacing.medium) {
            CheckButton(item: item, inCart: inCart, enabled: enabled) { clouds.toggle(file) }
            Image(systemName: file.isPackage ? "shippingbox" : FileKind.of(file.name).symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Palette.color(for: .cloudItems).gradient.opacity(file.isDataless ? 0.55 : 1),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(verbatim: file.name).font(Typography.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: Spacing.tight) {
                    Text(verbatim: place)
                        .font(Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    if let reason = item.protections.first {
                        Tag(Describe.protection(reason), symbol: "lock.fill", tint: Palette.vivid(for: .protected))
                    } else if group != nil, !inCart, !enabled {
                        // Le dernier exemplaire d'un groupe reste (SPEC §7). Le dossier
                        // se tronque d'abord : l'étiquette finissait en « Dernier
                        // exemplaire,… » (revue du 18/10/2026).
                        Tag(L10n.string("clouds.kept"), symbol: "star.fill", tint: Palette.vivid(for: .safe))
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
            }
            Spacer(minLength: Spacing.medium)
            Text(verbatim: file.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? L10n.string("clouds.no_date"))
                .font(Typography.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: Columns.date, alignment: .trailing)
            Text(verbatim: Formatters.compactBytes(file.cloudSize)).font(Typography.size)
                .frame(width: Columns.size, alignment: .trailing)
            Group {
                if file.isDataless {
                    Label { Text("clouds.online_only", bundle: .oust) } icon: { Image(systemName: "icloud") }
                        .labelStyle(.titleAndIcon)
                        .font(Typography.caption).foregroundStyle(.secondary)
                        .help(Text("clouds.online_only_help", bundle: .oust))
                } else {
                    Text(verbatim: Formatters.compactBytes(file.localSize)).font(Typography.size)
                }
            }
            .frame(width: Columns.size, alignment: .trailing)
            Button { explaining.toggle() } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: Columns.info)
            .popover(isPresented: $explaining, arrowEdge: .trailing) { Explanation(item: item) }
            .accessibilityLabel(Text("row.why", bundle: .oust))
        }
        .padding(.vertical, Spacing.tight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if enabled { clouds.toggle(file) } }
        .contextMenu {
            // Le Finder montre le fantôme sans le télécharger ; le coup d'œil, lui,
            // le téléchargerait : il n'est pas proposé ici.
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                Label { Text("row.reveal", bundle: .oust) } icon: { Image(systemName: "folder") }
            }
            Button { clouds.toggle(file) } label: {
                Label { Text(inCart ? "row.remove_from_cart" : "row.add_to_cart", bundle: .oust) } icon: { Image(systemName: "trash") }
            }
            .disabled(!enabled)
        }
    }

    /// Le service quand plusieurs comptes sont montrés, puis le dossier.
    private var place: String {
        let account = clouds.account(file.accountID)
        let parts = (showsService ? [account?.displayName].compactMap { $0 } : []) + file.folder
        return parts.joined(separator: " › ")
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
                .foregroundStyle(inCart ? AnyShapeStyle(Palette.color(for: .cloudItems)) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(inCart ? "row.remove_from_cart" : "row.add_to_cart", bundle: .oust))
        .help(Text(verbatim: item.protections.first.map(Describe.protection) ?? L10n.string("row.add_to_cart")))
    }
}

// MARK: - Doublons évidents

private struct Groups: View {
    let model: AppModel
    let groups: [CloudDuplicateGroup]
    let emptyTitle: LocalizedStringKey
    @State private var limit = 40

    var body: some View {
        if groups.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: emptyTitle)
        } else {
            LazyVStack(spacing: Spacing.medium) {
                ForEach(groups.prefix(limit)) { group in
                    GroupCard(model: model, group: group)
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
    let group: CloudDuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.small) {
                Image(systemName: "doc.on.doc").foregroundStyle(Palette.color(for: .cloudItems))
                Text(verbatim: group.name).font(Typography.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(verbatim: L10n.string("clouds.group_detail", Formatters.count(group.files.count),
                                           Formatters.compactBytes(group.size), Formatters.compactBytes(group.cloudSavings)))
                    .font(Typography.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.bottom, Spacing.small)
            Divider().opacity(0.25)
            ForEach(group.files) { file in
                // Le service toujours : un doublon est souvent d'un nuage à l'autre.
                FileRow(model: model, file: file, showsService: true, group: group)
                Divider().opacity(0.25)
            }
        }
        .padding(Spacing.large)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }
}
