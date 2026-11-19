import AppKit
import SwiftUI
import FeatureApplications
import FeatureArchive
import FeatureBrowsers
import FeatureCart
import FeatureClouds
import FeatureDevAI
import FeatureDisks
import FeatureDuplicates
import FeatureExplorer
import FeatureHistory
import FeatureLargeFiles
import FeatureOverview
import FeaturePhotos
import FeatureSearch
import FeatureSystem
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// La fenêtre : la barre latérale, et la section choisie sur son fond coloré.
struct RootView: View {
    @Bindable var model: AppModel
    /// La largeur de la colonne de détail : les disques de la barre d'outils
    /// s'y tiennent, et défilent au-delà.
    @State private var detailWidth: CGFloat = 800
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            // La barre latérale est en verre sombre dans les deux apparences,
            // comme tout ce qui est posé sur le fond coloré (IDENTITE §4,
            // règle 2). En clair, elle virait au lilas pâle à texte foncé
            // (« moche », Romain, 18/10/2026). La recherche est posée ici pour
            // que son champ hérite du même schéma.
            Sidebar(model: model)
                .searchable(text: $model.searchText, placement: .sidebar, prompt: Text("search.prompt", bundle: .oust))
                .environment(\.colorScheme, .dark)
                .background(DarkColumn())
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            // Une recherche en cours passe devant la section : on cherche partout.
            Group {
                if model.isSearching { SearchView(model: model) } else {
                    detail.modifier(SectionEntrance()).id(model.section).transition(.identity)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
            .safeAreaInset(edge: .top, spacing: 0) {
                GuidedReviewBanner(model: model)
            }
            // Cocher ne servait à rien tant qu'on ne savait pas où aller ensuite :
            // aucune section ne disait comment faire le vide (Romain, 18/10/2026).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if BinBar.isShown(in: model) {
                    BinBar(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: model.cart.isEmpty)
            // Les disques au centre ; à droite, l'Historique seul, en icône : les
            // Réglages ont quitté la barre d'outils (⌘, et le panneau de la barre
            // des menus y mènent), toute la place va aux disques (Romain,
            // 18/10/2026).
            .toolbar {
                // La place de l'Historique et des marges retirée de la colonne.
                DiskToolbar(model: model, maxWidth: max(240, detailWidth - 120))
                // `.primaryAction` posait l'Historique à gauche, contre le bouton
                // de la barre latérale : l'espace flexible le pousse au bord droit.
                ToolbarSpacer(.flexible)
                ToolbarItem {
                    ToolbarSectionButton(section: .history, model: model)
                }
            }
        }
        .alert(
            Text(verbatim: L10n.string("volume.offer_title", model.offeredVolume?.name ?? "")),
            isPresented: Binding(get: { model.offeredVolume != nil }, set: { if !$0 { model.offeredVolume = nil } }),
            presenting: model.offeredVolume
        ) { volume in
            // Analysé comme le disque de démarrage, depuis la vue d'ensemble.
            Button {
                model.section = .overview
                Task { await model.analyze(volume) }
            } label: { Text("volume.offer_scan", bundle: .oust) }
            Button(role: .cancel) {} label: { Text("common.later", bundle: .oust) }
        } message: { _ in
            Text("volume.offer_analyze_message", bundle: .oust)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .overview: OverviewView(model: model)
        case .advice: AdviceView(model: model)
        case .timeMachine: TimeMachineView(model: model)
        case .transfer: TransferView(model: model.transfer)
        case .developer: DeveloperView(model: model)
        case .archive: ArchiveView(model: model)
        case .explorer: ExplorerView(model: model)
        case .largeFiles: LargeFilesView(model: model)
        case .duplicates: DuplicatesView(model: model)
        case .photos: PhotosView(model: model)
        case .clouds: CloudsView(model: model)
        case .applications: ApplicationsView(model: model)
        case .browsers: BrowsersView(model: model)
        case .system: SystemView(model: model)
        case .history: HistoryView(model: model)
        case .cart: CartView(model: model)
        }
    }
}

