import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// La vue d'ensemble : où est passé l'espace, ce qu'on peut rendre, d'un coup d'œil.
public struct OverviewView: View {
    @Bindable var model: AppModel
    @State private var review: AnalysisReview?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        // Pas de bouton « Analyser » dans l'en-tête : il doublait celui de la carte
        // principale (remarque de Romain, 18/10/2026).
        SectionScaffold(.overview, subtitle: "overview.subtitle") {
            if model.fullDiskAccess == false { AccessBanner(model: model) }
            // Le disque analysé se choisit ici, en haut : un disque externe
            // s'analyse comme le disque de démarrage (Romain, 18/10/2026), au
            // lieu d'attendre tout en bas avec un simple « Explorer ».
            VolumePicker(model: model)
            if let volume = model.analyzedVolume {
                HeroCard(model: model, volume: volume) { review = model.analysisReview(for: volume) }
                let phase = model.analysisPhase(for: volume)
                if phase.hasRun || phase.isRunning {
                    CategoryGrid(model: model, volume: volume)
                }
                // La mesure APFS des snapshots est indépendante du purgeable du volume.
                if volume.isBoot, model.snapshotEstimate > 1_000_000_000, !model.deletableSnapshots.isEmpty {
                    SnapshotCard(model: model)
                }
            }
        }
        .sheet(item: $review) { AnalysisReviewView(model: model, review: $0) }
    }
}

/// « Analyser » / « Analyse en cours… ».
public struct AnalyzeButton: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Button {
            Task { await model.analyze() }
        } label: {
            HStack(spacing: Spacing.small) {
                if model.analysis.isRunning { ProgressView().controlSize(.small).tint(.white) }
                Text(model.analysis.isRunning ? "overview.analyzing" : (model.currentAnalysis.hasRun ? "overview.reanalyze" : "overview.analyze"),
                     bundle: .oust)
            }
        }
        .buttonStyle(OnGradientButtonStyle())
        .disabled(model.analysis.isRunning)
        .keyboardShortcut("r", modifiers: .command)
    }
}

private struct HeroCard: View {
    let model: AppModel
    let volume: VolumeDescriptor
    let showReview: () -> Void

    @State private var breakdown = StorageBreakdown()
    @State private var showsStorageDetails = false

    private var parts: [StoragePart] { breakdown.parts(capacity: volume.capacity) }
    private var gaugeSegments: [DiskGauge.Segment] {
        parts.filter { $0.category != .free && $0.category != .purgeable }.map {
            DiskGauge.Segment(id: $0.category.rawValue, value: $0.bytes, color: storageColor($0.category))
        }
    }

