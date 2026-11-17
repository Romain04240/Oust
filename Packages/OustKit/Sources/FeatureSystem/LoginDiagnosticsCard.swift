import ServiceManagement
import SwiftUI
import OustDesignSystem
import OustLocalization
import OustModel

struct LoginDiagnosticsCard: View {
    @State private var revision = 0
    @State private var result: LoginDiagnostics.Result?

    var body: some View {
        ItemGroup(title: L10n.string("system.login_diagnostics_title"), symbol: "person.badge.clock",
                  tint: .blue, total: 0) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("system.login_diagnostics_detail", bundle: .oust)
                    .font(Typography.caption).foregroundStyle(.secondary)
                switch result {
                case nil:
                    Label {
                        Text("system.login_diagnostics_checking", bundle: .oust)
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                case .unavailable:
                    Text("system.login_diagnostics_unavailable", bundle: .oust)
                case .checked(volumeIndeterminate: let findings):
                    if findings.isEmpty {
                        Text("system.login_diagnostics_empty", bundle: .oust)
                    }
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(verbatim: finding.name).font(Typography.headline)
                            Text("system.login_diagnostics_indeterminate", bundle: .oust)
                                .font(Typography.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button {
                        SMAppService.openSystemSettingsLoginItems()
                    } label: {
                        Text("system.login_diagnostics_settings", bundle: .oust)
                    }
                    Button {
                        result = nil
                        revision += 1
                    } label: {
                        Text("system.login_diagnostics_refresh", bundle: .oust)
                    }
                    .disabled(result == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: revision) {
            result = nil
            let checked = await LoginDiagnostics.scan()
            guard !Task.isCancelled else { return }
            result = checked
        }
    }
}
