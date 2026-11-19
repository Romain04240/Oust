import ServiceManagement
import SwiftUI
import OustDesignSystem
import OustLocalization
import OustModel

struct LoginDiagnosticsCard: View {
    @State private var revision = 0
    @State private var snapshot: LoginDiagnostics.SessionSnapshot?
    @State private var showsInventory = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let read: @Sendable () async -> LoginDiagnostics.SessionSnapshot

    init() { read = { await LoginDiagnostics.readSession() } }

    init(read: @escaping @Sendable () async -> LoginDiagnostics.SessionSnapshot) { self.read = read }

    var body: some View {
        ItemGroup(title: L10n.string("system.login_diagnostics_title"), symbol: "person.badge.clock",
                  tint: .blue, total: 0) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.small) {
                    Text("system.login_diagnostics_scope", bundle: .oust)
                        .font(Typography.caption).foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.small)
                    ContextHelpButton("system.login_diagnostics_help")
                }
                switch snapshot?.diagnostic {
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
                inventory
                HStack {
                    Button {
                        SMAppService.openSystemSettingsLoginItems()
                    } label: {
                        Text("system.login_diagnostics_settings", bundle: .oust)
                    }
                    Button {
                        snapshot = nil
                        revision += 1
                    } label: {
                        Text("system.login_diagnostics_refresh", bundle: .oust)
                    }
                    .disabled(snapshot == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: revision) {
            snapshot = nil
            let checked = await read()
            guard !Task.isCancelled else { return }
            snapshot = checked
        }
    }

    @ViewBuilder private var inventory: some View {
        if let inventory = snapshot?.inventory {
            Divider()
            HStack(alignment: .top, spacing: Spacing.small) {
                Group {
                    switch inventory {
                    case .unavailable:
                        Text("system.login_inventory_unavailable", bundle: .oust)
                            .font(Typography.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .partial(let entries):
                        DisclosureGroup(isExpanded: $showsInventory) {
                            if entries.isEmpty {
                                Text("system.login_inventory_empty", bundle: .oust)
                                    .font(Typography.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                LazyVStack(alignment: .leading, spacing: Spacing.small) {
                                    ForEach(entries) { entry in
                                        inventoryRow(entry)
                                        Divider().opacity(0.25)
                                    }
                                }
                                .padding(.top, Spacing.small)
                            }
                        } label: {
                            Text(verbatim: L10n.string("system.login_inventory_count", Formatters.count(entries.count)))
                                .font(Typography.body.weight(.semibold).monospacedDigit())
                        }
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsInventory)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ContextHelpButton("system.login_inventory_help")
            }
        }
    }

    private func inventoryRow(_ entry: LoginSessionInventory.Entry) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            Image(systemName: entry.kind == .application ? "app" : "gearshape.2")
                .font(Typography.body).foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(verbatim: entry.name).font(Typography.body.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(Text(verbatim: entry.name))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.small) {
                        kind(entry)
                        enabled(entry)
                        allowed(entry)
                    }
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        kind(entry)
                        enabled(entry)
                        allowed(entry)
                    }
                }
                .font(Typography.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func kind(_ entry: LoginSessionInventory.Entry) -> some View {
        Text(entry.kind == .application ? "system.login_inventory_application" : "system.login_inventory_component", bundle: .oust)
    }

    private func enabled(_ entry: LoginSessionInventory.Entry) -> some View {
        let key = entry.isEnabled.map { $0 ? "system.login_inventory_enabled" : "system.login_inventory_disabled" }
            ?? "system.login_inventory_enabled_unknown"
        return Text(LocalizedStringKey(key), bundle: .oust)
    }

    private func allowed(_ entry: LoginSessionInventory.Entry) -> some View {
        let key = entry.isAllowed.map { $0 ? "system.login_inventory_allowed" : "system.login_inventory_disallowed" }
            ?? "system.login_inventory_allowed_unknown"
        return Text(LocalizedStringKey(key), bundle: .oust)
    }
}
