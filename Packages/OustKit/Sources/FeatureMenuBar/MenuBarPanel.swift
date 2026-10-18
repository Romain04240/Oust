import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustWatch

/// Le panneau de la barre de menus : tous les disques montés, la corbeille
/// d'Oust!, la fenêtre. Une ligne par information, quitte à prendre de la
/// largeur (Romain, 18/10/2026 : « trop étalé sur la hauteur »).
///
/// On y regarde ; on fait le vide dans la fenêtre, où l'on revoit ce qui part
/// et où l'on confirme (SPEC §6.3). Pas d'analyse d'ici : on ouvre Oust!.
public struct MenuBarPanel: View {
    @Bindable var model: AppModel
    /// Les disques en cours d'éjection (points de montage).
    @State private var ejecting: Set<String> = []
    /// Le refus de macOS au dernier essai, par disque.
    @State private var ejectFailures: [String: String] = [:]
    @Environment(\.openSettings) private var openSettings

    public init(model: AppModel) {
        self.model = model
    }

    static let width: CGFloat = 460

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            header
            volumes
            Divider()
            bin
            if let retention = retentionLine {
                PanelRow(symbol: "calendar.badge.clock") {
                    Text(verbatim: retention).font(Typography.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            // Les trois commandes sur une ligne : le panneau est assez large
            // (Romain, 18/10/2026).
            HStack(spacing: Spacing.small) {
                Button { open(nil) } label: {
                    Label { Text("menubar.open", bundle: .oust) } icon: { Image(systemName: "macwindow") }
                }
                .buttonStyle(.borderedProminent)
                Spacer(minLength: Spacing.small)
                Button { SettingsWindow.show(model: model) } label: {
                    Label { Text("menu.settings", bundle: .oust) } icon: { Image(systemName: "gearshape") }
                }
                Button { confirmQuit() } label: {
                    Label { Text("menubar.quit", bundle: .oust) } icon: { Image(systemName: "power") }
                }
            }
            .controlSize(.regular)
        }
        .padding(Spacing.large)
        .frame(width: Self.width)
        // À chaque ouverture : la veille ne relit que le disque de démarrage
        // (un disque réseau endormi pourrait faire attendre), les autres
        // disques sont relus ici, quand on les regarde.
        .onAppear {
            // Lancé à la connexion, sans fenêtre : le panneau est la première
            // vue à connaître l'ouverture des Réglages.
            if SettingsWindow.opener == nil { SettingsWindow.opener = openSettings }
            model.refreshVolumes()
            Task { await model.watch.refreshDisk() }
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack {
            Text(verbatim: "Oust!").font(Typography.headline)
            Spacer()
            if model.watch.isLow, let threshold = model.watch.thresholdBytes {
                Label { Text(verbatim: L10n.string("menubar.low", Formatters.compactBytes(threshold))) }
                    icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.color(for: .review))
            }
        }
    }

    // MARK: Disques

    private var volumes: some View {
        VStack(alignment: .leading, spacing: Spacing.small + 2) {
            // « Tout éjecter » en tête de la liste, pas dessous (Romain, 18/10/2026).
            let ejectable = model.volumes.filter(DiskEjector.canEject)
            PanelRow(symbol: nil) {
                Text("menubar.disks", bundle: .oust)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } trailing: {
                if !ejectable.isEmpty {
                    Button { eject(ejectable) } label: {
                        Label { Text("menubar.eject_all", bundle: .oust) } icon: { Image(systemName: "eject.fill") }
                    }
                    .controlSize(.small)
                    .disabled(!ejecting.isEmpty)
                }
            }
            ForEach(model.volumes) { volume in
                VolumeLine(volume: volume, isLow: isLow(volume),
                           eject: DiskEjector.canEject(volume) ? { eject([volume]) } : nil,
                           isEjecting: ejecting.contains(volume.id))
                if let failure = ejectFailures[volume.id] {
                    Text(verbatim: failure)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.color(for: .review))
                        .lineLimit(2)
                        .padding(.leading, PanelMetrics.labelInset)
                }
            }
        }
    }

