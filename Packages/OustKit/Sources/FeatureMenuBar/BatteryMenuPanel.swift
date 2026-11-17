import AppKit
import SwiftUI
import OustDesignSystem
import OustLocalization
import OustModel
import OustWatch

struct BatteryMenuPanel: View {
    private struct PowerSample: Equatable {
        let expanded: Bool
        let source: BatteryReading.State?
        let presented: Bool
    }

    let watch: WatchModel
    let presented: Bool
    let batteryPresentedAt: ContinuousClock.Instant
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var health: BatterySummary?
    @State private var diagnostics: BatteryDiagnostics?
    @State private var showsEnergy = true
    @State private var showsCharger = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if let battery = watch.battery {
                charge(battery).batteryCard()
            } else {
                Text("menubar.battery_unavailable", bundle: .oust).foregroundStyle(.secondary)
            }
            peripherals
            VStack(alignment: .leading, spacing: Spacing.small) {
                DisclosureGroup(isExpanded: $showsEnergy) {
                    energy.padding(.top, Spacing.small)
                } label: { Text("menubar.battery_energy", bundle: .oust).font(Typography.headline) }
            }
            .batteryCard()
            if watch.battery != nil {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("menubar.battery_health", bundle: .oust).font(Typography.headline)
                    healthDetails
                }
                .batteryCard()
            }
        }
        .task(id: presented) {
            guard presented else { return }
            let current = await BatterySummary.read()
            guard !Task.isCancelled else { return }
            health = current
        }
        .task(id: presented) {
            guard presented else { return }
            while !Task.isCancelled {
                await watch.refreshBatteryDevices(since: batteryPresentedAt)
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .task(id: PowerSample(expanded: showsEnergy, source: watch.battery?.state, presented: presented)) {
            diagnostics = nil
            guard presented else { return }
            repeat {
                let readings = await BatteryDiagnostics.read()
                guard !Task.isCancelled else { return }
                diagnostics = readings
                do { try await Task.sleep(for: .seconds(showsEnergy ? 2 : 15)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private func charge(_ battery: BatteryReading) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Image(systemName: battery.symbol).font(.title2)
                Text(verbatim: L10n.string("menubar.battery_percent", Formatters.count(battery.level)))
                    .font(Typography.title.monospacedDigit())
                Spacer()
                Text(LocalizedStringKey(battery.state.localizationKey), bundle: .oust)
                    .font(Typography.body)
            }
            .foregroundStyle(levelColor(battery.level))
            BatteryLevelBar(level: battery.level, color: levelColor(battery.level),
                            shimmering: presented && battery.state == .charging && !reduceMotion)
                .accessibilityLabel(Text("menubar.battery", bundle: .oust))
            if let minutes = battery.minutes {
                let key = battery.state == .charging ? "menubar.battery_until_full" : "menubar.battery_remaining"
                Text(verbatim: L10n.string(key, Formatters.count(minutes)))
                    .font(Typography.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var peripherals: some View {
        let fresh = watch.hasFreshBatteryDevices(since: batteryPresentedAt)
        let devices = fresh
            ? watch.orderedBatteryDevices.filter { $0.connected && watch.batteryPreference(for: $0.id).shown }
            : []
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("menubar.battery_devices", bundle: .oust).font(Typography.headline)
            if !devices.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Spacing.small)], spacing: Spacing.small) {
                    ForEach(devices) { device in
                        let alias = watch.batteryPreference(for: device.id).alias
                        VStack(alignment: .leading, spacing: Spacing.hair) {
                            Text(verbatim: alias.isEmpty ? device.name : alias).lineLimit(2).font(Typography.caption)
                            if let level = device.level {
                                Text(verbatim: L10n.string("menubar.battery_percent", Formatters.count(level)))
                                    .font(Typography.headline.monospacedDigit()).foregroundStyle(levelColor(level))
                                BatteryLevelBar(level: level, color: levelColor(level), shimmering: false)
                                    .accessibilityHidden(true)
                            } else {
                                Text("menubar.battery_device_level_unknown", bundle: .oust)
                                    .font(Typography.caption).foregroundStyle(.secondary)
                            }
                        }
                        .batteryCard()
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Text("menubar.battery_devices_unavailable", bundle: .oust)
                    .font(Typography.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func levelColor(_ level: Int) -> Color {
        switch level {
        case ...10: .red
        case ...20: .orange
        case ...40: .yellow
        default: .green
        }
    }

    private var healthDetails: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let percent = health?.maximumCapacity {
                Text(verbatim: L10n.string("menubar.battery_capacity", Formatters.count(percent)))
            }
            if let cycles = health?.cycleCount {
                Text(verbatim: L10n.string("menubar.battery_cycles", Formatters.count(cycles)))
            }
            if let temperature = diagnostics?.temperature {
                Text(verbatim: L10n.string("menubar.battery_temperature", decimal(temperature)))
            } else {
                Text("menubar.battery_temperature_unavailable", bundle: .oust)
                    .foregroundStyle(.secondary)
                Text(verbatim: L10n.string("menubar.mac_thermal_state", thermalState))
            }
        }
        .monospacedDigit()
    }

    @ViewBuilder private var energy: some View {
        let diagnostics = self.diagnostics.flatMap { $0.source == watch.battery?.state ? $0 : nil }
        if watch.battery?.state == .onBattery {
            if let watts = diagnostics?.batteryWatts {
                Text(verbatim: L10n.string("menubar.battery_net_discharge_estimate", decimal(watts)))
                    .monospacedDigit()
            } else {
                Text("menubar.battery_energy_on_battery", bundle: .oust)
                    .foregroundStyle(.secondary)
            }
        } else if watch.battery != nil, let diagnostics,
                  diagnostics.nominalWatts != nil || diagnostics.inputPower != nil || diagnostics.batteryWatts != nil {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.tight) {
                    if let nominal = diagnostics.nominalWatts {
                        chargerButton(nominal)
                    } else {
                        Label {
                            Text("menubar.battery_charger_unknown", bundle: .oust)
                        } icon: { Image(systemName: "powerplug.fill") }
                    }
                    if case let .measured(watts)? = diagnostics.inputPower {
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: L10n.string("menubar.battery_watts", decimal(watts)))
                                .font(Typography.headline).foregroundStyle(.green)
                            Text("menubar.battery_input_caption", bundle: .oust).font(Typography.caption)
                        }
                        .padding(Spacing.small)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.small))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: L10n.string("menubar.battery_input_power", decimal(watts))))
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                        Image(systemName: "laptopcomputer").accessibilityHidden(true)
                    }
                }
                if case let .estimated(watts)? = diagnostics.inputPower {
                    Text(verbatim: L10n.string("menubar.battery_input_estimate", decimal(watts)))
                } else if diagnostics.inputPower == nil {
                    Text("menubar.battery_input_unknown", bundle: .oust).foregroundStyle(.secondary)
                }
                if let watts = diagnostics.macWatts {
                    Text(verbatim: L10n.string("menubar.battery_mac_power", decimal(watts)))
                        .font(Typography.caption)
                }
                if showsCharger, let nominal = diagnostics.nominalWatts {
                    Text(verbatim: L10n.string("menubar.battery_charger_nominal", Formatters.count(nominal)))
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
                if watch.battery?.state == .charging, let watts = diagnostics.batteryWatts {
                    Text(verbatim: L10n.string("menubar.battery_net_charge_estimate", decimal(watts)))
                }
            }
            .monospacedDigit()
        } else {
            Text("menubar.battery_energy_unavailable", bundle: .oust).foregroundStyle(.secondary)
        }
    }

    private func chargerButton(_ nominal: Int) -> some View {
        Button { showsCharger.toggle() } label: {
            Label {
                Text(verbatim: L10n.string("menubar.battery_charger", Formatters.count(nominal)))
            } icon: { Image(systemName: "powerplug.fill") }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityValue(showsCharger ? Text("menubar.battery_charger_details_open", bundle: .oust)
                                          : Text("menubar.battery_charger_details_closed", bundle: .oust))
    }

    private func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: L10n.string("menubar.mac_thermal_nominal")
        case .fair: L10n.string("menubar.mac_thermal_fair")
        case .serious: L10n.string("menubar.mac_thermal_serious")
        case .critical: L10n.string("menubar.mac_thermal_critical")
        @unknown default: L10n.string("menubar.mac_thermal_unknown")
        }
    }
}

private struct BatteryLevelBar: View {
    let level: Int
    let color: Color
    let shimmering: Bool

    var body: some View {
        GeometryReader { proxy in
            let fill = proxy.size.width * Double(level) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .overlay {
                        if shimmering, fill > 0 {
                            TimelineView(.animation(minimumInterval: 1.0 / 24)) { timeline in
                                let progress = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                                let highlight = min(50, fill / 2)
                                LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: highlight)
                                    .position(x: -highlight + (fill + 2 * highlight) * progress, y: proxy.size.height / 2)
                            }
                            .clipShape(Capsule())
                        }
                    }
                    .frame(width: fill)
            }
        }
        .frame(height: 7)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: L10n.string("menubar.battery_percent", Formatters.count(level))))
    }
}

private extension View {
    func batteryCard() -> some View {
        self.padding(Spacing.small + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.small + 3))
    }
}
