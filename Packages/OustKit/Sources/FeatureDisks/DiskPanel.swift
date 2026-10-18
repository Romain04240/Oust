import AppKit
import SwiftUI
import OustClean
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustScan
import OustVolume

/// Le panneau d'un disque (Romain, 18/10/2026) : son nom, qu'on peut changer,
/// son format et, à droite du nom, éjecter, formater, les informations et
/// Utilitaire de disque ; puis la jauge de l'utilisé et du disponible, et la
/// répartition de l'espace d'après la dernière analyse, gardée d'une fois sur
/// l'autre.
struct DiskPanel: View {
    let model: AppModel
    let volume: VolumeDescriptor
    let onFormat: (FormatTarget) -> Void
    /// « Garder les N dernières… » sur un disque Time Machine.
    var onPruneBackups: (BackupsTarget) -> Void = { _ in }

    @State private var details: DiskDetails?
    @State private var name = ""
    @State private var message: String?
    @State private var working = false
    @State private var showsDetails = false
    /// Les sauvegardes, si c'est un disque Time Machine ; nil tant qu'on lit.
    @State private var backups: TimeMachineListing?

    // Sans ScrollView : dans un popover, elle n'a pas de hauteur à elle et le
    // panneau défilait dans quelques lignes (Romain, 18/10/2026).
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            header
            capacity
            BreakdownView(model: model, volume: volume)
            if let message {
                Text(verbatim: message).font(Typography.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsDetails, let details { InfoGrid(details: details) }
            if let backups, backups != .notADestination {
                TimeMachineSection(volume: volume, listing: backups, onPrune: onPruneBackups)
            }
            if volume.isBoot {
                let clouds = model.cloudFootprints
                if !clouds.isEmpty {
                    Divider()
                    Text("disks.clouds", bundle: .oust).font(Typography.headline)
                    ForEach(clouds) { CloudRow(model: model, footprint: $0) }
                }
            }
        }
        .padding(Spacing.xLarge)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: volume.id) {
            name = volume.name
            async let stored: ScanIndex? = model.storedAnalysis(for: volume)
            async let listing = model.timeMachineListing(for: volume)
            details = await model.diskDetails(volume)
            backups = await listing
            _ = await stored
        }
    }

    // MARK: En-tête : le nom, modifiable, le format et les actions

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.medium) {
            Image(systemName: volume.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Palette.linearGradient(for: volume.isBoot ? .overview : .explorer),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.hair) {
                nameField
                Text(verbatim: formatLine).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.small)
            actions
        }
    }

    /// Un vrai champ, qui se voit comme tel : le crayon seul, tout fin au bout
    /// de la ligne, ne disait pas ce qu'il faisait (Romain, 18/10/2026). Ce qui
    /// ne se renomme pas (le disque de démarrage, un volume en lecture seule)
    /// reste un simple titre.
    @ViewBuilder private var nameField: some View {
        if details?.isWritable == true && !volume.isBoot {
            TextField(text: $name) { Text(verbatim: volume.name) }
                .textFieldStyle(.plain)
                .font(Typography.headline)
                .padding(.horizontal, Spacing.tight)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .frame(maxWidth: 190, alignment: .leading)
                .disabled(working)
                .onSubmit { rename() }
                .help(Text("disks.rename_help", bundle: .oust))
        } else {
            Text(verbatim: volume.name).font(Typography.headline).lineLimit(1)
        }
    }

    private var formatLine: String {
        guard let details else { return "…" }
        var parts = [details.format]
        if let bus = details.busProtocol { parts.append(bus) }
        if details.isEncrypted { parts.append(L10n.string("disks.encrypted")) }
        parts.append(Formatters.compactBytes(volume.capacity.total))
        return parts.joined(separator: " · ")
    }

    private func rename() {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard let details, wanted != volume.name, !wanted.isEmpty else { name = volume.name; return }
        guard DiskInfo.isValidVolumeName(wanted, format: details.format) else {
            message = L10n.string("disks.rename_invalid")
            return
        }
        working = true
        message = nil
        Task {
            if let failure = await model.renameVolume(details, to: wanted) {
                message = L10n.string("disks.rename_failed", failure)
                name = volume.name
            }
            working = false
        }
    }

    /// Éjecter, formater, les informations, Utilitaire de disque : en haut, à
    /// droite du nom, en boutons ronds avec leur bulle d'aide.
    private var actions: some View {
        HStack(spacing: Spacing.tight) {
            // Un disque USB se dit souvent « éjectable » à diskutil sans l'être
            // pour les attributs du volume : l'un ou l'autre suffit.
            if !volume.isBoot && (volume.isRemovable || details?.isEjectable == true || details?.isExternal == true) {
                RoundAction(symbol: "eject.fill", help: "disks.eject") { eject() }
                    .disabled(working)
            }
            if let details, details.isExternal, !volume.isBoot {
                RoundAction(symbol: "eraser.line.dashed.fill", help: "disks.format") {
                    onFormat(FormatTarget(volume: volume, details: details))
                }
                .disabled(working)
            }
            RoundAction(symbol: showsDetails ? "info.circle.fill" : "info.circle", help: "disks.info") {
                showsDetails.toggle()
            }
            RoundAction(symbol: "wrench.and.screwdriver", help: "disks.disk_utility") {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"),
                    configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    // MARK: L'utilisé et le disponible, sur une ligne, puis la jauge

    private var capacity: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack {
                Text(verbatim: L10n.string("disks.used", Formatters.compactBytes(volume.capacity.used)))
                Spacer()
                Text(verbatim: L10n.string("disks.available", Formatters.compactBytes(volume.capacity.available)))
                    .foregroundStyle(DiskToolbar.isLow(volume.capacity) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
            }
            .font(Typography.caption.monospacedDigit().weight(.semibold))
            MiniGauge(capacity: volume.capacity, selected: volume.isBoot ? model.cartTotal : 0)
                .frame(height: 8)
        }
    }

    private func eject() {
        working = true
        message = nil
        Task {
            switch await model.eject(volume) {
            case .ejected: message = nil
            case .inUse(let names): message = L10n.string("disks.in_use", names.formatted(.list(type: .and)))
            case .failed(let reason): message = L10n.string("disks.eject_failed", reason)
            }
            working = false
        }
    }
}

/// Un bouton rond, une icône et sa bulle d'aide.
private struct RoundAction: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(Text(help, bundle: .oust))
        .accessibilityLabel(Text(help, bundle: .oust))
    }
}