/// Animate only the incoming page. Keeping an outgoing scanner view alive for
/// a crossfade can delay its cancellation until the new page has started work.
private struct SectionEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(x: appeared || reduceMotion ? 0 : 18, y: appeared || reduceMotion ? 0 : 3)
            .onAppear {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { appeared = true }
            }
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel

    // Une seule liste : deux sections creusaient entre « Système » et
    // « Corbeille » un écart plus grand qu'entre les autres lignes (remarque de
    // Romain, 18/10/2026).
    // L'ordre de Romain (18/10/2026) : ce qu'Oust! trouve pour vous
    // (applications, navigateurs, système), puis ce qu'on explore soi-même,
    // puis ce qui ne sert qu'aux développeurs — Oust! doit être utilisable par
    // tous. La corbeille est en bas ; le disque au centre de la barre d'outils,
    // l'historique et les réglages à sa droite.
    // Photos suit les Doublons (Romain, 18/10/2026) : la photothèque est le
    // plus gros gisement du grand public. Le Cloud vient juste après (nommé
    // ainsi par Romain, 18/10/2026, plutôt que « Nuages ») :
    // même public, même question (« qu'est-ce qui pèse, là-dedans ? »), et
    // iCloud y est déjà.
    private let sections: [AppSection] = [
        .advice, .applications, .browsers, .system, .timeMachine, .explorer, .largeFiles, .duplicates, .photos, .clouds, .developer,
        .transfer, .archive,
    ]

    var body: some View {
        // Pendant une recherche, aucune section n'est sélectionnée ; en choisir une
        // quitte la recherche (revue du 18/10/2026 : « Vue d'ensemble » restait en surbrillance).
        List(selection: Binding(get: { model.isSearching ? nil : model.section },
                                set: { if let value = $0 { model.searchText = ""; model.section = value } })) {
            row(.overview)
            ForEach(model.preferences.orderedSidebarTools(sections)) { section in
                row(section)
                    .contextMenu {
                        Button {
                            model.preferences.toggleSidebarPin(section)
                        } label: {
                            Text(model.preferences.sidebarPins.contains(section) ? "sidebar.unpin" : "sidebar.pin", bundle: .oust)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                BinTile(model: model)
                FeedbackTile()
            }
            .padding(Spacing.medium)
            .padding(.bottom, Spacing.small)
        }
    }

    private func row(_ section: AppSection) -> some View {
        Label {
            HStack {
                Text(LocalizedStringKey(section.localizationKey), bundle: .oust)
                Spacer()
                if model.preferences.sidebarPins.contains(section) {
                    Image(systemName: "pin.fill").font(Typography.caption)
                        .accessibilityHidden(true)
                }
                if section == .developer || section == .overview, model.analysis.isRunning {
                    ProgressView().controlSize(.mini)
                }
            }
        } icon: {
            Image(systemName: section.symbol)
                .foregroundStyle(Palette.linearGradient(for: section))
        }
        .tag(section)
    }
}

/// Écrire au développeur : un bug, une idée, autre chose (Romain, 18/10/2026).
///
/// Oust! n'envoie rien lui-même (RULES.md, règle 11) : il ouvre un e-mail
/// prérempli dans la messagerie de l'utilisateur, qui le relit et l'envoie. Le
/// gabarit ne porte que la version d'Oust!, celle de macOS et le modèle du Mac,
/// et le dit en toutes lettres (Romain, 18/10/2026).
private struct FeedbackTile: View {
    @State private var showsPanel = false

    var body: some View {
        Button { showsPanel.toggle() } label: {
            HStack(spacing: Spacing.medium) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Palette.linearGradient(for: .history), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("feedback.menu", bundle: .oust).font(Typography.caption.weight(.semibold))
                    Text("feedback.tagline", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsPanel, arrowEdge: .trailing) {
            FeedbackPanel { kind in
                showsPanel = false
                FeedbackMail.compose(kind)
            }
        }
    }
}

/// Le choix du message, en trois cartes, et ce que l'e-mail emportera.
private struct FeedbackPanel: View {
    let onChoose: (FeedbackMail.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text("feedback.menu", bundle: .oust).font(Typography.headline)
                Text("feedback.intro", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Spacing.small) {
                ForEach(FeedbackMail.Kind.allCases, id: \.self) { kind in
                    Button { onChoose(kind) } label: { FeedbackCard(kind: kind) }
                        .buttonStyle(.plain)
                }
            }
            Label {
                Text("feedback.privacy", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.xLarge)
        .frame(width: 340)
    }
}

private struct FeedbackCard: View {
    let kind: FeedbackMail.Kind
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Image(systemName: kind.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Palette.linearGradient(for: kind.section), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(kind.titleKey, bundle: .oust).font(Typography.body.weight(.semibold))
                Text(kind.detailKey, bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
        }
        .padding(Spacing.medium)
        .background(.quaternary.opacity(hovering ? 0.9 : 0.45), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// L'e-mail prérempli : sujet selon le choix, et seulement les versions et le modèle.
enum FeedbackMail {
    static let address = "daniel@blanc-conseil.fr"

    enum Kind: String, CaseIterable {
        case bug, idea, other
        // Une chaîne d'abord : interpolée directement dans LocalizedStringKey,
        // « feedback.\(rawValue) » devenait le format « feedback.%@ », et les
        // cartes montraient leur clé brute.
        var titleKey: LocalizedStringKey { LocalizedStringKey("feedback." + rawValue) }
        var detailKey: LocalizedStringKey { LocalizedStringKey("feedback." + rawValue + "_detail") }
        var symbol: String {
            switch self {
            case .bug: "ladybug.fill"
            case .idea: "lightbulb.fill"
            case .other: "bubble.left.and.text.bubble.right.fill"
            }
        }
        /// Des dégradés déjà vérifiés de l'identité, pas de couleurs inventées.
        var section: AppSection {
            switch self {
            case .bug: .browsers
            case .idea: .duplicates
            case .other: .developer
            }
        }
    }

    static func compose(_ kind: Kind) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let system = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: L10n.string("feedback.subject.\(kind.rawValue)")),
            // Un gabarit par choix : un bug se décrit autrement qu'une idée
            // (Romain : « qu'est-ce qui va les différencier dans l'e-mail ? »).
            URLQueryItem(name: "body", value: L10n.string("feedback.body." + kind.rawValue) + "\n\n"
                + L10n.string("feedback.footer", version, build, system, machineModel())),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    /// « Mac15,8 » : le modèle, rien qui désigne la personne.
    static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// La corbeille d'Oust!, en bas de la barre latérale : ce qu'elle rendra, d'un
/// coup d'œil (Romain, 18/10/2026).
private struct BinTile: View {
    let model: AppModel

    private var isCurrent: Bool { model.section == .cart && !model.isSearching }

    var body: some View {
        Button {
            model.searchText = ""
            model.section = .cart
        } label: {
            HStack(spacing: Spacing.medium) {
                Image(systemName: AppSection.cart.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Palette.linearGradient(for: .cart), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(LocalizedStringKey(AppSection.cart.localizationKey), bundle: .oust)
                        .font(Typography.body.weight(.semibold))
                    Group {
                        if model.cart.isEmpty {
                            Text("sidebar.bin_empty", bundle: .oust)
                        } else if model.cartOnlySnapshots {
                            Text(verbatim: L10n.string("cart.snapshot_count", Formatters.count(model.cartSnapshotCount)))
                        } else if model.cartFreesNothingHere {
                            // Des fichiers du cloud restés en ligne ne rendent rien ici :
                            // « — à libérer » se lisait comme une erreur (essai du 18/10/2026).
                            Text("cart.nothing_on_mac", bundle: .oust)
                        } else {
                            Text(verbatim: L10n.string("sidebar.bin_frees", Formatters.compactBytes(model.cartTotal)))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(model.cartTotal)))
                        }
                    }
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.small)
            .background(Color.white.opacity(isCurrent ? 0.16 : 0.07),
                        in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(.white.opacity(isCurrent ? 0.3 : 0.1), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: model.cartTotal)
    }
}

/// En bas de chaque section, dès que la corbeille contient quelque chose : le
/// chemin vers « Faire le vide ». Il passe par la corbeille, sa revue et sa
/// confirmation, comme le bouton de la vue d'ensemble (SPEC §6.3).
private struct BinBar: View {
    let model: AppModel

    /// Pas là où le bouton existe déjà (vue d'ensemble, corbeille), ni là où
    /// l'on ne coche rien (historique).
    static func isShown(in model: AppModel) -> Bool {
        guard !model.cart.isEmpty else { return false }
        if model.isSearching { return true }
        return ![.overview, .cart, .history].contains(model.section)
    }

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Image(systemName: AppSection.cart.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Palette.linearGradient(for: .cart), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text("binbar.title", bundle: .oust).font(Typography.headline)
                Text("binbar.detail", bundle: .oust).font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
            }
            .foregroundStyle(Palette.onGradient)
            .lineLimit(1)
            Spacer(minLength: Spacing.medium)
            Button {
                model.searchText = ""
                model.section = .cart
            } label: {
                // Sans montant quand rien ne revient ici, comme dans la corbeille.
                Text(verbatim: model.cartTotal > 0
                     ? L10n.string("overview.go_clean", Formatters.compactBytes(model.cartTotal))
                     : L10n.string("cart.clean_plain"))
                    .lineLimit(1)
                    .contentTransition(.numericText(value: Double(model.cartTotal)))
            }
            .buttonStyle(PrimaryButtonStyle(section: .cart, eclat: true))
            .fixedSize()
        }
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.medium)
        .glassEffect(.regular.tint(.black.opacity(0.18)), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .padding(.horizontal, Spacing.xxLarge)
        .padding(.bottom, Spacing.large)
        .environment(\.colorScheme, .dark)
    }
}

/// Un bouton de barre d'outils qui ouvre une section, marqué quand elle est ouverte.
private struct ToolbarSectionButton: View {
    let section: AppSection
    let model: AppModel

    private var isCurrent: Bool { model.section == section && !model.isSearching }

    var body: some View {
        Button {
            model.searchText = ""
            model.section = section
        } label: {
            Label {
                Text(LocalizedStringKey(section.localizationKey), bundle: .oust)
            } icon: {
                Image(systemName: section.symbol)
                    .symbolVariant(isCurrent ? .fill : .none)
            }
            // L'icône seule, son nom en bulle d'aide : le texte prenait la place
            // des disques (Romain, 18/10/2026).
            .labelStyle(.iconOnly)
        }
        .help(Text(LocalizedStringKey(section.localizationKey), bundle: .oust))
    }
}

/// Donne l'apparence sombre à toute la colonne qui la contient, verre compris.
///
/// `.environment(\.colorScheme, .dark)` ne suffit pas : il blanchit le texte,
/// mais le verre de la barre latérale est dessiné par AppKit d'après
/// l'apparence de la fenêtre, et restait clair — texte blanc sur lilas pâle.
/// On remonte donc jusqu'à la vue que le `NSSplitView` range, et c'est elle qui
/// passe en sombre. Introuvable, on ne touche à rien.
private struct DarkColumn: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view: NSView? = self
            while let current = view, !(current.superview is NSSplitView) { view = current.superview }
            view?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
