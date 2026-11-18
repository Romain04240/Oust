import AppKit
import SwiftUI
import OustLocalization
import OustModel
import OustWatch

struct BatterySettingsTab: View {
    @Bindable var watch: WatchModel
    @State private var batteryTabOpenedAt: ContinuousClock.Instant?

    var body: some View {
        SettingsForm {
            Picker(selection: $watch.settings.batteryPercentageStyle) {
                Text("settings.battery.percent_beside", bundle: .oust).tag(WatchSettings.BatteryPercentageStyle.beside)
                Text("settings.battery.percent_inside", bundle: .oust).tag(WatchSettings.BatteryPercentageStyle.inside)
            } label: {
                Text("settings.battery.percent_position", bundle: .oust)
            }
            Picker(selection: $watch.settings.batteryTemperatureUnit) {
                Text("settings.battery.celsius", bundle: .oust).tag(WatchSettings.TemperatureUnit.celsius)
                Text("settings.battery.fahrenheit", bundle: .oust).tag(WatchSettings.TemperatureUnit.fahrenheit)
            } label: {
                Text("menubar.battery_temperature_short", bundle: .oust)
            }
            Section {
                Toggle(isOn: $watch.settings.batteryAlerts.warnsLow) {
                    Text("settings.watch.battery_low", bundle: .oust)
                }
                Stepper(value: $watch.settings.batteryAlerts.low, in: 1...(watch.settings.batteryAlerts.high - 1)) {
                    Text(verbatim: L10n.string("settings.watch.battery_low_level", Formatters.count(watch.settings.batteryAlerts.low)))
                }
                .disabled(!watch.settings.batteryAlerts.warnsLow)
                Toggle(isOn: $watch.settings.batteryAlerts.warnsCharged) {
                    Text("settings.watch.battery_charged", bundle: .oust)
                }
                Stepper(value: $watch.settings.batteryAlerts.high, in: (watch.settings.batteryAlerts.low + 1)...100) {
                    Text(verbatim: L10n.string("settings.watch.battery_charged_level", Formatters.count(watch.settings.batteryAlerts.high)))
                }
                .disabled(!watch.settings.batteryAlerts.warnsCharged)
            } header: {
                Text("settings.watch.battery_section", bundle: .oust)
            }
            Section {
                let devices = watch.orderedBatteryDevices
                if devices.isEmpty {
                    Text(watch.batteryDevices == nil ? "settings.battery.devices_unavailable" : "settings.battery.devices_empty",
                         bundle: .oust)
                        .foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    deviceRow(device, first: devices.first?.id == device.id, last: devices.last?.id == device.id)
                }
            } header: {
                Text("menubar.battery_devices", bundle: .oust)
            }
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("menubar.battery_system_settings", bundle: .oust)
            }
        }
        .task {
            let opened = ContinuousClock.now
            batteryTabOpenedAt = opened
            defer {
                if batteryTabOpenedAt == opened { batteryTabOpenedAt = nil }
            }
            while !Task.isCancelled {
                await watch.refreshBatteryDevices(since: opened)
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .onDisappear { batteryTabOpenedAt = nil }
    }

    private func deviceRow(_ device: BatteryDevice, first: Bool, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: preference(device.id, \.shown)) { Text(verbatim: device.name) }
                    .toggleStyle(.checkbox)
                Spacer()
                if !watch.hasFreshBatteryDevices(since: batteryTabOpenedAt) {
                    Text("menubar.battery_device_level_unknown", bundle: .oust).foregroundStyle(.secondary)
                } else if let level = device.level {
                    Text(verbatim: L10n.string("menubar.battery_percent", Formatters.count(level))).monospacedDigit()
                } else {
                    Text(device.connected ? "menubar.battery_device_level_unknown" : "settings.battery.offline", bundle: .oust)
                        .foregroundStyle(.secondary)
                }
                Button { watch.moveBatteryDevice(device.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(first)
                    .accessibilityLabel(Text("settings.battery.move_up", bundle: .oust))
                Button { watch.moveBatteryDevice(device.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(last)
                    .accessibilityLabel(Text("settings.battery.move_down", bundle: .oust))
            }
            TextField(text: preference(device.id, \.alias), prompt: Text(verbatim: device.name)) {
                Text("settings.battery.alias", bundle: .oust)
            }
            let threshold = preference(device.id, \.threshold)
            Toggle(isOn: Binding(get: { threshold.wrappedValue != nil }, set: { threshold.wrappedValue = $0 ? 20 : nil })) {
                Text("settings.battery.device_alert", bundle: .oust)
            }
            if let level = threshold.wrappedValue {
                Stepper(value: Binding(get: { threshold.wrappedValue ?? 20 }, set: { threshold.wrappedValue = $0 }), in: 1...99) {
                    Text(verbatim: L10n.string("settings.watch.battery_low_level", Formatters.count(level)))
                }
            }
        }
    }

    private func preference<Value>(_ id: String, _ field: WritableKeyPath<BatteryDevicePreference, Value>) -> Binding<Value> {
        Binding(get: { watch.batteryPreference(for: id)[keyPath: field] }, set: { value in
            var updated = watch.batteryPreference(for: id)
            updated[keyPath: field] = value
            watch.setBatteryPreference(updated)
        })
    }
}
