import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Des caches de navigateurs attendent dans la corbeille, et leur navigateur
/// est ouvert : ils ne partiront pas tant qu'il l'est (SPEC §8). Plutôt que de
/// dire « à quitter d'abord », Oust! propose de le faire (Romain, 18/10/2026) :
/// « Fermer Safari, nettoyer, puis le rouvrir ». La confirmation est celle du
/// vide ordinaire, avec en plus ce qui arrivera au navigateur.
struct BrowserCloseBanner: View {
    let model: AppModel
    /// Relit les navigateurs ouverts quand une application s'ouvre ou se ferme.
    @State private var workspace = RunningAppsWatcher()
    @State private var confirming = false
    @State private var closing = false

    var body: some View {
        // La lecture de `changes` abonne la vue aux ouvertures et fermetures d'applications.
        let open = workspace.changes >= 0 ? model.openBrowsersInCart() : []
        if !open.isEmpty {
            banner(open)
        }
    }

    private func banner(_ open: [OpenBrowser]) -> some View {
        let names = ListFormatter.localizedString(byJoining: open.map(\.name))
        let bytes = Formatters.compactBytes(open.reduce(0) { $0 + $1.bytes })
        let one = open.count == 1
        return VStack(alignment: .leading, spacing: Spacing.small) {
            Label {
                Text(verbatim: L10n.string(one ? "cart.browsers.open_one" : "cart.browsers.open_other", names, bytes))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "globe") }
                .font(Typography.body.weight(.semibold))
            HStack(spacing: Spacing.medium) {
                if closing {
                    ProgressView().controlSize(.small).tint(Palette.onGradient)
                    Text(verbatim: L10n.string("cart.browsers.closing", names)).font(Typography.body)
                } else {
                    Button { confirming = true } label: {
                        Label {
                            Text(verbatim: L10n.string(one ? "cart.browsers.close_one" : "cart.browsers.close_other", names))
                        } icon: { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(OnGradientButtonStyle())
                    .disabled(model.cleaning == .running)
                }
            }
            Text("cart.browsers.politely", bundle: .oust)
                .font(Typography.caption)
                .foregroundStyle(Palette.onGradientSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.onGradient)
        .confirmationDialog(Text(verbatim: L10n.string(one ? "cart.browsers.confirm_title_one" : "cart.browsers.confirm_title_other",
                                                      names)),
                            isPresented: $confirming) {
            Button(role: .destructive) {
                closing = true
                Task {
                    await model.cleanClosingBrowsers()
                    closing = false
                }
            } label: {
                Text(verbatim: L10n.string("cart.browsers.confirm_action", Formatters.compactBytes(model.cartTotal)))
            }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .oust) }
        } message: {
            Text(verbatim: confirmMessage(names: names, one: one))
        }
    }

    /// Le message du vide ordinaire, renforcé s'il le faut (SPEC §6.3), puis ce
    /// qui arrivera au navigateur.
    private func confirmMessage(names: String, one: Bool) -> String {
        let base = model.cartNeedsStrongConfirmation
            ? L10n.string("cart.confirm_strong", Formatters.count(model.cartItems.filter { $0.safety == .review }.count))
            : L10n.string("cart.confirm_message")
        return base + "\n\n" + L10n.string(one ? "cart.browsers.confirm_one" : "cart.browsers.confirm_other", names)
    }
}

/// Compte les ouvertures et fermetures d'applications, pour que la revue sache
/// quand relire les navigateurs ouverts.
@MainActor
@Observable
final class RunningAppsWatcher {
    private(set) var changes = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changes += 1 }
            })
        }
    }

    isolated deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
