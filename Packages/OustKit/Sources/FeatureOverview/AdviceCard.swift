import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Le plan reste en haut ; chaque piste déploie ses éléments et ses actions
/// juste dessous, pour ne pas perdre le contexte dans une autre fenêtre.
public struct AdviceView: View {
    let model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        SectionScaffold(.advice, subtitle: "advice.subtitle") {
            Button { Task { await model.refreshAdvice() } } label: {
                HStack(spacing: Spacing.small) {
                    if model.adviceSearch.isRunning { ProgressView().controlSize(.small).tint(.white) }
                    Text("advice.refresh", bundle: .oust)
                }
            }
            .buttonStyle(OnGradientButtonStyle())
            .disabled(model.adviceSearch.isRunning || model.archive.search.isRunning)
        } content: {
            GlassCard {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    HStack {
                        Label { Text("advice.plan_title", bundle: .oust) } icon: { Image(systemName: "lightbulb.fill") }
                            .font(Typography.headline)
                        Spacer()
                        ContextHelpButton("advice.plan_detail")
                    }
                    if model.adviceSearch.isRunning {
                        Label { Text("advice.searching", bundle: .oust) } icon: { ProgressView().controlSize(.small).tint(.white) }
                    } else if !model.storageAdvice.isEmpty {
                        Text(verbatim: L10n.string("advice.count", Formatters.count(model.storageAdvice.count)))
                            .font(Typography.headline.monospacedDigit())
                    }
                    if case .done(let date) = model.adviceSearch {
                        Text(verbatim: L10n.string("advice.updated", Formatters.relative(date)))
                            .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
                    }
                }
                .foregroundStyle(Palette.onGradient)
            }
            if model.adviceSearch.hasRun, model.storageAdvice.isEmpty, !model.adviceSearch.isRunning {
                GlassCard {
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        Text("advice.none", bundle: .oust).foregroundStyle(Palette.onGradient)
                        if let boot = model.bootVolume {
                            Button {
                                Task {
                                    await model.analyze(boot)
                                    await model.refreshAdvice()
                                }
                            } label: { Text(model.analysis.isRunning ? "overview.analyzing" : "overview.analyze", bundle: .oust) }
                            .buttonStyle(OnGradientButtonStyle())
                            .disabled(model.analysis.isRunning || model.adviceSearch.isRunning)
                        }
                    }
                }
            }
            ForEach(model.storageAdvice) { advice in AdviceActionCard(model: model, advice: advice) }
        }
        .task { if !model.adviceSearch.hasRun { await model.refreshAdvice() } }
    }
}

private struct AdviceActionCard: View {
    let model: AppModel
    let advice: StorageAdvice
    @State private var expanded = false
    @State private var showAll = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var actionSection: AppSection { advice.url != nil && advice.destination != .archive ? .transfer : advice.destination }
    private var symbol: String { actionSection == .system ? "cloud" : actionSection.symbol }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { expanded.toggle() }
                } label: {
                    HStack(alignment: .center, spacing: Spacing.medium) {
                        Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.small))
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(verbatim: advice.title).font(Typography.headline).multilineTextAlignment(.leading)
                            Text(verbatim: advice.detail).font(Typography.caption)
                                .multilineTextAlignment(.leading).lineLimit(expanded ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Spacing.small)
                        VStack(alignment: .trailing, spacing: Spacing.tight) {
                            Text(verbatim: Formatters.bytes(advice.bytes)).font(Typography.size).monospacedDigit()
                            Label { Text(expanded ? "advice.collapse" : "advice.action_details", bundle: .oust) } icon: {
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            }.font(Typography.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    Divider().overlay(.white.opacity(0.15))
                    if let url = advice.url { fileActions(url) } else { cleanupActions }
                }
            }
            .foregroundStyle(Palette.onGradient)
        }
    }

    @ViewBuilder private func fileActions(_ url: URL) -> some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let current = exists && (advice.destination != .archive || model.archive.candidates.contains { $0.id == advice.id })
        Text(verbatim: url.path).font(Typography.caption).textSelection(.enabled)
        if !current { Text("advice.stale", bundle: .oust).font(Typography.caption) }
        HStack(spacing: Spacing.medium) {
            if model.canMoveFiles && advice.destination == .archive {
                Button {
                    model.searchText = ""
                    model.archive.dismissReport()
                    model.archive.chosen = []
                    model.archive.focusedProjectID = advice.id
                    model.section = .archive
                } label: { Text("advice.prepare_archive", bundle: .oust) }
                .buttonStyle(PrimaryButtonStyle(section: .archive))
                .disabled(!current || model.archive.running == .running)
            } else if model.canMoveFiles {
                Button {
                    model.transfer.present(sources: [url])
                    model.searchText = ""
                    model.section = .transfer
                } label: { Text("advice.prepare_transfer", bundle: .oust) }
                .buttonStyle(PrimaryButtonStyle(section: .transfer))
                .disabled(!current || model.transfer.isRunning)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Text("row.reveal", bundle: .oust) }
                .buttonStyle(OnGradientButtonStyle()).disabled(!exists)
        }
    }

    @ViewBuilder private var cleanupActions: some View {
        let items = model.items(for: advice)
        if items.isEmpty {
            Text("advice.stale", bundle: .oust)
        } else {
            Text("advice.choose_items", bundle: .oust).font(Typography.caption)
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(showAll ? items.count : 5))) { item in
                    ItemRow(item, enabled: model.canSelectForCleanup(item), isSelected: model.isInCart(item.id), showOwner: true) { model.toggle(item) }
                        .padding(.vertical, Spacing.small)
                    Divider().opacity(0.2)
                }
            }
            if items.count > 5 {
                Button { showAll.toggle() } label: {
                    Text(showAll ? "advice.show_less_items" : "advice.show_all_items", bundle: .oust)
                }.buttonStyle(OnGradientButtonStyle())
            }
            Button {
                model.searchText = ""
                model.section = .cart
            } label: { Text("advice.open_cart", bundle: .oust) }
            .buttonStyle(PrimaryButtonStyle(section: .cart))
            .disabled(!items.contains { model.isInCart($0.id) })
        }
    }
}