// MARK: - Répartition de l'espace

/// Comment l'espace est occupé, par nature de fichier, d'après la dernière
/// analyse : pour le disque de démarrage, l'analyse partagée ; pour un autre
/// disque, celle qu'on a gardée (Romain : « si à chaque fois tu dois
/// réanalyser, c'est pas agréable »). La date dit de quand elle date, et
/// « Réanalyser » la met à jour sans quitter le panneau.
private struct BreakdownView: View {
    let model: AppModel
    let volume: VolumeDescriptor
    @State private var computed: (root: ObjectIdentifier, value: DiskBreakdown)?

    var body: some View {
        let root = model.analyzedTree(for: volume)
        let analyzing = model.isAnalyzing(volume)
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text("disks.breakdown", bundle: .oust).font(Typography.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if root != nil {
                    Button {
                        model.searchText = ""
                        model.explore(volume)
                        model.section = .explorer
                    } label: { Text("overview.explore_volume", bundle: .oust) }
                        .buttonStyle(.borderless).font(Typography.caption)
                }
            }
            if let root, let computed, computed.root == ObjectIdentifier(root) {
                segments(computed.value)
            } else if root != nil {
                ProgressView().controlSize(.small)
            } else if !analyzing {
                Text("disks.breakdown_unknown", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
            }
            footer(analyzing: analyzing, hasTree: root != nil)
        }
        .task(id: root.map(ObjectIdentifier.init)) {
            guard let root else { return }
            let value = await BreakdownCache.shared.breakdown(of: root, used: volume.capacity.used)
            computed = (ObjectIdentifier(root), value)
        }
    }

