import SwiftUI
import OustClean
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustVolume

/// Formater un disque externe et choisir ses partitions (Romain, 18/10/2026) :
/// en créer, en retirer, les nommer, choisir leur format. La seule suppression
/// d'Oust! sans corbeille : on montre ce qui sera perdu, on fait taper le nom du
/// disque, on redemande « vraiment ? », et rien ne part si une application garde
/// un fichier ouvert sur l'un de ses volumes (DiskEraser revalide).
///
/// Refaite au dessin d'Oust! : la première version, en contrôles système sur
/// fond gris, coupait son texte à gauche, débordait à droite et laissait de
/// grands vides (« ultra mal faite et moche », Romain, 18/10/2026).
struct FormatSheet: View {
    let model: AppModel
    let target: FormatTarget
    let onClose: () -> Void

    @State private var layout: DiskLayout?
    @State private var scheme: PartitionScheme = .gpt
    @State private var drafts: [Draft]
    @State private var typed = ""
    @State private var confirming = false
    @State private var running = false
    @State private var refusal: EraseRefusal?
    @State private var done = false

    init(model: AppModel, target: FormatTarget, onClose: @escaping () -> Void) {
        self.model = model
        self.target = target
        self.onClose = onClose
        let name = DiskEraser.isValid(name: target.volume.name, for: .exfat) ? target.volume.name
            : L10n.string("partition.untitled")
        _drafts = State(initialValue: [Draft(name: name, format: .exfat, bytes: nil)])
    }

    /// Une partition telle qu'on la règle ; `bytes` nil pour la dernière, qui
    /// prend le reste.
    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var format: EraseFormat
        var bytes: Int64?