    var body: some View {
        let phase = model.analysisPhase(for: volume)
        // Ce qui est coché sur ce disque : la barre et la jauge sont les siennes.
        let selected = model.cartTotal(on: volume)
        GlassCard(padding: Spacing.xLarge) {
            HStack(alignment: .center, spacing: Spacing.xLarge) {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    Label { Text(verbatim: volume.name) } icon: { Image(systemName: volume.symbol) }
                        .font(Typography.headline)
                        .foregroundStyle(Palette.onGradient)
                    if phase.hasRun || phase.isRunning {
                        HeroSize(selected, caption: "overview.selected_caption")
                    } else {
                        Text("overview.welcome", bundle: .oust)
                            .font(Typography.title)
                            .foregroundStyle(Palette.onGradient)
                        Group {
                            if volume.isBoot {
                                Text("overview.welcome_detail", bundle: .oust)
                            } else {
                                Text(verbatim: L10n.string("overview.volume_welcome_detail", volume.name))
                            }
                        }
                        .font(Typography.body)
                        .foregroundStyle(Palette.onGradientSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    StorageChart(parts: parts, capacity: volume.capacity, date: model.analysisDate(for: volume),
                                 showSystemDetails: { showsStorageDetails = true })
                    Button { showsStorageDetails = true } label: {
                        Label { Text("storage.details.open", bundle: .oust) } icon: { Image(systemName: "info.circle") }
                    }
                    .buttonStyle(.plain)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.onGradient)
                    Text(verbatim: L10n.string("storage.breakdown", Formatters.compactBytes(volume.capacity.available),
                                               Formatters.compactBytes(volume.capacity.purgeable)))
                        .font(Typography.caption.monospacedDigit()).foregroundStyle(Palette.onGradientSecondary)
                    Text("storage.explanation", bundle: .oust)
                        .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Spacing.medium) {
                        if !phase.hasRun && !phase.isRunning {
                            Button { Task { await model.analyze() } } label: {
                                if volume.isBoot {
                                    Text("overview.analyze_now", bundle: .oust)
                                } else {
                                    Text(verbatim: L10n.string("overview.analyze_volume", volume.name))
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle(section: .overview))
                            // Une analyse à la fois : celle d'un autre disque tourne peut-être.
                            .disabled(model.analysis.isRunning)
                        } else {
                            if model.analysisReview(for: volume) != nil {
                                Button(action: showReview) { Text("analysis_review.open", bundle: .oust) }
                                    .buttonStyle(PrimaryButtonStyle(section: .overview, eclat: true))
                            }
                            if !model.cart.isEmpty {
                                Button { model.section = .cart } label: {
                                    // Sans montant quand rien ne revient ici (fichiers du cloud
                                    // restés en ligne) : « Faire le vide · — » faisait erreur.
                                    Text(verbatim: model.cartTotal > 0
                                         ? L10n.string("overview.go_clean", Formatters.compactBytes(model.cartTotal))
                                         : L10n.string("cart.clean_plain"))
                                }
                                .buttonStyle(PrimaryButtonStyle(section: .overview, eclat: true))
                            }
                            Button { Task { await model.analyze() } } label: {
                                Text(phase.isRunning ? "overview.analyzing" : "overview.reanalyze", bundle: .oust)
                            }
                            .buttonStyle(.plain)
                            .font(Typography.body.weight(.semibold))
                            .foregroundStyle(Palette.onGradientSecondary)
                            .disabled(model.analysis.isRunning)
                        }
                        if !volume.isBoot {
                            Button {
                                model.explore(volume)
                                model.section = .explorer
                            } label: { Text("overview.explore_volume", bundle: .oust) }
                                .buttonStyle(.plain)
                                .font(Typography.body.weight(.semibold))
                                .foregroundStyle(Palette.onGradientSecondary)
                        }
                    }
                    .padding(.top, Spacing.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DiskGauge(segments: gaugeSegments, cart: 0, capacity: volume.capacity, beat: model.beat)
                    .frame(width: 174, height: 174)
            }
        }
        .task(id: StorageChartKey(volume: volume.id, tree: model.storageTreeIdentifier(for: volume))) {
            let value = await model.storageBreakdown(for: volume)
            guard !Task.isCancelled else { return }
            breakdown = value
        }
        .sheet(isPresented: $showsStorageDetails) {
            StorageDetailsView(model: model, volume: volume, breakdown: breakdown)
        }
    }
}

private struct StorageChartKey: Hashable {
    let volume: String
    let tree: ObjectIdentifier?
}

/// Une tuile par grande famille, qui mène à sa section.
private struct CategoryGrid: View {
    let model: AppModel
    let volume: VolumeDescriptor

    private static let bootTiles: [(ItemCategory, AppSection)] = [
        (.aiAgents, .developer), (.projectArtifacts, .developer), (.simulators, .developer),
        (.xcode, .developer), (.packageCaches, .developer), (.aiModels, .developer), (.toolVersions, .developer),
        (.compressibleProjects, .developer), (.downloads, .system), (.appCaches, .system), (.creative, .system),
        (.games, .system), (.cloudFiles, .system),
        (.attachments, .system), (.trash, .system), (.iosBackups, .system), (.virtualMachines, .system),
        (.browsers, .browsers), (.duplicates, .duplicates),
    ]

    /// Sur un autre disque, ce que ses propres chercheurs y trouvent. Les
    /// dernières tuiles ne paraissent que si elles ont quelque chose à montrer.
    private static let volumeTiles: [(ItemCategory, AppSection)] = [
        (.projectArtifacts, .developer), (.creative, .system), (.systemDownloads, .system), (.trash, .system),
        (.duplicates, .duplicates), (.diskTraces, .system), (.virtualMachines, .system), (.protectedOnDisk, .system),
    ]
    private static let alwaysShown: Set<ItemCategory> = [.projectArtifacts, .creative, .systemDownloads, .trash, .duplicates]

    var body: some View {
        let running = model.analysisPhase(for: volume).isRunning
        let tiles = volume.isBoot ? Self.bootTiles
            : Self.volumeTiles.filter { Self.alwaysShown.contains($0.0) || !model.items(in: [$0.0]).isEmpty }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Spacing.medium)], spacing: Spacing.medium) {
            ForEach(tiles, id: \.0) { category, section in
                let items = model.items(in: [category])
                let total = model.total(of: [category], headlineOnly: false)
                let done = !running || !items.isEmpty
                Button { model.section = section } label: {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        HStack {
                            Image(systemName: category.symbol)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(Palette.color(for: category).gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Spacer()
                            if !done { ProgressView().controlSize(.small).tint(.white) }
                        }
                        Text(LocalizedStringKey(category.localizationKey), bundle: .oust)
                            .font(Typography.headline)
                            .foregroundStyle(Palette.onGradient)
                        Text(verbatim: Formatters.compactBytes(total))
                            .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                            .foregroundStyle(Palette.onGradient)
                            .contentTransition(.numericText(value: Double(total)))
                        Text(verbatim: L10n.string("overview.items_count", Formatters.count(items.count)))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.onGradientSecondary)
                    }
                    .padding(Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                }
                .buttonStyle(.plain)
                .animation(.snappy, value: total)
            }
        }
    }
}

