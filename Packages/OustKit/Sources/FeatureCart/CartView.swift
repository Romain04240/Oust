import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Le panier : revoir, confirmer, puis regarder le vide se faire en direct.
public struct CartView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        switch model.cleaning {
        case .running:
            CleaningView(model: model)
        case .finished(let report):
            ReportView(model: model, report: report)
        case .idle:
            ReviewView(model: model)
        }
    }
}

// MARK: - Revue

private struct ReviewView: View {
    let model: AppModel
    @State private var confirming = false
    @State private var preview = FilePreview()
    @State private var selection: CleanupItem.ID?

    var body: some View {
        SectionScaffold(.cart, subtitle: "cart.subtitle") {
            if !model.cart.isEmpty {
                Button { model.clearCart() } label: { Text("cart.clear", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
        } content: {
            if model.cart.isEmpty {
                EmptyState(symbol: "trash", title: "cart.empty_title", message: "cart.empty_detail")
            } else {
                GlassCard(padding: Spacing.xLarge) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: Spacing.medium) {
                            // Des fichiers du cloud restés en ligne ne rendent rien ici : un
                            // « — » de 64 points ressemblait à une barre blanche (revue du
                            // 18/10/2026). On le dit en toutes lettres, sans les deux petits
                            // « — » dessous. Un snapshot seul garde son « — » : inconnu, pas nul.
                            if model.cartOnlySnapshots {
                                Text(verbatim: L10n.string("cart.snapshot_count", Formatters.count(model.cartSnapshotCount)))
                                    .font(Typography.title).foregroundStyle(Palette.onGradient)
                                if model.cartSnapshotSizesKnown {
                                    HeroSize(model.cartTotal, caption: model.cartSnapshotIsAggregate ? "snapshot.selected_total" : "snapshot.private_total", showsZero: true)
                                } else {
                                    Text(model.snapshotSizing ? "snapshot.measuring" : "snapshot.size_unknown", bundle: .oust)
                                        .font(Typography.headline).foregroundStyle(Palette.onGradientSecondary)
                                }
                            } else if model.cartFreesNothingHere {
                                Text("cart.nothing_on_mac", bundle: .oust)
                                    .font(Typography.title).foregroundStyle(Palette.onGradient)
                            } else {
                                HeroSize(model.cartTotal, caption: "cart.total_caption")
                                HStack(spacing: Spacing.large) {
                                    figure("cart.frees_now", model.cartFreesNow, "bolt.fill")
                                    figure("cart.to_trash", model.cartGoesToTrash, "trash.square")
                                    if !photoItems.isEmpty {
                                        figure("cart.to_photos", photoItems.reduce(0) { $0 + $1.sizes.freeable },
                                               AppSection.photos.symbol)
                                    }
                                }
                            }
                            // Un snapshot n'a pas de taille à lui que macOS veuille
                            // dire : il n'entre pas dans le total, et on le dit.
                            if model.cartItems.contains(where: { $0.category == .snapshots }) {
                                Label { Text("cart.snapshots_note", bundle: .oust) } icon: { Image(systemName: "clock.arrow.circlepath") }
                                    .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            // Photos fait confirmer, et garde 30 jours : on le dit avant.
                            if !photoItems.isEmpty {
                                Label { Text("cart.photos_note", bundle: .oust) } icon: { Image(systemName: AppSection.photos.symbol) }
                                    .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            // Un navigateur ouvert garde ses caches : proposer de le fermer, puis de le rouvrir.
                            BrowserCloseBanner(model: model)
                            // Un fichier d'un nuage part aussi du nuage et des autres
                            // appareils : on le dit avant, pas après.
                            if model.cartItems.contains(where: { $0.method == .trashFromCloud }) {
                                Label { Text("cart.clouds_note", bundle: .oust) } icon: { Image(systemName: AppSection.clouds.symbol) }
                                    .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button { confirming = true } label: {
                                Text(verbatim: model.cartTotal > 0
                                     ? L10n.string("cart.clean", Formatters.compactBytes(model.cartTotal))
                                     : L10n.string("cart.clean_plain"))
                            }
                            .buttonStyle(PrimaryButtonStyle(section: .cart, eclat: true))
                            .keyboardShortcut(.return, modifiers: .command)
                        }
                        Spacer()
                        PulseOrb(section: .cart, isActive: false, size: 160)
                    }
                }
                VStack(alignment: .leading, spacing: Spacing.xLarge) {
                    ForEach(MethodGroup.allCases, id: \.self) { group in
                        let items = model.cartItems.filter { group.contains($0.method) }
                        if !items.isEmpty {
                            ItemGroup(title: L10n.string(group.titleKey), symbol: group.symbol, tint: group.tint,
                                      total: items.reduce(0) { $0 + $1.sizes.freeable },
                                      totalLabel: items.allSatisfy { $0.method.isSnapshot }
                                        ? model.cartSnapshotBytes.map(Formatters.bytes) ?? L10n.string("snapshot.size_unknown") : nil) {
                                LazyVStack(spacing: 0) {
                                    ForEach(items) { item in
                                        row(item)
                                        Divider().opacity(0.25)
                                    }
                                }
                            }
                        }
                    }
                }
                .previewKeys(selection: $selection, order: orderedItems.map(\.id)) { id in
                    if let item = orderedItems.first(where: { $0.id == id }), let url = previewURL(item) {
                        preview.toggle(url, among: previewNeighbors())
                    }
                }
                .filePreview(preview)
                // Le panneau suit la sélection, et la sélection ses flèches.
                .onChange(of: selection) {
                    guard preview.isOpen, let item = orderedItems.first(where: { $0.id == selection }) else { return }
                    preview.follow(previewURL(item), among: previewNeighbors())
                }
                .onChange(of: preview.current) {
                    guard let current = preview.current else { return }
                    if let item = orderedItems.first(where: { previewURL($0) == current }) { selection = item.id }
                }
            }
        }
        .confirmationDialog(Text("cart.confirm_title", bundle: .oust), isPresented: $confirming) {
            Button(role: .destructive) { model.startCleaning() } label: {
                Text(verbatim: L10n.string("cart.confirm_action", Formatters.compactBytes(model.cartTotal)))
            }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .oust) }
        } message: {
            let base = model.cartNeedsStrongConfirmation
                ? L10n.string("cart.confirm_strong", Formatters.count(model.cartItems.filter { $0.safety == .review }.count))
                : L10n.string("cart.confirm_message")
            let clouds = model.cartItems.filter { $0.method == .trashFromCloud }.count
            // Dit une seconde fois, au moment de confirmer : partout, pas seulement ici.
            Text(verbatim: clouds == 0 ? base : base + "\n\n" + L10n.string("cart.clouds_confirm", Formatters.count(clouds)))
        }
    }

    private var photoItems: [CleanupItem] { model.cartItems.filter { $0.method.photoAssetID != nil } }

    private func figure(_ key: LocalizedStringKey, _ value: Int64, _ symbol: String) -> some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: symbol)
            VStack(alignment: .leading, spacing: 0) {
                Text(key, bundle: .oust).font(Typography.caption)
                Text(verbatim: Formatters.compactBytes(value)).font(Typography.headline.monospacedDigit())
            }
        }
        .foregroundStyle(Palette.onGradient)
    }

    // MARK: Coup d'œil

    /// Une ligne de la corbeille ; l'œil seulement pour un élément d'un seul
    /// chemin. Regarder ne retire rien : seul le rond de la ligne le fait.
    private func row(_ item: CleanupItem) -> some View {
        let isChosen = selection == item.id
        let url = previewURL(item)
        let show: (() -> Void)? = url.map { url in { preview.show(url, among: previewNeighbors()) } }
        return ItemRow(item, isSelected: true, showOwner: true, showsPreview: isChosen, preview: show) { model.toggle(item) }
            .previewRow(isSelected: isChosen, select: { selection = item.id }, preview: show)
            .id(item.id)
    }

    /// Les éléments dans l'ordre affiché : groupe par groupe.
    private var orderedItems: [CleanupItem] {
        MethodGroup.allCases.flatMap { group in model.cartItems.filter { group.contains($0.method) } }
    }

    private func previewURL(_ item: CleanupItem) -> URL? {
        // Le coup d'œil d'un fichier resté dans le nuage le téléchargerait.
        guard !item.notes.contains(.cloudOnly) else { return nil }
        return item.paths.count == 1 ? item.paths[0] : nil
    }

    /// Les fichiers de la corbeille entre lesquels les flèches du panneau
    /// circulent. Lu sur le disque, donc seulement quand on regarde.
    private func previewNeighbors() -> [URL] {
        orderedItems.compactMap(previewURL).filter { PreviewKind.of($0) == .file }
    }
}