    /// De quand date l'analyse, et de quoi la refaire.
    @ViewBuilder private func footer(analyzing: Bool, hasTree: Bool) -> some View {
        HStack(spacing: Spacing.small) {
            if analyzing {
                ProgressView().controlSize(.mini)
                if !volume.isBoot {
                    // Le compteur du parcours n'est pas observé : on le relit deux fois par seconde.
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(verbatim: L10n.string("disks.analyzing", Formatters.compactBytes(model.scanProgress.allocatedBytes)))
                            .monospacedDigit()
                    }
                } else {
                    Text("disks.analyzing_boot", bundle: .oust)
                }
            } else if let date = model.analysisDate(for: volume) {
                Text(verbatim: L10n.string("disks.analyzed_at", Formatters.timestamp(date)))
            }
            Spacer()
            if !analyzing {
                Button { model.reanalyze(volume) } label: {
                    Label { Text(hasTree ? "disks.reanalyze" : "disks.analyze", bundle: .oust) }
                        icon: { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
            }
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
    }

    private func segments(_ breakdown: DiskBreakdown) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(breakdown.parts) { part in
                        Rectangle().fill(part.color)
                            .frame(width: max(2, proxy.size.width * part.fraction(of: breakdown.total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: Spacing.tight) {
                ForEach(breakdown.parts) { part in
                    HStack(spacing: Spacing.tight) {
                        Circle().fill(part.color).frame(width: 7, height: 7)
                        Text(verbatim: part.label).lineLimit(1)
                        Spacer(minLength: Spacing.tight)
                        Text(verbatim: Formatters.compactBytes(part.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(Typography.caption)
                }
            }
        }
    }
}

/// Une part de l'espace occupé.
struct DiskBreakdownPart: Identifiable, Sendable {
    let id: String
    let label: String
    let bytes: Int64
    let color: Color

    func fraction(of total: Int64) -> Double { Double(bytes) / Double(max(1, total)) }
}

struct DiskBreakdown: Sendable {
    let parts: [DiskBreakdownPart]
    var total: Int64 { parts.reduce(0) { $0 + $1.bytes } }
}

/// Le calcul parcourt tout l'arbre (une à deux secondes sur cinq millions de
/// fichiers) : il est gardé pour la racine qui l'a donné.
actor BreakdownCache {
    static let shared = BreakdownCache()
    private var last: (root: ObjectIdentifier, used: Int64, value: DiskBreakdown)?

    func breakdown(of root: TreeNode, used: Int64) async -> DiskBreakdown {
        let key = ObjectIdentifier(root)
        if let last, last.root == key, abs(last.used - used) < 1_000_000_000 { return last.value }
        let value = await Task.detached(priority: .userInitiated) { Self.compute(root, used: used) }.value
        last = (key, used, value)
        return value
    }

    static func compute(_ root: TreeNode, used: Int64) -> DiskBreakdown {
        let analytics = TreeAnalytics.compute(root, largestLimit: 0)
        var parts = analytics.kinds.filter { $0.tally.bytes > 0 }.map { entry in
            DiskBreakdownPart(id: entry.kind.rawValue, label: L10n.string(entry.kind.localizationKey),
                              bytes: entry.tally.bytes, color: tint(entry.kind))
        }
        if analytics.smallFiles.bytes > 0 {
            parts.append(DiskBreakdownPart(id: "small", label: L10n.string("explorer.small_files_kind"),
                                           bytes: analytics.smallFiles.bytes, color: Color(hex: 0x8C86A8)))
        }
        parts.sort { $0.bytes > $1.bytes }
        // Ce que le parcours ne voit pas : le système scellé, les snapshots, ce
        // que macOS garde privé. Montré tel quel plutôt que réparti au hasard.
        let scanned = root.total.allocated
        if used - scanned > max(1_000_000_000, used / 100) {
            parts.append(DiskBreakdownPart(id: "unseen", label: L10n.string("disks.breakdown_unseen"),
                                           bytes: used - scanned, color: Color(hex: 0x4A4560)))
        }
        return DiskBreakdown(parts: parts)
    }

    /// Les teintes de l'onglet « Types de fichiers » de l'Explorateur.
    static func tint(_ kind: FileKind) -> Color {
        switch kind {
        case .video: Palette.colors(for: .overview).glow
        case .image: Palette.colors(for: .browsers).glow
        case .audio: Palette.colors(for: .history).glow
        case .archive, .diskImage: Palette.colors(for: .system).glow
        case .application: Palette.colors(for: .developer).glow
        case .model: Palette.color(for: .aiModels)
        case .code: Palette.colors(for: .duplicates).glow
        case .document: Palette.colors(for: .explorer).glow
        case .data: Palette.vivid(for: .rebuilds)
        case .other: Color(hex: 0xD9D4EC)
        }
    }
}

// MARK: - Détails et nuages

/// Ce que macOS dit du disque, en lecture seule.
private struct InfoGrid: View {
    let details: DiskDetails

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.medium, verticalSpacing: Spacing.hair) {
            row("disks.info.format", details.format)
            if let bus = details.busProtocol { row("disks.info.connection", bus) }
            if let media = details.mediaName { row("disks.info.device", media) }
            row("disks.info.encrypted", L10n.string(details.isEncrypted ? "common.yes" : "common.no"))
            row("disks.info.identifier", "\(details.deviceIdentifier) · \(details.wholeDisk)")
            if !details.mountPoint.isEmpty { row("disks.info.mount", details.mountPoint) }
        }
        .font(Typography.caption)
        .padding(Spacing.small)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(key, bundle: .oust).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Un nuage : ce qu'il occupe ici, et ce qui s'évince sans rien perdre.
private struct CloudRow: View {
    let model: AppModel
    let footprint: CloudFootprint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Image(systemName: "icloud").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: footprint.provider.name).font(Typography.body.weight(.semibold))
                if let account = footprint.provider.account {
                    Text(verbatim: account).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if footprint.evictable > 0 {
                    Text(verbatim: L10n.string("disks.cloud_evictable", Formatters.compactBytes(footprint.evictable)))
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Spacing.small)
            VStack(alignment: .trailing, spacing: 0) {
                if let size = footprint.onThisMac, size > 0 {
                    Text(verbatim: L10n.string("disks.cloud_on_mac", Formatters.compactBytes(size)))
                        .font(Typography.caption.monospacedDigit())
                } else if footprint.onThisMac == 0 {
                    Text("disks.cloud_empty", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                } else {
                    Text("disks.cloud_unknown", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
                }
                if footprint.evictable > 0 {
                    Button {
                        model.searchText = ""
                        model.section = .system
                    } label: { Text("disks.cloud_see", bundle: .oust) }
                        .buttonStyle(.borderless)
                        .font(Typography.caption)
                }
            }
        }
    }
}
