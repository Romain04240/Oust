import AppKit
import SwiftUI
import OustCore
import OustLocalization

/// Une ligne d'élément : cocher, comprendre, voir ce que ça rend.
public struct ItemRow: View {
    let item: CleanupItem
    let enabled: Bool
    let isSelected: Bool
    let showOwner: Bool
    let showsPreview: Bool
    let preview: (() -> Void)?
    let onToggle: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var explaining = false
    @State private var hovering = false

    /// `preview` : le coup d'œil, pour un élément d'un seul chemin. L'œil
    /// paraît au survol, ou toujours quand `showsPreview` (la ligne choisie).
    public init(_ item: CleanupItem, enabled: Bool = true, isSelected: Bool, showOwner: Bool = false,
                showsPreview: Bool = false, preview: (() -> Void)? = nil, onToggle: @escaping () -> Void) {
        self.item = item
        self.enabled = enabled && item.isSelectable
        self.isSelected = isSelected
        self.showOwner = showOwner
        self.showsPreview = showsPreview
        self.preview = preview
        self.onToggle = onToggle
    }

    public var body: some View {
        HStack(spacing: Spacing.medium) {
            Button(action: onToggle) {
                Image(systemName: checkSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(enabled ? (isSelected ? Palette.color(for: item.category) : .secondary) : .secondary.opacity(0.6))
                    .contentTransition(reduceMotion || !isEnabled || !enabled ? .identity : .symbolEffect(.replace))
            }
            .buttonStyle(SelectionFeedbackStyle())
            .disabled(!enabled)
            .accessibilityLabel(Text("row.select", bundle: .oust))

            Image(systemName: item.category.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Palette.color(for: item.category).gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: Spacing.hair) {
                HStack(spacing: Spacing.small) {
                    Text(verbatim: item.title).font(Typography.body.weight(.semibold)).lineLimit(1)
                    // Un propriétaire qui répète le nom (« Spotify  Spotify ») n'apprend rien.
                    if showOwner, item.owner != item.title {
                        Text(verbatim: item.owner).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: Spacing.tight) {
                    SafetyBadge(item.safety)
                    if item.isIncompleteSafariDownload {
                        Tag(L10n.string("system.safari_download_review"), symbol: "lock.fill", tint: Palette.vivid(for: .protected))
                    } else if item.isInvalidPreference {
                        Tag(Describe.ruleTitle(item.ruleID), symbol: "lock.fill", tint: Palette.vivid(for: .protected))
                    } else if let reason = item.protections.first {
                        Tag(Describe.protection(reason), symbol: "lock.fill", tint: Palette.vivid(for: .protected))
                    }
                    ForEach(Array(item.notes.prefix(2).enumerated()), id: \.offset) { _, note in
                        Tag(Describe.note(note), tint: .secondary)
                    }
                    // Le moins important de la ligne : c'est lui qui raccourcit
                    // en premier quand la place manque, pas les pastilles.
                    if !item.isIncompleteSafariDownload && !item.isInvalidPreference && !item.isAccountArchive && !item.isDeviceBackup {
                        Text(verbatim: item.method.isSnapshot ? L10n.string("snapshot.irreversible") : Describe.rebuild(item.rebuild))
                            .font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                if let detail = item.detail, detail != item.title {
                    Text(verbatim: detail).font(Typography.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                if item.isDeviceBackup && item.lastActivity == nil {
                    Text("system.device_backup_unknown_date", bundle: .oust)
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
                if item.category == .userLogs, let modified = item.lastActivity {
                    Text(verbatim: L10n.string("system.user_log_modified", Formatters.relative(modified)))
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Spacing.medium)
            VStack(alignment: .trailing, spacing: Spacing.hair) {
                if item.isIncompleteSafariDownload {
                    if item.sizes.allocated > 0 {
                        Text(verbatim: L10n.string("system.safari_download_occupied", Formatters.compactBytes(item.sizes.allocated)))
                            .font(Typography.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else if item.isAccountArchive || item.isDeviceBackup || item.category == .cloudFiles {
                    Text(verbatim: L10n.string("system.safari_download_occupied", Formatters.compactBytes(item.sizes.allocated)))
                        .font(Typography.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if item.method.isSnapshot {
                    if let bytes = item.measuredSnapshotBytes {
                        Text(verbatim: L10n.string("snapshot.private_size", Formatters.bytes(bytes)))
                            .font(Typography.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("snapshot.size_unknown", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                    }
                } else if !item.isInvalidPreference {
                    Text(verbatim: Formatters.compactBytes(item.sizes.freeable)).font(Typography.size)
                }
                if !item.isIncompleteSafariDownload, !item.isInvalidPreference, !item.isAccountArchive, !item.isDeviceBackup, item.category != .cloudFiles, item.sizes.retained > 0 {
                    Text(verbatim: L10n.string("row.retained", Formatters.compactBytes(item.sizes.retained)))
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
            }
            if let preview, let url = item.paths.first {
                // La sorte du chemin (fichier, dossier, paquet) n'est lue que
                // sur la ligne survolée ou choisie.
                let visible = hovering || showsPreview
                PreviewButton(kind: visible ? PreviewKind.of(url) : .file, isVisible: visible, action: preview)
            }
            Button { explaining.toggle() } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $explaining, arrowEdge: .trailing) { Explanation(item: item) }
            .accessibilityLabel(Text("row.why", bundle: .oust))
        }
        .padding(.vertical, Spacing.tight)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if enabled { onToggle() } }
        .contextMenu {
            if let preview, let url = item.paths.first {
                PreviewMenuItem(kind: PreviewKind.of(url), action: preview)
            }
            if !item.paths.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(item.paths) } label: {
                    Label { Text("row.reveal", bundle: .oust) } icon: { Image(systemName: "folder") }
                }
            }
            Button(action: onToggle) {
                Label { Text(isSelected ? "row.remove_from_cart" : "row.add_to_cart", bundle: .oust) } icon: { Image(systemName: isSelected ? "trash.slash" : "trash") }
            }
            .disabled(!enabled)
        }
    }

    private var checkSymbol: String {
        if !enabled { return "lock.circle" }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }
}

/// L'appui anime uniquement le label : les lignes et leurs cibles restent fixes.
private struct SelectionFeedbackStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled && configuration.isPressed ? 0.7 : 1)
            .animation(isEnabled && !reduceMotion ? .easeOut(duration: 0.13) : nil, value: configuration.isPressed)
            .transaction { transaction in
                if !isEnabled || reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

/// « Pourquoi ? » : ce que c'est, comment ça revient, ce qu'Oust! en fera.
public struct Explanation: View {
    let item: CleanupItem

    public init(item: CleanupItem) {
        self.item = item
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack {
                Text(verbatim: Describe.ruleTitle(item.ruleID)).font(Typography.headline)
                Spacer()
                SafetyBadge(item.safety)
            }
            section("explain.what", Describe.ruleWhat(item.ruleID))
            if item.isIncompleteSafariDownload || item.isInvalidPreference || item.isAccountArchive || item.isDeviceBackup {
                section("explain.back", Describe.ruleBack(item.ruleID))
            } else {
                section("explain.back", Describe.ruleBack(item.ruleID) + " " + (item.method.isSnapshot ? L10n.string("snapshot.irreversible") : Describe.rebuild(item.rebuild)))
            }
            section("explain.method", Describe.method(item.method))
            if !item.protections.isEmpty {
                section("explain.protected", item.protections.map(Describe.protection).joined(separator: "\n"))
            }
            if !item.paths.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text("explain.where", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                    ForEach(item.paths.prefix(4), id: \.self) { url in
                        Text(verbatim: url.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    }
                    if item.paths.count > 4 {
                        Text(verbatim: "+ \(item.paths.count - 4)").font(Typography.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if (item.isIncompleteSafariDownload || item.isAccountArchive || item.isDeviceBackup), item.sizes.allocated > 0 {
                Text(verbatim: L10n.string("system.safari_download_occupied", Formatters.bytes(item.sizes.allocated)))
                    .font(Typography.caption).foregroundStyle(.secondary)
            } else if !item.isIncompleteSafariDownload && !item.isInvalidPreference && !item.isAccountArchive && !item.isDeviceBackup {
                Text(verbatim: L10n.string("explain.sizes", Formatters.bytes(item.sizes.allocated), Formatters.bytes(item.sizes.freeable)))
                    .font(Typography.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.large)
        .frame(width: 380)
    }

    private func section(_ key: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            Text(key, bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
            Text(verbatim: text).font(Typography.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Le gabarit d'une section : fond coloré, en-tête, contenu défilant.
public struct SectionScaffold<Trailing: View, Content: View>: View {
    let section: AppSection
    let title: LocalizedStringKey?
    let symbol: String?
    let subtitle: LocalizedStringKey?
    let trailing: Trailing
    let content: Content

    /// `title` et `symbol` remplacent ceux de la section, pour une vue qui emprunte
    /// son fond sans en être une (la recherche).
    public init(_ section: AppSection, title: LocalizedStringKey? = nil, symbol: String? = nil,
                subtitle: LocalizedStringKey? = nil,
                @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.section = section
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    public var body: some View {
        ZStack {
            SectionBackground(section)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xLarge) {
                    SectionHeader(section, title: title, symbol: symbol, subtitle: subtitle) { trailing }
                    content
                }
                .padding(Spacing.xxLarge)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .stopsUnderToolbar()
            .onSectionBackground()
        }
    }
}

extension SectionScaffold where Trailing == EmptyView {
    public init(_ section: AppSection, subtitle: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(section, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// La case « tout cocher » posée au-dessus d'une liste, à la place et à la
/// taille des cases de ses lignes : vide, cochée, ou un tiret quand seule une
/// partie l'est.
public struct SelectAllRow: View {
    public enum State: Sendable {
        case none, some, all
    }

    let state: State
    let count: Int
    let tint: Color
    let onToggle: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: State, count: Int, tint: Color, onToggle: @escaping () -> Void) {
        self.state = state
        self.count = count
        self.tint = tint
        self.onToggle = onToggle
    }

    public var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Spacing.medium) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(state == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                    .contentTransition(reduceMotion || !isEnabled ? .identity : .symbolEffect(.replace))
                Text(state == .all ? "group.deselect_all" : "group.select_all", bundle: .oust)
                    .font(Typography.body.weight(.semibold))
                Text(verbatim: L10n.string("group.selectable_count", Formatters.count(count)))
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(SelectionFeedbackStyle())
        .accessibilityValue(Text(state == .all ? "group.deselect_all" : "group.select_all", bundle: .oust))
    }

    private var symbol: String {
        switch state {
        case .none: "circle"
        case .some: "minus.circle.fill"
        case .all: "checkmark.circle.fill"
        }
    }
}

/// Un groupe d'éléments sous un titre, avec son total et « tout cocher ».
public struct ItemGroup<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let total: Int64
    let totalLabel: String?
    let selectAllTitle: LocalizedStringKey
    let selectAll: (() -> Void)?
    let content: Content

    /// `selectAllTitle` : l'intitulé du bouton d'en-tête, « Cocher le sûr » par
    /// défaut ; « Tout cocher » / « Tout décocher » là où tout peut être choisi.
    public init(title: String, symbol: String, tint: Color, total: Int64, totalLabel: String? = nil,
                selectAllTitle: LocalizedStringKey = "group.select_safe", selectAll: (() -> Void)? = nil,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.total = total
        self.totalLabel = totalLabel
        self.selectAllTitle = selectAllTitle
        self.selectAll = selectAll
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.small) {
                Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 15, weight: .bold))
                Text(verbatim: title).font(Typography.headline)
                Spacer()
                Text(verbatim: totalLabel ?? Formatters.compactBytes(total)).font(Typography.size).foregroundStyle(.secondary)
                if let selectAll {
                    Button(action: selectAll) { Text(selectAllTitle, bundle: .oust) }
                        .buttonStyle(.borderless)
                        .font(Typography.caption)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.medium)
            Divider().opacity(0.4)
            content
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.small)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