/// Les éléments regroupés par façon de partir.
enum MethodGroup: CaseIterable {
    case now, trash, photos, tools

    func contains(_ method: CleanupMethod) -> Bool {
        switch (self, method) {
        case (.now, .removeNow), (.trash, .trash), (.trash, .trashFromCloud), (.photos, .photoAsset): true
        case (.tools, .removeNow), (.tools, .trash), (.tools, .trashFromCloud), (.tools, .photoAsset), (.now, _), (.trash, _),
             (.photos, _): false
        case (.tools, _): true
        }
    }

    var titleKey: String {
        switch self {
        case .now: "cart.group_now"
        case .trash: "cart.group_trash"
        case .photos: "cart.group_photos"
        case .tools: "cart.group_tools"
        }
    }

    var symbol: String {
        switch self {
        case .now: "bolt.fill"
        case .trash: "trash.square.fill"
        case .photos: "photo.on.rectangle.angled"
        case .tools: "wrench.and.screwdriver.fill"
        }
    }

    var tint: Color {
        switch self {
        case .now: Palette.color(for: .safe)
        case .trash: Palette.color(for: .review)
        case .photos: Palette.gradient(for: .photos).start
        case .tools: Palette.color(for: .rebuilds)
        }
    }
}

// MARK: - En direct

