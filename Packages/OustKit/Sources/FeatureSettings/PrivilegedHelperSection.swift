import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Le démon privilégié, à installer ou non (docs/adr/0001).
///
/// Ce qu'il peut faire et ce qu'il ne peut pas faire sont écrits **avant** le
/// bouton : on demande d'installer un composant qui tourne en root, la moindre
/// des choses est de dire exactement quoi avant de rien déclencher. Sans lui,
/// Oust! fait tout comme avant, mot de passe compris.
struct PrivilegedHelperSection: View {
    @State private var helper = PrivilegedHelperModel()
    @State private var showsDetails = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $showsDetails) {
                details.padding(.top, Spacing.small)
            } label: {
                HStack {
                    Text("helper.title", bundle: .oust)
                    Spacer()
                    HStack(spacing: Spacing.tight) {
                        if helper.isBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: symbol)
                        }
                        Text(badgeKey, bundle: .oust)
                    }
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(badgeTint)
                    .padding(.horizontal, Spacing.small)
                    .padding(.vertical, Spacing.tight)
                    .background(badgeTint.opacity(0.12), in: Capsule())
                }
            }
        }
        .disabled(helper.isBusy)
        .task { await helper.refresh() }
        // L'approbation se donne dans Réglages Système : on relit l'état au retour.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await helper.refresh() }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(stateKey, bundle: .oust)
                .fixedSize(horizontal: false, vertical: true)
            Label { Text("helper.can", bundle: .oust) } icon: { Image(systemName: "checkmark.circle") }
            Label { Text("helper.cannot", bundle: .oust) } icon: { Image(systemName: "nosign") }
            if let notice = helper.updateNotice {
                Text(LocalizedStringKey(notice), bundle: .oust).foregroundStyle(.secondary)
            }
            if let issue = helper.installationIssue {
                Label { Text(LocalizedStringKey(issue), bundle: .oust) } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
            if helper.needsStableLocation {
                Text("helper.stable_location", bundle: .oust).foregroundStyle(.secondary)
            }
            if helper.isDevelopmentBuild, !helper.isInstalled {
                Label { Text("helper.development_build", bundle: .oust) } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.secondary)
            }
            // L'échec d'une tentative passée ne reste pas à côté d'un démon
            // qui répond : l'écran se contredirait (leçon de Tacho).
            if let failure = helper.failure, !isActive {
                Label { Text(verbatim: L10n.string("helper.failure", failure)) } icon: {
                    Image(systemName: "xmark.circle")
                }
                .foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.small) { actions }
            Text("helper.footer", bundle: .oust).font(Typography.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        switch helper.state {
        case .notInstalled:
            Button { Task { await helper.install() } } label: { Text("helper.install", bundle: .oust) }
                .disabled(helper.installationIssue != nil)
            if helper.failure != nil {
                Button { helper.openSystemSettings() } label: { Text("access.open", bundle: .oust) }
            }
        case .awaitingApproval:
            Button { helper.openSystemSettings() } label: { Text("access.open", bundle: .oust) }
            Button(role: .destructive) { Task { await helper.uninstall() } } label: {
                Text("helper.uninstall", bundle: .oust)
            }
        case .active:
            if helper.updateNotice != nil {
                Button { Task { await helper.reinstall() } } label: { Text("helper.reinstall", bundle: .oust) }
                    .disabled(helper.installationIssue != nil)
            }
            Button(role: .destructive) { Task { await helper.uninstall() } } label: {
                Text("helper.uninstall", bundle: .oust)
            }
        case .unresponsive:
            Button { Task { await helper.reinstall() } } label: { Text("helper.reinstall", bundle: .oust) }
                .disabled(helper.installationIssue != nil)
            Button(role: .destructive) { Task { await helper.uninstall() } } label: {
                Text("helper.uninstall", bundle: .oust)
            }
        }
    }

    private var isActive: Bool {
        if case .active = helper.state { return true }
        return false
    }

    private var badgeKey: LocalizedStringKey {
        if helper.isBusy { return "helper.badge.checking" }
        if isActive, helper.updateNotice != nil || helper.installationIssue != nil { return "helper.badge.repair" }
        return switch helper.state {
        case .notInstalled: "helper.badge.not_installed"
        case .awaitingApproval: "helper.badge.awaiting_approval"
        case .active: "helper.badge.active"
        case .unresponsive: "helper.badge.repair"
        }
    }

    private var badgeTint: Color {
        if helper.isBusy { return .secondary }
        if isActive, helper.updateNotice != nil || helper.installationIssue != nil { return Palette.color(for: .review) }
        return tint
    }

    private var stateKey: LocalizedStringKey {
        switch helper.state {
        case .notInstalled: "helper.state.not_installed"
        case .awaitingApproval: "helper.state.awaiting_approval"
        case .active: "helper.state.active"
        case .unresponsive: "helper.state.unresponsive"
        }
    }

    private var symbol: String {
        switch helper.state {
        case .notInstalled: "key"
        case .awaitingApproval: "hourglass"
        case .active: "checkmark.shield.fill"
        case .unresponsive: "exclamationmark.shield"
        }
    }

    private var tint: Color {
        switch helper.state {
        case .notInstalled: .secondary
        case .awaitingApproval, .unresponsive: Palette.color(for: .review)
        case .active: Palette.color(for: .safe)
        }
    }
}
