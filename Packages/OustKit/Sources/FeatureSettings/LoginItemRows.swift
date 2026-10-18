import SwiftUI
import OustDesignSystem
import OustLocalization
import OustModel
import OustWatch

/// Sous « Ouvrir Oust! à la connexion » : l'accord que macOS attend, ou ce qu'il
/// a refusé et quoi faire. Avant, un refus faisait revenir l'interrupteur en
/// arrière sans un mot (18/10/2026).
struct LoginItemRows: View {
    let watch: WatchModel

    var body: some View {
        if watch.loginItem == .requiresApproval {
            row(opensSettings: true) {
                Text("settings.watch.login_approval", bundle: .oust)
            }
        } else if let notice = watch.loginItemNotice {
            row(opensSettings: notice != .invalidSignature) {
                message(notice)
            }
        }
    }

    @ViewBuilder
    private func message(_ notice: LoginItemNotice) -> some View {
        switch notice {
        case .deniedByUser: Text("settings.login.denied", bundle: .oust)
        case .invalidSignature: Text("settings.login.invalid_signature", bundle: .oust)
        case .notKept: Text("settings.login.not_kept", bundle: .oust)
        case .notRemoved: Text("settings.login.not_removed", bundle: .oust)
        case .failed(let reason): Text(verbatim: L10n.string("settings.login.failed", reason))
        }
    }

    private func row(opensSettings: Bool, @ViewBuilder text: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.color(for: .review))
            text().fixedSize(horizontal: false, vertical: true)
            Spacer()
            if opensSettings {
                Button { watch.openLoginItemsSettings() } label: { Text("settings.watch.open_settings", bundle: .oust) }
            }
        }
    }
}
