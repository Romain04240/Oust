import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustArchive
import OustModel

/// L'archivage des projets inactifs sur un disque externe (SPEC §10, phase 2) :
/// copier, vérifier chaque fichier, puis seulement envoyer l'original à la
/// corbeille du Mac.
public struct ArchiveView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var archive: ArchiveModel { model.archive }

    public var body: some View {
        SectionScaffold(.archive, subtitle: "archive.subtitle") {
            HStack(spacing: Spacing.small) {
                ContextHelpButton(text: L10n.string("archive.step_copy") + "\n\n"
                                  + L10n.string("archive.step_verify") + "\n\n"
                                  + L10n.string("archive.step_trash"))
                Picker(selection: Binding(get: { archive.inactiveMonths }, set: { archive.inactiveMonths = $0 })) {
                    ForEach([0, 1, 3, 6, 12, 24], id: \.self) { months in
                        Text(verbatim: months == 0 ? L10n.string("archive.all_projects")
                             : L10n.string("archive.months", Formatters.count(months))).tag(months)
                    }
                } label: {
                    Text("archive.inactive_for", bundle: .oust)
                }
                .fixedSize()
                .disabled(archive.running == .running || archive.search.isRunning)
                // Le libellé ne change pas pendant la recherche : la carte en
                // dessous le dit déjà, et « Recherche des projets endormis… »
                // passait sur deux lignes, coupé, à 1080 pt de fenêtre.
                Button { Task { await archive.find() } } label: {
                    Text("archive.search", bundle: .oust)
                }
                .buttonStyle(OnGradientButtonStyle())
                .disabled(archive.search.isRunning || archive.running == .running)
            }
            .fixedSize()
        } content: {
            switch archive.running {
            case .running:
                ArchivingCard(archive: archive)
            case .finished:
                Report(model: model)
            case .idle:
                if archive.focusedProjectID != nil {
                    HStack {
                        Text("advice.archive_focus", bundle: .oust).font(Typography.headline)
                        Spacer()
                        Button { archive.focusedProjectID = nil } label: { Text("advice.show_all_projects", bundle: .oust) }
                            .buttonStyle(OnGradientButtonStyle())
                    }
                    .foregroundStyle(Palette.onGradient)
                    Candidates(archive: archive)
                    Destination(archive: archive)
                }
                rootsCard
                if archive.focusedProjectID == nil {
                    Destination(archive: archive)
                    Candidates(archive: archive)
                }
            }
        }
        .task { if !archive.search.hasRun { await archive.find() } }
        .onChange(of: archive.inactiveMonths) { _, _ in Task { await archive.find() } }
    }

    private var rootsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack {
                    Text("archive.roots_title", bundle: .oust).font(Typography.headline)
                    Spacer()
                    Button { addRoot() } label: { Text("archive.add_root", bundle: .oust) }
                        .buttonStyle(OnGradientButtonStyle())
                        .disabled(archive.search.isRunning || archive.running == .running)
                }
                Text("archive.activity_hint", bundle: .oust).font(Typography.caption)
                if archive.projectRoots.isEmpty {
                    Text("archive.no_roots", bundle: .oust)
                }
                ForEach(archive.projectRoots, id: \.path) { root in
                    Text(verbatim: root.path).font(Typography.caption).textSelection(.enabled)
                }
            }
            .foregroundStyle(Palette.onGradient)
        }
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            archive.addRoots(panel.urls)
            Task { await archive.find() }
        }
    }
}

// MARK: - Avant

