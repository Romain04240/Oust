import AppKit
import SwiftUI
import OustDesignSystem
import OustLocalization
import OustModel
import OustWatch

struct BatteryMenuPanel: View {
    private struct PowerSample: Equatable {
        let source: BatteryReading.State?
        let presented: Bool
        let cycle: Int
    }

    let watch: WatchModel
    let navigation: MenuBarNavigation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsCharger = false
    @State private var showsAllDevices = false
    @State private var contentHeight: CGFloat = 325
    @State private var devicesRead = false
    @State private var diagnosticsRead = false

    private var presented: Bool { navigation.presented }
    private var diagnostics: BatteryDiagnostics? {
        guard let read = navigation.batteryDiagnosticsReadAt, ContinuousClock.now - read <= .seconds(10),
              navigation.batteryDiagnosticsCycle == watch.batteryAlertCycle,
              let sample = navigation.batteryDiagnostics, sample.source == watch.battery?.state else { return nil }
        return sample
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let battery = watch.battery {
                    charge(battery)
                } else {
                    Label { Text("menubar.battery_unavailable", bundle: .oust) } icon: {
                        Image(systemName: "batteryblock.slash")
                    }
                    .foregroundStyle(.secondary)
                    .batteryCard()
                }
                peripherals
                if let battery = watch.battery {
                    section("menubar.battery_energy", symbol: "bolt.fill", tint: .blue) { energy(battery) }
                    section("menubar.battery_health", symbol: "heart.fill", tint: .pink) { healthDetails }
                    if let diagnostics, diagnostics.batteryVoltage != nil || diagnostics.batteryMilliamps != nil
                        || diagnostics.macWatts != nil || diagnostics.fullMilliampHours != nil
                        || diagnostics.designMilliampHours != nil {
                        detailedReadings(diagnostics)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: max(1, min(contentHeight, navigation.height - 40)))
        .task(id: presented) {
            guard presented else { return }
            if let read = navigation.batteryHealthReadAt, ContinuousClock.now - read < .seconds(300) { return }
            let current = await BatterySummary.read()
            guard !Task.isCancelled else { return }
            navigation.batteryHealth = current
            navigation.batteryHealthReadAt = current == nil ? nil : .now
        }
        .task(id: presented) {
            devicesRead = false
            guard presented else { return }
            while !Task.isCancelled {
                await watch.refreshBatteryDevices(since: navigation.batteryPresentedAt)
                guard !Task.isCancelled else { return }
                devicesRead = true
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .task(id: PowerSample(source: watch.battery?.state, presented: presented, cycle: watch.batteryAlertCycle)) {
            diagnosticsRead = false
            guard presented, watch.battery != nil else { return }
            repeat {
                let cycle = watch.batteryAlertCycle
                let readings = await BatteryDiagnostics.read()
                guard !Task.isCancelled, cycle == watch.batteryAlertCycle else { return }
                navigation.batteryDiagnostics = readings
                navigation.batteryDiagnosticsReadAt = readings == nil ? nil : .now
                navigation.batteryDiagnosticsCycle = cycle
                diagnosticsRead = true
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private func charge(_ battery: BatteryReading) -> some View {
        let color = levelColor(battery.level)
        let stateSymbol = switch battery.state {
        case .charging: "bolt.fill"
        case .charged: "checkmark"
        case .onAC: "powerplug.fill"
        case .onBattery: battery.symbol
        }
        return VStack(alignment: .leading, spacing: Spacing.tight + 2) {
            HStack(alignment: .center, spacing: Spacing.medium) {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text("menubar.battery_current_charge", bundle: .oust)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                    percentage(battery.level)
                        .font(.system(size: 37, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(levelTextColor(battery.level))
                }
                Spacer(minLength: Spacing.tight)
                VStack(alignment: .trailing, spacing: Spacing.tight) {
                    Label {
                        Text(LocalizedStringKey(battery.state.localizationKey), bundle: .oust)
                    } icon: {
                        Image(systemName: stateSymbol).accessibilityHidden(true)
                    }
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(levelTextColor(battery.level))
                    .padding(.horizontal, Spacing.small)
                    .padding(.vertical, Spacing.tight)
                    .background(color.opacity(0.12), in: Capsule())
                    if let minutes = battery.minutes {
                        let key = battery.state == .charging ? "menubar.battery_until_full" : "menubar.battery_remaining"
                        Text(verbatim: L10n.string(key, Formatters.count(minutes)))
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.trailing)
            }
            BatteryLevelBar(level: battery.level, color: levelColor(battery.level),
                            shimmering: presented && battery.state == .charging && !reduceMotion, height: 8)
                .accessibilityHidden(true)
        }
        .batteryCard(tint: color, inset: Spacing.medium)
        .accessibilityElement(children: .combine)
    }

    private var peripherals: some View {
        let fresh = watch.hasFreshBatteryDevices(since: navigation.batteryPresentedAt)
        let readings = fresh ? watch.orderedBatteryDevices : watch.orderedLastKnownBatteryDevices
        let devices = readings.filter { $0.connected && watch.batteryPreference(for: $0.id).shown }
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.small) {
                heading("menubar.battery_devices", symbol: "personalhotspot", tint: .teal)
                Spacer(minLength: 0)
                if !fresh && !devices.isEmpty {
                    Text("menubar.battery_last_reading", bundle: .oust)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                if devices.count > 3 {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { showsAllDevices.toggle() }
                    } label: {
                        Text(showsAllDevices ? "group.show_less" : "group.show_more", bundle: .oust)
                            .font(Typography.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if devices.isEmpty {
                Text(devicesRead || fresh ? "menubar.battery_devices_unavailable" : "menubar.battery_refreshing", bundle: .oust)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .batteryCard()
            } else {
                deviceGrid(showsAllDevices ? devices : Array(devices.prefix(3)))
            }
        }
    }

    private func deviceGrid(_ devices: [BatteryDevice]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 110), spacing: Spacing.tight + 2)]
        return LazyVGrid(columns: columns, spacing: Spacing.tight + 2) {
            ForEach(devices) { device in
                let alias = watch.batteryPreference(for: device.id).alias
                let name = alias.isEmpty ? device.name : alias
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Label {
                        Text(verbatim: name).lineLimit(1).truncationMode(.tail)
                    } icon: {
                        Image(systemName: "personalhotspot")
                            .foregroundStyle(.teal)
                            .accessibilityHidden(true)
                    }
                    .font(Typography.caption)
                    .help(name)
                    if let level = device.level {
                        percentage(level)
                            .font(Typography.headline.monospacedDigit())
                            .foregroundStyle(levelTextColor(level))
                        BatteryLevelBar(level: level, color: levelColor(level), shimmering: false, height: 4)
                            .accessibilityHidden(true)
                    } else {
                        Text("menubar.battery_device_level_unknown", bundle: .oust)
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 45, alignment: .topLeading)
                .batteryCard()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func percentage(_ level: Int) -> Text {
        Text(verbatim: L10n.string("menubar.battery_percent", Formatters.count(level)))
    }

    private func levelColor(_ level: Int) -> Color {
        switch level {
        case ...10: .red
        case ...20: .orange
        case ...40: .yellow
        default: .green
        }
    }

    private func levelTextColor(_ level: Int) -> Color {
        switch level {
        case ...10: colorScheme == .dark ? Color(hex: 0xFF8076) : Color(hex: 0x9D2C24)
        case ...20: colorScheme == .dark ? Color(hex: 0xFFB362) : Color(hex: 0x8E4A08)
        case ...40: colorScheme == .dark ? Color(hex: 0xF3D76E) : Color(hex: 0x775D00)
        default: colorScheme == .dark ? Color(hex: 0x50E495) : Color(hex: 0x17683E)
        }
    }

    private func heading(_ label: String, symbol: String, tint: Color) -> some View {
        Label { Text(LocalizedStringKey(label), bundle: .oust) } icon: {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
        }
        .font(Typography.body.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
    }

    private func section<Content: View>(_ label: String, symbol: String, tint: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            heading(label, symbol: symbol, tint: tint)
            content()
        }
    }

    private var healthDetails: some View {
        HStack(alignment: .top, spacing: Spacing.tight + 2) {
            metric("menubar.battery_capacity_short",
                   value: navigation.batteryHealth?.maximumCapacity.map {
                       L10n.string("menubar.battery_percent", Formatters.count($0))
                   }, symbol: "battery.100percent", tint: .green)
            metric("menubar.battery_cycles_short",
                   value: navigation.batteryHealth?.cycleCount.map { Formatters.count($0) }, symbol: "arrow.clockwise", tint: .indigo)
            metric("menubar.battery_temperature_short", value: diagnostics?.temperature.map {
                let fahrenheit = watch.settings.batteryTemperatureUnit == .fahrenheit
                return L10n.string(fahrenheit ? "menubar.battery_degrees_f" : "menubar.battery_degrees",
                                   decimal(fahrenheit ? $0 * 9 / 5 + 32 : $0))
            }, symbol: "thermometer.medium", tint: .teal)
            .help(L10n.string("menubar.mac_thermal_state", thermalState))
        }
    }

    private func detailedReadings(_ readings: BatteryDiagnostics) -> some View {
        DisclosureGroup {
            VStack(spacing: Spacing.tight + 2) {
                if let voltage = readings.batteryVoltage {
                    detailLine("menubar.battery_voltage", value: L10n.string("menubar.battery_volts", voltage.formatted(.number.precision(.fractionLength(2)))))
                }
                if let current = readings.batteryMilliamps {
                    detailLine("menubar.battery_current",
                               value: L10n.string("menubar.battery_milliamps", Formatters.count(current)))
                }
                if let watts = readings.macWatts {
                    detailLine("menubar.battery_mac_draw",
                               value: L10n.string("menubar.battery_watts", decimal(watts)))
                }
                if let capacity = readings.remainingMilliampHours {
                    detailLine("menubar.battery_remaining_mah",
                               value: L10n.string("menubar.battery_mah", Formatters.count(capacity)))
                }
                if let capacity = readings.fullMilliampHours {
                    detailLine("menubar.battery_full_mah",
                               value: L10n.string("menubar.battery_mah", Formatters.count(capacity)))
                }
                if let capacity = readings.designMilliampHours {
                    detailLine("menubar.battery_design_mah",
                               value: L10n.string("menubar.battery_mah", Formatters.count(capacity)))
                }
            }
            .padding(.top, Spacing.tight)
        } label: {
            Text("menubar.battery_details", bundle: .oust)
                .font(Typography.body.weight(.semibold))
        }
        .batteryCard()
    }

    private func detailLine(_ key: String, value: String) -> some View {
        HStack(spacing: Spacing.small) {
            Text(LocalizedStringKey(key), bundle: .oust).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(verbatim: value).monospacedDigit()
        }
        .font(Typography.caption)
        .accessibilityElement(children: .combine)
    }

    private func metric(_ label: String, value: String?, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Label { Text(LocalizedStringKey(label), bundle: .oust) } icon: {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            }
            .font(Typography.caption)
            .foregroundStyle(.secondary)
            Text(verbatim: value ?? L10n.string("menubar.battery_device_level_unknown"))
                .font(value == nil ? Typography.caption : Typography.headline.monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 39, alignment: .topLeading)
        .batteryCard()
        .accessibilityElement(children: .combine)
    }

    private func energy(_ battery: BatteryReading) -> some View {
        HStack(spacing: Spacing.small) {
            if battery.state == .onBattery {
                Image(systemName: battery.symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("menubar.battery_state.onBattery", bundle: .oust))
            } else if let nominal = diagnostics?.nominalWatts {
                chargerButton(nominal)
            } else {
                Image(systemName: "powerplug.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("menubar.battery_charger_unknown", bundle: .oust))
            }
            flowArrow
            powerReading(battery)
                .frame(maxWidth: .infinity)
            flowArrow
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("menubar.battery_mac_short", bundle: .oust))
        }
        .batteryCard()
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.right")
            .font(Typography.caption)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func powerReading(_ battery: BatteryReading) -> some View {
        if battery.state == .onBattery, let watts = diagnostics?.batteryWatts {
            powerValue(watts, caption: "menubar.battery_battery_estimate_short")
        } else if case let .measured(watts)? = diagnostics?.inputPower {
            powerValue(watts, caption: "menubar.battery_input_caption")
        } else if case let .estimated(watts)? = diagnostics?.inputPower {
            powerValue(watts, caption: "menubar.battery_input_estimated_short")
        } else {
            Text(!diagnosticsRead ? "menubar.battery_refreshing" : battery.state == .onBattery
                 ? "menubar.battery_energy_on_battery" : "menubar.battery_input_unknown", bundle: .oust)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func powerValue(_ watts: Double, caption: String) -> some View {
        HStack(spacing: Spacing.tight + 2) {
            Text(verbatim: L10n.string("menubar.battery_watts", decimal(watts)))
                .font(Typography.headline.monospacedDigit())
                .fixedSize()
            Text(LocalizedStringKey(caption), bundle: .oust)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func chargerButton(_ nominal: Int) -> some View {
        Button { showsCharger.toggle() } label: {
            Label {
                Text(verbatim: L10n.string("menubar.battery_watts", Formatters.count(nominal)))
            } icon: { Image(systemName: "powerplug.fill") }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(Text(verbatim: L10n.string("menubar.battery_charger", Formatters.count(nominal))))
        .popover(isPresented: $showsCharger) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let nominal = diagnostics?.nominalWatts {
                    Text(verbatim: L10n.string("menubar.battery_charger_nominal", Formatters.count(nominal)))
                }
                if let watts = diagnostics?.macWatts {
                    Text(verbatim: L10n.string("menubar.battery_mac_power", decimal(watts)))
                }
                if watch.battery?.state == .charging, let watts = diagnostics?.batteryWatts {
                    Text(verbatim: L10n.string("menubar.battery_net_charge_estimate", decimal(watts)))
                }
            }
            .font(Typography.caption)
            .padding(Spacing.medium)
        }
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
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let fill = proxy.size.width * Double(min(100, max(0, level))) / 100
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
        .frame(height: height)
    }
}

private extension View {
    func batteryCard(tint: Color? = nil, inset: CGFloat = Spacing.small) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.medium)
        return self.padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint?.opacity(0.08) ?? Color.primary.opacity(0.038), in: shape)
            .overlay { shape.strokeBorder(tint?.opacity(0.22) ?? Color.primary.opacity(0.09)).allowsHitTesting(false) }
    }
}