/// Le nettoyage en direct (SPEC §9.3) : l'orbe bat à chaque élément, l'élément
/// quitte la liste, le compteur monte.
private struct CleaningView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SectionBackground(.cart)
            VStack(spacing: Spacing.xLarge) {
                PulseOrb(section: .cart, isActive: true, beat: model.beat, size: 240)
                VStack(spacing: Spacing.tight) {
                    Text(verbatim: Formatters.compactBytes(model.freedSoFar))
                        .font(.system(size: 80, weight: .heavy, design: .rounded))
                        .foregroundStyle(Palette.onGradient)
                        .contentTransition(.numericText(value: Double(model.freedSoFar)))
                        .animation(.snappy, value: model.freedSoFar)
                    Text("cleaning.freed", bundle: .oust).font(Typography.headline).foregroundStyle(Palette.onGradientSecondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(spacing: Spacing.tight) {
                            Text(verbatim: phaseDescription)
                                .font(Typography.headline)
                            Text(verbatim: L10n.string("cleaning.completed_count",
                                Formatters.count(model.cleanupProgress.completed), Formatters.count(model.cleanupProgress.total)))
                            Text(verbatim: L10n.string("cleaning.elapsed",
                                duration(model.cleanupProgress.elapsed()), duration(model.cleanupProgress.phaseElapsed())))
                                .font(Typography.caption).monospacedDigit()
                        }
                        .foregroundStyle(Palette.onGradient)
                    }
                    if let current = model.liveQueue.first(where: { $0.id == model.currentItemID }) {
                        Text(verbatim: L10n.string("cleaning.current", current.title))
                            .font(Typography.body).foregroundStyle(Palette.onGradient).lineLimit(1)
                            .id(current.id)
                            .transition(.opacity)
                    }
                }
                ListSurface {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.liveQueue) { item in
                                HStack(spacing: Spacing.medium) {
                                    Image(systemName: model.currentItemIDs.contains(item.id) ? "arrow.triangle.2.circlepath" : Describe.symbol(item.method))
                                        .foregroundStyle(Palette.color(for: item.category))
                                        .symbolEffect(.rotate, isActive: model.currentItemIDs.contains(item.id) && !reduceMotion)
                                        .frame(width: 22)
                                    Text(verbatim: item.title).lineLimit(1)
                                    Text(verbatim: item.owner).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Text(verbatim: Formatters.compactBytes(item.sizes.freeable)).font(Typography.size)
                                }
                                .padding(.horizontal, Spacing.large)
                                .padding(.vertical, Spacing.small)
                                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity,
                                                                                  removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.9))))
                            }
                        }
                        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.25),
                                   value: model.liveQueue.map(\.id))
                    }
                }
                .frame(maxWidth: 640, maxHeight: 280)
                Button { model.cancelCleaning() } label: { Text("cleaning.stop", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
                    .disabled(model.cleaningStopRequested)
                if model.cleaningStopRequested {
                    Text("cleaning.stop_requested", bundle: .oust)
                        .font(Typography.caption).foregroundStyle(Palette.onGradient)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(Spacing.xxLarge)
            .onSectionBackground()
        }
    }

    private var phaseDescription: String {
        switch model.cleanupProgress.phase {
        case .preparing: L10n.string("cleaning.phase.preparing")
        case .revalidating: L10n.string("cleaning.phase.revalidating")
        case .checkingSnapshotComponent: L10n.string("cleaning.phase.checking_component")
        case .deletingSnapshots(let count): L10n.string("cleaning.phase.snapshot_batch", Formatters.count(count))
        case .authorizingSnapshots(let count): L10n.string("cleaning.phase.snapshot_authorization", Formatters.count(count))
        case .verifyingSnapshots: L10n.string("cleaning.phase.verifying_snapshots")
        case .deleting: L10n.string("cleaning.phase.deleting")
        case .journaling: L10n.string("cleaning.phase.journaling")
        case .measuring: L10n.string("cleaning.phase.measuring")
        }
    }

    private func duration(_ elapsed: Duration) -> String {
        let seconds = max(0, elapsed.components.seconds)
        return Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }
}

