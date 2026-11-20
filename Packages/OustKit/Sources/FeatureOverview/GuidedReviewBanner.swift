import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Le parcours reste au-dessus de l’outil courant : aucune vue d’analyse
/// sortante n’est conservée pour animer le passage à l’étape suivante.
public struct GuidedReviewBanner: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        if let session = model.guidedReview, session.stage != .paused, !model.isSearching {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.medium) {
                    heading(for: session)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ContextHelpButton(text: explanation(for: session))
                        .foregroundStyle(model.guidedReviewNeedsStartupExplorer ? Color.orange : Palette.onGradient)
                        .accessibilityValue(Text(model.guidedReviewNeedsStartupExplorer
                            ? "guided_review.startup_explorer_required" : "guided_review.safety", bundle: .oust))
                    actions(for: session)
                    Button { model.endGuidedReview(token: session.token) } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("guided_review.close", bundle: .oust))
                }
                progress(for: session)
            }
            .frame(height: 64)
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.small)
            .foregroundStyle(Palette.onGradient)
            .background(Palette.colors(for: .overview).deep)
            .environment(\.colorScheme, .dark)
        }
    }

    private func heading(for session: GuidedReviewSession) -> some View {
        HStack(spacing: Spacing.small) {
            GuidedReviewIcon(section: session.step)
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text("guided_review.title", bundle: .oust).font(Typography.caption)
                Text(LocalizedStringKey(session.step.localizationKey), bundle: .oust)
                    .font(Typography.headline)
                    .lineLimit(1)
                    .help(Text(LocalizedStringKey(session.step.localizationKey), bundle: .oust))
                Text(verbatim: L10n.string("guided_review.progress", Formatters.count(session.completedCount),
                                           Formatters.count(GuidedReviewSession.steps.count)))
                    .font(Typography.caption.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private func actions(for session: GuidedReviewSession) -> some View {
        // Une commande affichée pour une étape ne doit pas agir sur sa suivante.
        let token = session.token
        HStack(spacing: Spacing.small) {
            switch session.stage {
            case .offering:
                Button { model.examineGuidedReview(token: token) } label: {
                    Label { Text("guided_review.examine", bundle: .oust) } icon: {
                        Image(systemName: "arrow.right.circle")
                    }
                }
                .disabled(model.guidedReviewNeedsStartupExplorer)
                if session.step != .cart {
                    Button { model.skipGuidedReview(token: token) } label: {
                        Text("guided_review.skip", bundle: .oust)
                    }
                }
            case .examining:
                Button { model.completeGuidedReviewStep(token: token) } label: {
                    Text(session.step == .cart ? "guided_review.finish" : "guided_review.complete_step", bundle: .oust)
                }
                Button { model.pauseGuidedReview(token: token) } label: {
                    Text("guided_review.pause", bundle: .oust)
                }
            case .paused:
                Button { model.resumeGuidedReview(token: token) } label: {
                    Text("guided_review.resume", bundle: .oust)
                }
                Button { model.endGuidedReview(token: token) } label: {
                    Text("guided_review.close", bundle: .oust)
                }
            }
        }
        .buttonStyle(OnGradientButtonStyle())
    }

    private func progress(for session: GuidedReviewSession) -> some View {
        HStack(spacing: Spacing.tight) {
            ForEach(GuidedReviewSession.steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index < session.completedCount ? Color.white
                          : (index == session.index ? Palette.colors(for: session.step).glow : Color.white.opacity(0.2)))
                    .frame(height: index == session.index ? 5 : 3)
            }
        }
        .frame(height: 5)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: session.index)
        .accessibilityHidden(true)
    }

    private func explanation(for session: GuidedReviewSession) -> String {
        let warning = model.guidedReviewNeedsStartupExplorer
            ? L10n.string("guided_review.startup_explorer_required") + "\n\n" : ""
        return warning + L10n.string(explanationKey(for: session)) + "\n\n" + L10n.string("guided_review.safety")
    }

    private func explanationKey(for session: GuidedReviewSession) -> String {
        switch session.stage {
        case .offering: "guided_review.detail." + session.step.rawValue
        case .examining: session.step == .cart ? "guided_review.cart_detail" : "guided_review.examining_detail"
        case .paused: "guided_review.paused_detail"
        }
    }
}

/// A permanent, non-scrolling entry; it does not select cleanup items.
public struct GuidedReviewLauncher: View {
    let model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let session = model.guidedReview
        let paused = session?.stage == .paused
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    if let session, paused { model.resumeGuidedReview(token: session.token) }
                    else { model.startGuidedReviewFromSidebar() }
                } label: {
                    Label {
                        Text(paused ? "guided_review.resume" : (session == nil ? "guided_review.start" : "guided_review.title"), bundle: .oust)
                            .font(Typography.body.weight(.semibold))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } icon: { Image(systemName: "arrow.triangle.branch") }
                    .frame(height: 36)
                }
                .buttonStyle(OnGradientButtonStyle())
                .disabled(!paused && !model.canStartGuidedReviewFromSidebar)
                // This place is reserved even without a session: no width jump.
                Group {
                    if let session {
                        Button { model.endGuidedReview(token: session.token) } label: {
                            Image(systemName: "xmark.circle")
                                .frame(width: 24, height: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("guided_review.close", bundle: .oust))
                        .help(Text("guided_review.close", bundle: .oust))
                    } else { Color.clear.frame(width: 24, height: 36).accessibilityHidden(true) }
                }
            }
            Text(LocalizedStringKey(model.guidedReviewAvailability.localizationKey), bundle: .oust)
                .font(Typography.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .topLeading)
        }
        .frame(height: 84)

    }
}

private struct GuidedReviewIcon: View {
    let section: AppSection

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Palette.linearGradient(for: section), in: RoundedRectangle(cornerRadius: Radius.medium))
            .accessibilityHidden(true)
    }
}
