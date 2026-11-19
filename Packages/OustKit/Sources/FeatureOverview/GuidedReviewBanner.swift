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
        if let session = model.guidedReview,
           session.stage != .offering || (model.section == .overview && !model.isSearching) {
            GlassCard(padding: Spacing.medium) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.large) {
                            heading(for: session).fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: Spacing.small)
                            actions(for: session).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            heading(for: session)
                            actions(for: session)
                        }
                    }
                    Text(LocalizedStringKey(explanationKey(for: session)), bundle: .oust)
                        .font(Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.guidedReviewNeedsStartupExplorer {
                        Label { Text("guided_review.startup_explorer_required", bundle: .oust) } icon: {
                            Image(systemName: "info.circle")
                        }
                        .font(Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .center, spacing: Spacing.small) {
                        Text("guided_review.safety", bundle: .oust)
                            .font(Typography.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    progress(for: session)
                }
                .foregroundStyle(Palette.onGradient)
            }
            .background(Palette.colors(for: .overview).deep, in: RoundedRectangle(cornerRadius: Radius.card))
            .padding(.horizontal, Spacing.large)
            .padding(.top, Spacing.small)
            .padding(.bottom, Spacing.small)
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
                    .lineLimit(2)
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

    private func explanationKey(for session: GuidedReviewSession) -> String {
        switch session.stage {
        case .offering: "guided_review.detail." + session.step.rawValue
        case .examining: session.step == .cart ? "guided_review.cart_detail" : "guided_review.examining_detail"
        case .paused: "guided_review.paused_detail"
        }
    }
}

/// L’entrée du parcours reste distincte des mesures et des commandes du disque.
struct GuidedReviewStartCard: View {
    let model: AppModel

    var body: some View {
        GlassCard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.large) {
                    introduction.frame(minWidth: 250)
                    Spacer(minLength: Spacing.small)
                    startButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    introduction
                    startButton
                }
            }
            .foregroundStyle(Palette.onGradient)
        }
    }

    private var introduction: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            GuidedReviewIcon(section: .overview)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("guided_review.start_title", bundle: .oust).font(Typography.headline)
                Text("guided_review.start_detail", bundle: .oust)
                    .font(Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var startButton: some View {
        Button { model.startGuidedReview() } label: {
            Label { Text("guided_review.start", bundle: .oust) } icon: { Image(systemName: "arrow.right") }
        }
        .buttonStyle(OnGradientButtonStyle())
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