        var isNameValid: Bool { DiskEraser.isValid(name: format.normalizedName(name), for: format) }
    }

    private var diskSize: Int64 { layout?.size ?? 0 }
    private var minimum: Int64 { DiskEraser.minimumPartitionSize(forDisk: diskSize) }
    /// Les tailles se tapent en Go comme le Finder les compte (10⁹ octets), en
    /// Mo sur une petite clé.
    private var unit: Int64 { diskSize < 8_000_000_000 ? 1_000_000 : 1_000_000_000 }
    private var specs: [PartitionSpec] {
        drafts.enumerated().map { index, draft in
            PartitionSpec(id: draft.id, name: draft.name, format: draft.format,
                          size: index == drafts.count - 1 ? nil : draft.bytes)
        }
    }
    private var planRefusal: EraseRefusal? {
        DiskEraser.refusal(for: target.details, scheme: scheme, partitions: specs, diskSize: diskSize,
                           startupWholeDisk: nil)
    }
    private var fixedBytes: Int64 { specs.dropLast().compactMap(\.size).reduce(0, +) }
    private var remainder: Int64 { max(0, diskSize - fixedBytes) }
    private var confirmed: Bool { typed == target.volume.name }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            header
            if done {
                doneCard
            } else if let layout {
                todayCard(layout)
                planCard
                confirmCard
                footer
            } else {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .frame(height: 160)
            }
        }
        .padding(Spacing.xLarge)
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .background { SectionBackground(.browsers) }
        .onSectionBackground()
        .foregroundStyle(Palette.onGradient)
        .interactiveDismissDisabled(running)
        .task { layout = await model.diskLayout(target.details) }
        .onChange(of: scheme) { _, scheme in
            for index in drafts.indices where !scheme.formats.contains(drafts[index].format) {
                drafts[index].format = .exfat
            }
        }
        .confirmationDialog(Text(verbatim: L10n.string("partition.confirm_title", target.volume.name)),
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(role: .destructive) { format() } label: { Text("partition.confirm_action", bundle: .oust) }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .oust) }
        } message: {
            Text("partition.confirm_message", bundle: .oust)
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.medium) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Palette.linearGradient(for: .browsers),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25)))
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(verbatim: L10n.string("erase.title", target.volume.name))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(verbatim: L10n.string("erase.whole_disk", target.details.mediaName ?? target.details.wholeDisk,
                                           Formatters.compactBytes(layout?.size ?? target.volume.capacity.total)))
                    .font(Typography.body)
                    .foregroundStyle(Palette.onGradientSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Aujourd'hui

    /// Ce qui est sur le disque aujourd'hui, et qui sera effacé.
    private func todayCard(_ layout: DiskLayout) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                CardTitle("partition.today")
                if layout.partitions.isEmpty {
                    Text("partition.current_empty", bundle: .oust).font(Typography.caption)
                        .foregroundStyle(Palette.onGradientSecondary)
                } else {
                    PlanBar(segments: layout.partitions.map { partition in
                        PlanBar.Segment(id: partition.identifier, name: partition.name ?? partition.content,
                                        bytes: partition.size, color: .white)
                    }, muted: true)
                    .frame(height: 24)
                    VStack(spacing: Spacing.tight) {
                        ForEach(layout.partitions) { partition in
                            HStack(spacing: Spacing.small) {
                                Image(systemName: "internaldrive").foregroundStyle(Palette.onGradientSecondary)
                                Text(verbatim: partition.name ?? partition.identifier).fontWeight(.semibold).lineLimit(1)
                                Text(verbatim: partition.content).foregroundStyle(Palette.onGradientSecondary).lineLimit(1)
                                Spacer()
                                Text(verbatim: Formatters.compactBytes(partition.size)).monospacedDigit()
                            }
                            .font(Typography.body)
                        }
                    }
                }
                Label {
                    Text(verbatim: L10n.string("erase.warning", Formatters.compactBytes(target.volume.capacity.used)))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.eclatSolid)
            }
        }
    }

    // MARK: Les nouvelles partitions

    private var planCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                HStack(alignment: .firstTextBaseline) {
                    CardTitle("partition.new")
                    Spacer()
                    Picker(selection: $scheme) {
                        ForEach(PartitionScheme.allCases) { scheme in
                            Text(LocalizedStringKey(scheme.shortKey), bundle: .oust).tag(scheme)
                        }
                    } label: { Text("partition.scheme", bundle: .oust) }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(running)
                }
                Text(LocalizedStringKey(scheme.localizationKey), bundle: .oust)
                    .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)

                PlanBar(segments: drafts.indices.map { index in
                    PlanBar.Segment(id: drafts[index].id.uuidString,
                                    name: drafts[index].format.normalizedName(drafts[index].name),
                                    bytes: index == drafts.count - 1 ? remainder : drafts[index].bytes ?? 0,
                                    color: Self.color(index))
                })
                .frame(height: 24)

                Grid(alignment: .leading, horizontalSpacing: Spacing.small, verticalSpacing: Spacing.small) {
                    ForEach($drafts) { $draft in
                        row($draft, index: drafts.firstIndex { $0.id == draft.id } ?? 0)
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Button { add() } label: {
                        Label { Text("partition.add", bundle: .oust) } icon: { Image(systemName: "plus") }
                    }
                    .buttonStyle(OnGradientButtonStyle())
                    .disabled(!canAdd || running)
                    Spacer()
                    if let message = planMessage {
                        Text(verbatim: message).font(Typography.caption.weight(.semibold))
                            .foregroundStyle(Palette.eclatSolid)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Text("erase.linux_note", bundle: .oust)
                    .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Une partition : sa couleur, son nom, son format, sa taille, la retirer.
    @ViewBuilder
    private func row(_ draft: Binding<Draft>, index: Int) -> some View {
        let isLast = index == drafts.count - 1
        GridRow(alignment: .center) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Self.color(index)).frame(width: 12, height: 12)
            TextField(text: draft.name) { Text("erase.name", bundle: .oust) }
                .textFieldStyle(.plain)
                .fieldBackground()
                .frame(minWidth: 180)
            Picker(selection: draft.format) {
                ForEach(scheme.formats) { format in
                    Text(LocalizedStringKey(format.shortKey), bundle: .oust).tag(format)
                }
            } label: { EmptyView() }
                .labelsHidden()
                .frame(width: 150)
                .help(Text(LocalizedStringKey(draft.wrappedValue.format.localizationKey), bundle: .oust))
            Group {
                if isLast {
                    Text(verbatim: L10n.string("partition.remainder", Formatters.compactBytes(remainder)))
                        .font(Typography.body.monospacedDigit())
                        .foregroundStyle(Palette.onGradientSecondary)
                } else {
                    HStack(spacing: Spacing.tight) {
                        TextField(value: amount(draft), format: .number.precision(.fractionLength(0...1))) { EmptyView() }
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .fieldBackground()
                            .frame(width: 76)
                        Text(unit == 1_000_000 ? "partition.size_unit_mb" : "partition.size_unit", bundle: .oust)
                            .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
                    }
                }
            }
            .frame(width: 128, alignment: .leading)
            Button { remove(at: index) } label: {
                Image(systemName: "minus").font(.system(size: 11, weight: .bold)).frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(drafts.count == 1 || running)
            .help(Text("partition.remove", bundle: .oust))
        }
        .disabled(running)
        if !draft.wrappedValue.isNameValid {
            GridRow {
                Color.clear.frame(width: 12, height: 1)
                Text(verbatim: L10n.string("erase.name_hint", Formatters.count(draft.wrappedValue.format.maximumNameLength)))
                    .font(Typography.caption).foregroundStyle(Palette.eclatSolid)
                    .fixedSize(horizontal: false, vertical: true)
                    .gridCellColumns(4)
            }
        }
    }

    /// La taille d'une partition dans l'unité affichée.
    private func amount(_ draft: Binding<Draft>) -> Binding<Double> {
        Binding(get: { Double(draft.wrappedValue.bytes ?? minimum) / Double(unit) },
                set: { draft.wrappedValue.bytes = Int64((max(0, $0) * Double(unit)).rounded()) })
    }

    // MARK: Confirmer

    private var confirmCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(verbatim: L10n.string("erase.confirm_prompt", target.volume.name))
                    .font(Typography.body.weight(.semibold))
                TextField(text: $typed) { Text(verbatim: target.volume.name) }
                    .textFieldStyle(.plain)
                    .fieldBackground()
                    .disabled(running)
                if let refusal {
                    Label { Text(verbatim: Self.message(for: refusal)).fixedSize(horizontal: false, vertical: true) }
                        icon: { Image(systemName: "xmark.octagon.fill") }
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.eclatSolid)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.medium) {
            if running {
                ProgressView().controlSize(.small)
                Text("erase.running", bundle: .oust).font(Typography.body)
            }
            Spacer()
            Button(role: .cancel) { onClose() } label: { Text("common.cancel", bundle: .oust) }
                .buttonStyle(OnGradientButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(running)
            Button(role: .destructive) { confirming = true } label: { Text("disks.format", bundle: .oust) }
                .buttonStyle(PrimaryButtonStyle(section: .browsers))
                .disabled(!confirmed || planRefusal != nil || running)
                .opacity(!confirmed || planRefusal != nil || running ? 0.5 : 1)
        }
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            GlassCard {
                Label {
                    Text(verbatim: L10n.string("partition.done", drafts.map { "« \($0.format.normalizedName($0.name)) »" }
                        .formatted(.list(type: .and))))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.vivid(for: .safe))
                }
                .font(Typography.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button { onClose() } label: { Text("report.done", bundle: .oust) }
                    .buttonStyle(PrimaryButtonStyle(section: .browsers))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Ajouter, retirer

    /// Ajouter coupe en deux ce que prenait la dernière partition.
    private var canAdd: Bool {
        drafts.count < scheme.maximumPartitions && remainder / 2 >= minimum
    }

    private func add() {
        guard canAdd, let last = drafts.indices.last else { return }
        let half = max(minimum, remainder / 2 / unit * unit)
        drafts[last].bytes = half
        let name = L10n.string("partition.default_name", Formatters.count(drafts.count + 1))
        let format = drafts[last].format
        drafts.append(Draft(name: String(name.prefix(format.maximumNameLength)), format: format, bytes: nil))
    }

    private func remove(at index: Int) {
        guard drafts.count > 1, drafts.indices.contains(index) else { return }
        drafts.remove(at: index)
        if let last = drafts.indices.last { drafts[last].bytes = nil }
    }

    /// Pourquoi le plan ne tient pas, dit simplement.
    private var planMessage: String? {
        guard let planRefusal else { return nil }
        switch planRefusal {
        case .invalidName: return nil // chaque ligne le dit déjà sous son nom
        case .invalidPlan:
            if drafts.count > scheme.maximumPartitions {
                return L10n.string("partition.limit", Formatters.count(scheme.maximumPartitions))
            }
            if specs.dropLast().contains(where: { ($0.size ?? 0) < minimum }) {
                return L10n.string("partition.too_small_size", Formatters.compactBytes(minimum))
            }
            return L10n.string("partition.overflow", Formatters.compactBytes(fixedBytes + minimum - diskSize))
        default: return Self.message(for: planRefusal)
        }
    }

    private func format() {
        running = true
        refusal = nil
        Task {
            let result = await model.partitionDisk(target.details, scheme: scheme, partitions: specs, diskSize: diskSize)
            running = false
            if let result { refusal = result } else { done = true }
        }
    }

    static func message(for refusal: EraseRefusal) -> String {
        switch refusal {
        case .inUse(let names): L10n.string(refusal.localizationKey, names.formatted(.list(type: .and)))
        case .failed(let message): L10n.string(refusal.localizationKey, message)
        default: L10n.string(refusal.localizationKey)
        }
    }

    /// Une couleur par partition, prise aux dégradés des sections.
    static func color(_ index: Int) -> Color {
        let sections: [AppSection] = [.explorer, .duplicates, .overview, .developer, .history, .system]
        return Palette.colors(for: sections[index % sections.count]).glow
    }
}

extension EraseFormat {
    /// Le nom court, pour le menu d'une ligne ; la bulle d'aide donne le détail.
    var shortKey: String { "erase.format_short.\(rawValue)" }
}

extension PartitionScheme {
    /// « GUID », « MBR » : le sélecteur reste court, l'explication est dessous.
    var shortKey: String { "partition.scheme_short.\(rawValue)" }
}

/// Le titre d'une carte.
private struct CardTitle: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }

    var body: some View {
        Text(key, bundle: .oust)
            .font(Typography.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Palette.onGradientSecondary)
    }
}

private extension View {
    /// Un champ sur le verre : un fond léger, arrondi, au lieu du cadre système.
    func fieldBackground() -> some View {
        padding(.horizontal, Spacing.small)
            .padding(.vertical, 6)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.18)))
    }
}

/// Les partitions côte à côte, à l'échelle du disque, avec leur nom quand il tient.
private struct PlanBar: View {
    struct Segment: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let color: Color
    }

    let segments: [Segment]
    var muted = false

    var body: some View {
        GeometryReader { proxy in
            let total = Double(max(1, segments.reduce(0) { $0 + $1.bytes }))
            let gaps = CGFloat(max(0, segments.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    let width = max(6, (proxy.size.width - gaps) * Double(segment.bytes) / total)
                    ZStack {
                        Rectangle().fill(segment.color.opacity(muted ? 0.22 : 0.9))
                        if width > 60 {
                            Text(verbatim: segment.name)
                                .font(Typography.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, Spacing.tight)
                        }
                    }
                    .frame(width: width)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: segments.map { "\($0.name) \(Formatters.compactBytes($0.bytes))" }
            .joined(separator: ", ")))
    }
}