private struct Destination: View {
    let archive: ArchiveModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack {
                    Image(systemName: "externaldrive.fill").foregroundStyle(Palette.onGradient)
                    if let destination = archive.destination {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: destination.name).font(Typography.headline).foregroundStyle(Palette.onGradient)
                            Text(verbatim: L10n.string("archive.destination_detail", destination.fileSystem.uppercased(),
                                                       Formatters.compactBytes(destination.available)))
                                .font(Typography.caption).foregroundStyle(Palette.onGradient)
                        }
                    } else {
                        Text("archive.no_destination", bundle: .oust).font(Typography.headline).foregroundStyle(Palette.onGradient)
                    }
                    Spacer()
                    Menu {
                        ForEach(archive.volumes) { volume in
                            Button { archive.choose(volume: volume.mountURL) } label: {
                                Label { Text(verbatim: volume.name) } icon: { Image(systemName: volume.symbol) }
                            }
                        }
                        if !archive.volumes.isEmpty { Divider() }
                        Button { chooseVolume() } label: {
                            Label { Text("archive.choose_other", bundle: .oust) } icon: { Image(systemName: "folder") }
                        }
                    } label: {
                        Text("archive.choose_destination", bundle: .oust)
                    }
                    .menuStyle(.button)
                    .buttonStyle(OnGradientButtonStyle())
                    .fixedSize()
                }
                if let destination = archive.destination {
                    advice(destination.advice)
                }
                ForEach(Array(archive.refusals.enumerated()), id: \.offset) { _, refusal in
                    Label { Text(verbatim: describe(refusal)) } icon: { Image(systemName: "xmark.octagon.fill") }
                        .font(Typography.caption).foregroundStyle(Palette.onGradient)
                }
            }
        }
    }

    @ViewBuilder
    private func advice(_ advice: FileSystemAdvice) -> some View {
        switch advice {
        case .recommended:
            Label { Text("archive.fs_recommended", bundle: .oust) } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.vivid(for: .safe))
            }
            .font(Typography.caption).foregroundStyle(Palette.onGradient)
        case .acceptable:
            Label { Text("archive.fs_acceptable", bundle: .oust) } icon: {
                Image(systemName: "checkmark.circle").foregroundStyle(Palette.vivid(for: .rebuilds))
            }
            .font(Typography.caption).foregroundStyle(Palette.onGradient)
        case .warning(let warning):
            Label { Text(LocalizedStringKey(warning.localizationKey), bundle: .oust).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.vivid(for: .review))
            }
            .font(Typography.caption).foregroundStyle(Palette.onGradient)
        }
    }

    private func describe(_ refusal: DestinationRefusal) -> String {
        switch refusal {
        case .notEnoughSpace(let needed, let available):
            L10n.string(refusal.localizationKey, Formatters.compactBytes(needed), Formatters.compactBytes(available))
        case .fileTooLarge(let name):
            L10n.string(refusal.localizationKey, name)
        case .readOnly, .sameVolume:
            L10n.string(refusal.localizationKey)
        }
    }

    private func chooseVolume() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { archive.choose(volume: url) }
    }
}

private struct Candidates: View {
    let archive: ArchiveModel
    @State private var confirming = false

    var body: some View {
        switch archive.search {
        case .idle:
            EmptyState(symbol: "tray.and.arrow.down", title: "archive.empty_title", message: "archive.empty_detail")
        case .running:
            GlassCard(padding: Spacing.xLarge) {
                HStack(spacing: Spacing.xLarge) {
                    PulseOrb(section: .archive, isActive: true, size: 120)
                    Text("archive.searching", bundle: .oust).font(Typography.headline).foregroundStyle(Palette.onGradient)
                }
            }
        case .done:
            if archive.displayedCandidates.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: "archive.none_title", message: "archive.none_detail")
            } else {
                HStack(alignment: .bottom) {
                    // Rien de coché : pas de chiffre. `compactBytes(0)` rend un
                    // tiret, et un tiret de 64 pt se lisait comme une barre
                    // blanche posée sur le dégradé.
                    if archive.chosenBytes > 0 {
                        HeroSize(archive.chosenBytes, caption: "archive.total_caption")
                    }
                    Spacer()
                    Button { confirming = true } label: {
                        Text(verbatim: L10n.string("archive.start", Formatters.count(archive.chosen.count)))
                    }
                    .buttonStyle(PrimaryButtonStyle(section: .archive))
                    .disabled(!archive.canStart)
                    .confirmationDialog(Text("archive.confirm_title", bundle: .oust), isPresented: $confirming) {
                        Button { archive.start() } label: {
                            Text(verbatim: L10n.string("archive.confirm_action", archive.destination?.name ?? ""))
                        }
                        Button(role: .cancel) {} label: { Text("common.cancel", bundle: .oust) }
                    } message: {
                        Text(verbatim: L10n.string("archive.confirm_message", Formatters.count(archive.chosen.count),
                                                   archive.destination?.name ?? ""))
                    }
                }
                ItemGroupSurface(archive: archive)
            }
        }
    }
}

private struct ItemGroupSurface: View {
    let archive: ArchiveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(archive.displayedCandidates) { candidate in
                CandidateRow(candidate: candidate, chosen: archive.chosen.contains(candidate.id)) { archive.toggle(candidate) }
                Divider().opacity(0.25)
            }
        }
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.small)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

