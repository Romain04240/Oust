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

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(stateKey, bundle: .oust)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                actions
            }
            Label { Text("helper.can", bundle: .oust) } icon: { Image(systemName: "checkmark.circle") }
            Label { Text("helper.cannot", bundle: .oust) } icon: { Image(systemName: "nosign") }
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
        } header: {
            Text("helper.title", bundle: .oust)
        } footer: {
            Text("helper.footer", bundle: .oust)
        }
        .disabled(helper.isWorking)
        .task { await helper.refresh() }
        // L'approbation se donne dans Réglages Système : on relit l'état au retour.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await helper.refresh() }
        }
    }

    @ViewBuilder private var actions: some View {
        switch helper.state {
        case .notInstalled:
            Button { Task { await helper.install() } } label: { Text("helper.install", bundle: .oust) }
        case .awaitingApproval:
            Button { helper.openSystemSettings() } label: { Text("access.open", bundle: .oust) }
            Button(role: .destructive) { Task { await helper.uninstall() } } label: {
                Text("helper.uninstall", bundle: .oust)
            }
        case .active:
            Button(role: .destructive) { Task { await helper.uninstall() } } label: {
                Text("helper.uninstall", bundle: .oust)
            }
        case .unresponsive:
            Button { Task { await helper.reinstall() } } label: { Text("helper.reinstall", bundle: .oust) }
            Button(role: .destructive) { Task { await helper.uninstall() } } label: {
                Text("helper.uninstall", bundle: .oust)
            }
        }
    }

    private var isActive: Bool {
        if case .active = helper.state { return true }
        return false
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