/// L'espace « purgeable », expliqué : la leçon du 18 octobre.
private struct SnapshotCard: View {
    let model: AppModel

    var body: some View {
        GlassCard {
            HStack(spacing: Spacing.large) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Palette.onGradient)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(verbatim: L10n.string("overview.purgeable_title", Formatters.compactBytes(model.snapshotEstimate)))
                        .font(Typography.headline)
                        .foregroundStyle(Palette.onGradient)
                    Text(verbatim: L10n.string("overview.purgeable_detail", Formatters.count(model.snapshots.filter(\.isDeletable).count)))
                        .font(Typography.body)
                        .foregroundStyle(Palette.onGradientSecondary)
                }
                Spacer()
                Button { model.section = .timeMachine } label: { Text("overview.see_snapshots", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
        }
    }
}

private struct AccessBanner: View {
    let model: AppModel

    var body: some View {
        GlassCard {
            HStack(spacing: Spacing.large) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Palette.onGradient)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("access.title", bundle: .oust).font(Typography.headline).foregroundStyle(Palette.onGradient)
                    Text("access.detail", bundle: .oust).font(Typography.body).foregroundStyle(Palette.onGradientSecondary)
                }
                Spacer()
                Button { FullDiskAccess.openSettings() } label: { Text("access.open", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
                Button { FullDiskAccess.relaunch() } label: { Text("access.relaunch", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
        }
    }
}

/// Le choix du disque analysé : le disque de démarrage et chaque disque
/// branché. Une destination Time Machine se montre sans se choisir.
private struct VolumePicker: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if model.volumes.count > 1 {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("overview.disk_choice", bundle: .oust).font(Typography.headline).foregroundStyle(Palette.onGradient)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: Spacing.medium) {
                            ForEach(model.volumes) { volume in
                                VolumeChip(model: model, volume: volume, isSelected: model.analyzedVolume?.id == volume.id)
                                    .id(volume.id)
                            }
                        }
                        .padding(.vertical, Spacing.hair)
                    }
                    .scrollIndicators(.never)
                    // Le disque choisi reste entièrement visible.
                    .onChange(of: model.analyzedVolume?.id) { _, id in
                        if let id { withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(id) } }
                    }
                }
            }
        }
    }
}

private struct VolumeChip: View {
    let model: AppModel
    let volume: VolumeDescriptor
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let timeMachine = model.isTimeMachine(volume)
        let readOnly = model.isReadOnly(volume)
        let analyzed = model.analysisPhase(for: volume)
        Button { model.selectAnalysisVolume(volume) } label: {
            HStack(spacing: Spacing.medium) {
                Image(systemName: timeMachine ? "clock.arrow.circlepath" : volume.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    HStack(spacing: Spacing.tight) {
                        Text(verbatim: volume.name).font(Typography.headline).lineLimit(1)
                        if analyzed.isRunning {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else if analyzed.hasRun {
                            Image(systemName: "checkmark.circle.fill").font(Typography.caption)
                                .accessibilityLabel(Text("overview.disk_analyzed", bundle: .oust))
                        }
                    }
                    Group {
                        if timeMachine {
                            Text("overview.disk_time_machine", bundle: .oust)
                        } else if readOnly {
                            Text("overview.disk_read_only", bundle: .oust)
                        } else {
                            Text(verbatim: L10n.string("disks.of_total", Formatters.compactBytes(volume.capacity.availableForImportantUsage),
                                                       Formatters.compactBytes(volume.capacity.total)))
                                .monospacedDigit()
                        }
                    }
                    .font(Typography.caption)
                    .lineLimit(1)
                    Capsule().fill(Color.white.opacity(0.18))
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(Color.white.opacity(0.9))
                                    .frame(width: proxy.size.width * volume.capacity.occupiedFraction)
                            }
                        }
                        .frame(width: 150, height: 5)
                }
            }
            .foregroundStyle(Palette.onGradient)
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.medium)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .strokeBorder(Color.white.opacity(isSelected ? 0.95 : 0), lineWidth: 2)
            }
            .opacity(timeMachine ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(timeMachine)
        .help(timeMachine ? L10n.string("overview.disk_time_machine_help") : volume.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if !timeMachine {
                Button {
                    model.explore(volume)
                    model.section = .explorer
                } label: { Text("overview.explore_volume", bundle: .oust) }
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: isSelected)
    }
}