    /// Un disque après l'autre ; ce que macOS refuse reste monté, avec sa raison.
    private func eject(_ targets: [VolumeDescriptor]) {
        for volume in targets {
            ejecting.insert(volume.id)
            ejectFailures[volume.id] = nil
        }
        Task {
            for volume in targets {
                if let failure = await DiskEjector.eject(volume) {
                    ejectFailures[volume.id] = L10n.string("menubar.eject_failed", volume.name, failure)
                }
                ejecting.remove(volume.id)
            }
            model.refreshVolumes()
        }
    }

    private func isLow(_ volume: VolumeDescriptor) -> Bool {
        model.watch.settings.alertsLowDisk
            && LowDiskAlarm.isLow(available: volume.capacity.available, total: volume.capacity.total,
                                  threshold: model.watch.settings.threshold)
    }

    // MARK: Corbeille

    /// La corbeille d'Oust! sur une ligne. « Faire le vide… » ouvre la corbeille
    /// dans la fenêtre : on y revoit ce qui part et on confirme ; rien ne se vide
    /// d'ici (SPEC §6.3).
    private var bin: some View {
        PanelRow(symbol: AppSection.cart.symbol,
                 tint: model.cart.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.eclatSolid)) {
            HStack(spacing: Spacing.small) {
                Text("menubar.bin", bundle: .oust).font(Typography.body.weight(.semibold))
                Text(verbatim: binContent)
                    .font(Typography.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } trailing: {
            Button { open(.cart) } label: {
                Text("menubar.bin_review", bundle: .oust)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(model.cart.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.onEclat))
                    .padding(.horizontal, Spacing.medium)
                    .padding(.vertical, Spacing.tight)
                    .background(model.cart.isEmpty ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(Palette.eclat),
                                in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.cart.isEmpty)
        }
    }

    private var binContent: String {
        let count = model.cart.count
        switch count {
        case 0: return L10n.string("menubar.bin_empty")
        case 1: return L10n.string("watch.items_one", Formatters.compactBytes(model.cartTotal))
        default: return L10n.string("watch.items_other", Formatters.count(count), Formatters.compactBytes(model.cartTotal))
        }
    }

    // MARK: Règles planifiées

    private var retentionLine: String? {
        let watch = model.watch
        if let running = watch.runningFamily {
            return L10n.string("menubar.retention_running", L10n.string(running.localizationKey))
        }
        let next = RetentionFamily.allCases.compactMap { family in watch.nextRun(family).map { (family, $0) } }
            .min { $0.1 < $1.1 }
        guard let next else { return nil }
        return L10n.string("menubar.retention_next", L10n.string(next.0.localizationKey), Formatters.relative(next.1))
    }

    /// Quitter arrête la veille : on le dit avant (Romain, 18/10/2026). Depuis le
    /// panneau seulement : ⌘Q dans l'app reste direct, et Réglages Système doit
    /// pouvoir quitter Oust! sans question pour appliquer un accès.
    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = L10n.string("menubar.quit_title")
        var detail = L10n.string("menubar.quit_detail")
        if model.cleaning == .running { detail += " " + L10n.string("menubar.quit_cleaning") }
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.string("menubar.quit_confirm"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    private func open(_ section: AppSection?) {
        if let section {
            model.searchText = ""
            model.section = section
        }
        MainWindow.show()
    }
}

/// Les colonnes communes à toutes les lignes du panneau : chaque libellé
/// commence au même x, chaque barre a la même largeur, les chiffres et les
/// boutons s'alignent à droite (Romain, 18/10/2026 : « il y a des décalages »).
enum PanelMetrics {
    static let icon: CGFloat = 18
    static let gap: CGFloat = 10
    static let bar: CGFloat = 120
    /// Le nombre, aligné à droite, avec de quoi grandir (« 1 234 »).
    static let number: CGFloat = 46
    /// L'unité (« Go », « Mo », « To »), alignée à gauche juste après.
    static let unit: CGFloat = 22
    static let eject: CGFloat = 18
    static var labelInset: CGFloat { icon + gap }
}

/// Une ligne : la colonne d'icône (vide au besoin), le libellé qui prend la
/// place, puis ce qui va à droite.
struct PanelRow<Title: View, Trailing: View>: View {
    let symbol: String?
    var tint: AnyShapeStyle = AnyShapeStyle(.secondary)
    @ViewBuilder let title: Title
    @ViewBuilder let trailing: Trailing

    init(symbol: String?, tint: AnyShapeStyle = AnyShapeStyle(.secondary), @ViewBuilder title: () -> Title,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.symbol = symbol
        self.tint = tint
        self.title = title()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: PanelMetrics.gap) {
            Group {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) } else { Color.clear }
            }
            .frame(width: PanelMetrics.icon)
            title.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

/// Un disque sur une ligne : son nom, la barre, l'espace libre en clair, et la
/// colonne d'éjection, réservée même vide (disque de démarrage) pour que barres
/// et chiffres restent alignés.
private struct VolumeLine: View {
    let volume: VolumeDescriptor
    let isLow: Bool
    let eject: (() -> Void)?
    let isEjecting: Bool

    var body: some View {
        PanelRow(symbol: volume.symbol) {
            Text(verbatim: volume.name)
                .font(Typography.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        } trailing: {
            DiskBar(used: volume.capacity.usedFraction, isLow: isLow)
                .frame(width: PanelMetrics.bar)
            // Le nombre seul change de largeur : l'unité et « libres » restent
            // dans leurs colonnes, d'un disque à l'autre.
            let free = FreeSpace(volume.capacity.available)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: free.number)
                    .frame(width: PanelMetrics.number, alignment: .trailing)
                Text(verbatim: free.unit)
                    .frame(width: PanelMetrics.unit, alignment: .leading)
                Text("watch.capsule.word", bundle: .oust)
            }
            .font(Typography.body.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isLow ? AnyShapeStyle(Palette.color(for: .review)) : AnyShapeStyle(.primary))
            ZStack {
                if isEjecting {
                    ProgressView().controlSize(.mini)
                } else if let eject {
                    Button(action: eject) { Image(systemName: "eject.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L10n.string("menubar.eject", volume.name))
                        .accessibilityLabel(Text(verbatim: L10n.string("menubar.eject", volume.name)))
                } else {
                    // Grisé plutôt qu'absent : la colonne reste lisible, et la
                    // bulle dit pourquoi.
                    Image(systemName: "eject.fill")
                        .foregroundStyle(.tertiary)
                        .help(L10n.string(volume.isBoot ? "menubar.eject_boot" : "menubar.eject_internal"))
                        .accessibilityLabel(Text(verbatim: L10n.string(volume.isBoot ? "menubar.eject_boot"
                                                                       : "menubar.eject_internal")))
                }
            }
            .frame(width: PanelMetrics.eject)
        }
        .help(L10n.string("menubar.volume_free", Formatters.compactBytes(volume.capacity.available),
                          Formatters.compactBytes(volume.capacity.total)))
        .accessibilityElement(children: .contain)
    }
}

/// « 208 Go » coupé en nombre et unité, pour les aligner chacun dans sa colonne.
struct FreeSpace {
    let number: String
    let unit: String

    init(_ bytes: Int64) {
        let text = Formatters.compactBytes(bytes)
        // Entre le nombre et l'unité, Foundation met une espace, parfois insécable.
        if let split = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" }) {
            number = String(text[..<split])
            unit = String(text[text.index(after: split)...])
        } else {
            number = text
            unit = ""
        }
    }
}

/// La barre d'un disque, comme le contour de la pastille : l'occupé aux
/// couleurs de l'anneau, le libre en piste ; en orangé sous le seuil d'alerte.
private struct DiskBar: View {
    let used: Double
    let isLow: Bool

    private static let ring = LinearGradient(
        colors: [Color(hex: 0xFF3D8B), Color(hex: 0xB23BFF), Color(hex: 0x4F5BFF), Color(hex: 0x1FD1FF)],
        startPoint: .leading, endPoint: .trailing
    )

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(isLow ? AnyShapeStyle(Palette.vivid(for: .review)) : AnyShapeStyle(Self.ring))
                    .frame(width: max(4, proxy.size.width * min(1, max(0, used))))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