private struct CandidateRow: View {
    let candidate: ProjectCandidate
    let chosen: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Button(action: toggle) {
                Image(systemName: candidate.isArchivable ? (chosen ? "checkmark.circle.fill" : "circle") : "lock.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(chosen ? Palette.color(for: .archives) : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!candidate.isArchivable)
            .accessibilityLabel(Text("row.select", bundle: .oust))

            Image(systemName: "folder.fill").foregroundStyle(Palette.color(for: .archives)).frame(width: 22)
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(verbatim: candidate.name).font(Typography.body.weight(.semibold)).lineLimit(1)
                if let blocker = candidate.blocker {
                    Tag(blockerText(blocker), symbol: "lock.fill", tint: Palette.vivid(for: .protected))
                } else {
                    Text(verbatim: candidate.lastModified.map { L10n.string("archive.untouched_since", Formatters.relative($0)) } ?? "")
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(verbatim: L10n.string("explorer.files", Formatters.count(candidate.fileCount)))
                .font(Typography.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(verbatim: Formatters.compactBytes(candidate.sizes.allocated)).font(Typography.size)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, Spacing.tight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggle() }
        .contextMenu {
            Button { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) } label: {
                Label { Text("row.reveal", bundle: .oust) } icon: { Image(systemName: "folder") }
            }
        }
    }

    private func blockerText(_ blocker: ArchiveBlocker) -> String {
        if let argument = blocker.argument { return L10n.string(blocker.localizationKey, argument) }
        return L10n.string(blocker.localizationKey)
    }
}

// MARK: - Pendant

private struct ArchivingCard: View {
    let archive: ArchiveModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassCard(padding: Spacing.xLarge) {
            HStack(spacing: Spacing.xLarge) {
                PulseOrb(section: .archive, isActive: true, beat: archive.outcomes.count, size: 160)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        let name = archive.candidates.first { $0.id == archive.currentID }?.name ?? ""
                        Text(verbatim: L10n.string(archive.currentStep == .trashing ? "archive.trashing" : "archive.copying", name))
                            .font(Typography.headline).foregroundStyle(Palette.onGradient)
                        Text(verbatim: Formatters.compactBytes(archive.progress.copiedBytes))
                            .font(Typography.hero).foregroundStyle(Palette.onGradient)
                            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(archive.progress.copiedBytes)))
                        Text(verbatim: L10n.string("archive.copied_files", Formatters.count(archive.progress.copiedFiles)))
                            .font(Typography.body).foregroundStyle(Palette.onGradient)
                        Button { archive.cancel() } label: { Text("common.cancel", bundle: .oust) }
                            .buttonStyle(OnGradientButtonStyle())
                    }
                }
            }
        }
    }
}

// MARK: - Après

private struct Report: View {
    let model: AppModel

    private var archive: ArchiveModel { model.archive }

    var body: some View {
        GlassCard(padding: Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                HeroSize(archive.archivedBytes, caption: "archive.report_caption")
                Text(verbatim: L10n.string("archive.report_detail", Formatters.count(archive.outcomes.filter(\.completed).count),
                                           archive.destination?.name ?? ""))
                    .font(Typography.body).foregroundStyle(Palette.onGradient)
                HStack {
                    Button { model.section = .history; archive.dismissReport() } label: { Text("report.see_history", bundle: .oust) }
                        .buttonStyle(OnGradientButtonStyle())
                    Button { archive.dismissReport() } label: { Text("common.ok", bundle: .oust) }
                        .buttonStyle(PrimaryButtonStyle(section: .archive))
                }
            }
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(archive.outcomes) { outcome in
                HStack(spacing: Spacing.medium) {
                    Image(systemName: outcome.completed ? "checkmark.circle.fill" : (outcome.copy == nil ? "xmark.circle.fill" : "exclamationmark.circle.fill"))
                        .foregroundStyle(outcome.completed ? Palette.vivid(for: .safe) : Palette.vivid(for: .review))
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(verbatim: outcome.project.name).font(Typography.body.weight(.semibold))
                        Text(verbatim: summary(outcome)).font(Typography.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let copy = outcome.copy {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([copy]) } label: {
                            Text("archive.reveal_copy", bundle: .oust)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, Spacing.small)
                Divider().opacity(0.25)
            }
        }
        .padding(.horizontal, Spacing.large)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    /// Ce qui est arrivé, en une phrase : archivé, ou pourquoi l'original est resté.
    private func summary(_ outcome: ArchiveOutcome) -> String {
        if outcome.completed { return L10n.string("archive.outcome_done", outcome.copy?.path ?? "") }
        if let error = outcome.error {
            return L10n.string("archive.outcome_failed", ArchiveModel.describe(error))
        }
        if outcome.copy != nil { return L10n.string("archive.outcome_kept", Describe.outcome(outcome.result)) }
        return Describe.outcome(outcome.result)
    }
}