// MARK: - Bilan

/// Le bilan honnête : ce qui est vraiment revenu, ce qui attend, ce qui est retenu.
private struct ReportView: View {
    let model: AppModel
    let report: CleanupReport

    var body: some View {
        SectionScaffold(.cart, subtitle: "report.subtitle") {
            Button { model.dismissReport() } label: { Text("report.done", bundle: .oust) }
                .buttonStyle(OnGradientButtonStyle())
        } content: {
            GlassCard(padding: Spacing.xLarge) {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    // Des fichiers du cloud restés en ligne, ou rien qui soit parti :
                    // un « — » géant puis « de vide fait » et trois « — » (essai du
                    // 18/10/2026). On le dit en toutes lettres, comme la corbeille.
                    if onlySnapshots, snapshotSuccesses > 0 {
                        Text(verbatim: L10n.string("report.snapshots_deleted", Formatters.count(snapshotSuccesses)))
                            .font(Typography.title).foregroundStyle(Palette.onGradient)
                        if snapshotRecovered > 0 {
                            HeroSize(snapshotRecovered, caption: "report.measured")
                        } else {
                            Text("report.snapshots_waiting", bundle: .oust)
                                .font(Typography.headline).foregroundStyle(Palette.onGradientSecondary)
                        }
                        Text("report.snapshots_measurement", bundle: .oust)
                            .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
                    } else if freedNothingHere {
                        Text("report.nothing_on_mac", bundle: .oust)
                            .font(Typography.title).foregroundStyle(Palette.onGradient)
                    } else {
                        HeroSize(report.expectedNow + report.pendingInTrash + report.pendingInPhotos, caption: "report.total_caption")
                        HStack(spacing: Spacing.xLarge) {
                            figure("report.freed_now", report.expectedNow, "bolt.fill")
                            figure("report.in_trash", report.pendingInTrash, "trash.square")
                            if report.pendingInPhotos > 0 {
                                figure("report.in_photos", report.pendingInPhotos, AppSection.photos.symbol)
                            }
                            if let measured = report.measuredNow {
                                figure("report.measured", measured, "gauge.with.dots.needle.67percent")
                            }
                        }
                    }
                    if report.pendingInTrash > 0 {
                        Text("report.trash_hint", bundle: .oust).font(Typography.body).foregroundStyle(Palette.onGradientSecondary)
                    }
                    // Ils ne rendent rien ici, mais ils sont partis : où, et comment les
                    // faire revenir (vérifié pour iCloud Drive et Google Drive).
                    if cloudFilesTrashed > 0 {
                        Text(verbatim: L10n.string("report.clouds_hint", Formatters.count(cloudFilesTrashed)))
                            .font(Typography.body).foregroundStyle(Palette.onGradientSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Ni rendu maintenant, ni dans la corbeille du Mac : Photos le garde 30 jours.
                    if report.pendingInPhotos > 0 {
                        Text("report.photos_hint", bundle: .oust).font(Typography.body).foregroundStyle(Palette.onGradientSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if report.purging > 0 {
                        Label {
                            Text(verbatim: L10n.string("report.purging", Formatters.compactBytes(report.purging)))
                        } icon: { Image(systemName: "hourglass") }
                            .font(Typography.body).foregroundStyle(Palette.onGradient)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.shouldOfferSnapshotRelease {
                        // Après un gros nettoyage dont les snapshots retiennent
                        // l'espace : le proposer ici, pas seulement dans Système.
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            Text(verbatim: L10n.string("report.snapshots_holding",
                                                       Formatters.compactBytes(model.stillHeldBack(report)),
                                                       Formatters.count(model.deletableSnapshots.count)))
                                .font(Typography.body).foregroundStyle(Palette.onGradient)
                                .fixedSize(horizontal: false, vertical: true)
                            Button { model.releaseSnapshots() } label: {
                                Label { Text("report.release_snapshots", bundle: .oust) } icon: {
                                    Image(systemName: "clock.arrow.circlepath")
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle(section: .cart, eclat: true))
                        }
                    } else if report.heldBack > 100_000_000 {
                        Text(verbatim: L10n.string("report.held_back", Formatters.compactBytes(report.heldBack)))
                            .font(Typography.body).foregroundStyle(Palette.onGradient)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reclaimed = model.reclaimed, let after = report.availableAfter, reclaimed.available > after {
                        Label {
                            Text(verbatim: L10n.string("report.reclaiming", Formatters.compactBytes(reclaimed.available - after)))
                        } icon: { Image(systemName: "arrow.down.circle") }
                            .font(Typography.headline).foregroundStyle(Palette.onGradient)
                    }
                    HStack(spacing: Spacing.medium) {
                        // Le vide fait, l'étape suivante : voir ce qu'il reste.
                        Button {
                            model.dismissReport()
                            model.section = .overview
                            Task { await model.analyze() }
                        } label: { Text("overview.reanalyze", bundle: .oust) }
                            .buttonStyle(PrimaryButtonStyle(section: .cart))
                        Button { model.section = .history; model.dismissReport() } label: { Text("report.see_history", bundle: .oust) }
                            .buttonStyle(OnGradientButtonStyle())
                    }
                }
            }
            let problems = report.skippedOrFailed
            if !problems.isEmpty {
                ItemGroup(title: L10n.string("report.left_in_place"), symbol: "hand.raised.fill",
                          tint: Palette.color(for: .review), total: 0) {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        ForEach(problems) { outcome in
                            HStack {
                                Text(verbatim: outcome.title).font(Typography.body.weight(.semibold))
                                Text(verbatim: outcome.owner).font(Typography.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(verbatim: Describe.outcome(outcome.result)).font(Typography.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Rien de compté, et rien dont la taille soit inconnue : un snapshot
    /// supprimé ne compte rien d'avance mais rend de la place, que la mesure
    /// du disque montre.
    private var onlySnapshots: Bool { !report.outcomes.isEmpty && report.outcomes.allSatisfy { $0.method.isSnapshot } }
    private var snapshotSuccesses: Int { report.succeeded.filter { $0.method.isSnapshot }.count }
    private var snapshotRecovered: Int64 {
        guard let before = report.availableBefore else { return 0 }
        return max(0, max(model.reclaimed?.available ?? 0, report.availableAfter ?? 0) - before)
    }

    private var freedNothingHere: Bool {
        report.expectedNow + report.pendingInTrash + report.pendingInPhotos == 0
            && !report.succeeded.contains { $0.category == .snapshots }
    }

    private var cloudFilesTrashed: Int {
        report.succeeded.filter { $0.method == .trashFromCloud }.count
    }

    private func figure(_ key: LocalizedStringKey, _ value: Int64, _ symbol: String) -> some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: symbol).font(.system(size: 20, weight: .bold))
            VStack(alignment: .leading, spacing: 0) {
                Text(key, bundle: .oust).font(Typography.caption)
                Text(verbatim: Formatters.compactBytes(value)).font(Typography.title.monospacedDigit())
            }
        }
        .foregroundStyle(Palette.onGradient)
    }
}
