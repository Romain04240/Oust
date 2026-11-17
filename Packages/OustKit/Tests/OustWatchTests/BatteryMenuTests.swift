import Foundation
import IOKit.ps
import Testing
@testable import OustWatch

struct BatteryMenuTests {
    @Test("Le nominal et la mesure proviennent du même relevé secteur")
    func adapterSnapshot() throws {
        let input = ["SystemVoltageIn": 20_000, "SystemCurrentIn": 1_500, "SystemPowerIn": 30_000]
        let a: [String: Any] = ["ExternalConnected": true, "AdapterDetails": ["Watts": 73],
                                "PowerTelemetryData": input, "Temperature": 3192]
        let b: [String: Any] = ["ExternalConnected": true, "PowerTelemetryData": input]
        let first = try #require(BatteryDiagnostics.parseSnapshot(pack: nil, battery: a, state: .charging,
                                                                  allowLegacyTemperature: true))
        let second = try #require(BatteryDiagnostics.parseSnapshot(pack: nil, battery: b, state: .charging,
                                                                   allowLegacyTemperature: false))
        #expect(first.nominalWatts == 73)
        #expect(first.temperature == 31.92)
        #expect(second.nominalWatts == nil)
        #expect(second.inputPower == .measured(30))
        #expect(BatteryDiagnostics.parseSnapshot(pack: nil, battery: a, state: .onBattery,
                                                 allowLegacyTemperature: false) == nil)
        let disconnected: [String: Any] = ["ExternalConnected": false, "Voltage": 12_000,
                                            "Amperage": 1_500, "Temperature": 3192]
        let uncertain = try #require(BatteryDiagnostics.parseSnapshot(pack: nil, battery: disconnected,
                                                                      state: .charging, allowLegacyTemperature: true))
        #expect(uncertain.batteryWatts == nil)
        #expect(uncertain.temperature == 31.92)
    }

    @Test("Une alerte différée affiche la charge actuelle ou disparaît")
    func deferredAlert() {
        let settings = BatteryAlertSettings(warnsLow: true, warnsCharged: true)
        let initial = BatteryAlert.charged(.init(level: 80, state: .charging))
        let fresh = BatteryReading(level: 81, state: .onAC)
        #expect(initial.updated(for: fresh, settings: settings) == .charged(fresh))
        #expect(initial.updated(for: .init(level: 82, state: .onBattery), settings: settings) == nil)
        #expect(initial.updated(for: fresh, settings: .init()) == nil)
    }

    @Test("La veille distingue la charge, le secteur sans charge et la batterie")
    func batteryStates() {
        var source: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 79,
            kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: true,
            kIOPSTimeToFullChargeKey: 35,
        ]
        #expect(BatteryReading.parse(source) == .init(level: 79, state: .charging, minutes: 35))
        source[kIOPSIsChargingKey] = false
        #expect(BatteryReading.parse(source) == .init(level: 79, state: .onAC))
        source[kIOPSIsChargedKey] = true
        #expect(BatteryReading.parse(source) == .init(level: 79, state: .charged))
        source[kIOPSPowerSourceStateKey] = kIOPSBatteryPowerValue
        source[kIOPSTimeToEmptyKey] = 65535
        #expect(BatteryReading.parse(source) == .init(level: 79, state: .onBattery))
        #expect(BatteryReading.parse(source, fallbackTimeRemaining: { 61 })?.minutes == 2)
        #expect(BatteryReading.parse(source, fallbackTimeRemaining: { .nan })?.minutes == nil)
        source[kIOPSCurrentCapacityKey] = 29
        #expect(BatteryReading.parse(source)?.level == 29)
        source[kIOPSMaxCapacityKey] = 0
        #expect(BatteryReading.parse(source) == nil)
    }

    @Test("Les alertes respectent le sens du franchissement et se réarment sans doublon")
    func thresholds() {
        var tracker = BatteryAlertTracker()
        let settings = BatteryAlertSettings(warnsLow: true, warnsCharged: true)
        #expect(tracker.observe(.init(level: 21, state: .onBattery), settings: settings) == nil)
        let low = BatteryReading(level: 20, state: .onBattery)
        #expect(tracker.observe(low, settings: settings) == .low(low))
        #expect(tracker.observe(.init(level: 21, state: .onBattery), settings: settings) == nil)
        #expect(tracker.observe(low, settings: settings) == nil)
        #expect(tracker.observe(.init(level: 79, state: .charging), settings: settings) == nil)
        let pausedAtThreshold = BatteryReading(level: 80, state: .onAC)
        #expect(tracker.observe(pausedAtThreshold, settings: settings) == .charged(pausedAtThreshold))
        #expect(tracker.observe(.init(level: 79, state: .charging), settings: settings) == nil)
        #expect(tracker.observe(pausedAtThreshold, settings: settings) == nil)
        #expect(tracker.observe(.init(level: 79, state: .onBattery), settings: settings) == nil)
        #expect(tracker.observe(.init(level: 85, state: .charging), settings: settings) == nil)
        #expect(tracker.observe(.init(level: 21, state: .onBattery), settings: settings) == nil)
        #expect(tracker.observe(low, settings: settings) == .low(low))
    }

    @Test("Une reprise sans mesure précédente n'invente pas de franchissement")
    func wakeBaseline() {
        var tracker = BatteryAlertTracker()
        let settings = BatteryAlertSettings(warnsLow: true, warnsCharged: true)
        #expect(tracker.observe(.init(level: 79, state: .charging), settings: settings) == nil)
        tracker.resetBaseline()
        #expect(tracker.observe(.init(level: 82, state: .charging), settings: settings) == nil)
        #expect(tracker.observe(.init(level: 21, state: .onBattery), settings: settings) == nil)
        #expect(tracker.observe(nil, settings: settings) == nil)
        #expect(tracker.observe(.init(level: 20, state: .onBattery), settings: settings) == nil)
    }

    @Test("Les watts mesurés sont indépendants du nominal et exigent une lecture cohérente")
    func measuredPower() throws {
        let adapter = [kIOPSPowerAdapterWattsKey: 73]
        let pack = ["Temperature": 3279]
        var telemetry = ["SystemPowerIn": 42230, "SystemVoltageIn": 19409,
                         "SystemCurrentIn": 2176, "SystemLoad": 42230]
        let reading = try #require(BatteryDiagnostics.parse(adapter: adapter, pack: pack, telemetry: telemetry))
        #expect(reading.nominalWatts == 73)
        #expect(reading.temperature == 32.79)
        #expect(reading.inputPower == .measured(42.23))
        #expect(reading.macWatts == 42.23)
        telemetry["SystemPowerIn"] = 42
        #expect(BatteryDiagnostics.parse(adapter: adapter, pack: nil, telemetry: telemetry)?.inputPower == nil)
        #expect(BatteryDiagnostics.parse(adapter: nil, pack: ["Temperature": 0], telemetry: telemetry) == nil)
    }

    @Test("Sans télémétrie complète, les watts estimés restent distincts et les données incompatibles sont écartées")
    func partialPower() throws {
        let adapter = [kIOPSPowerAdapterWattsKey: 73]
        let telemetry = ["SystemVoltageIn": 20_000, "SystemCurrentIn": 2_000, "SystemLoad": 38_000]
        let inputOnly = try #require(BatteryDiagnostics.parse(adapter: adapter, pack: nil, telemetry: telemetry))
        #expect(inputOnly.inputPower == .estimated(40))
        #expect(inputOnly.macWatts == nil)
        #expect(inputOnly.temperature == nil)

        let unknownAdapter = try #require(BatteryDiagnostics.parse(adapter: nil, pack: nil, telemetry: telemetry))
        #expect(unknownAdapter.inputPower == .estimated(40))
        #expect(unknownAdapter.nominalWatts == nil)

        let pack = ["Voltage": 12_000, "Amperage": -1_500]
        let batteryOnly = try #require(BatteryDiagnostics.parse(adapter: nil, pack: nil, telemetry: nil,
                                                                 battery: pack, state: .onBattery))
        #expect(batteryOnly.batteryWatts == 18)
        #expect(batteryOnly.inputPower == nil)
        #expect(batteryOnly.macWatts == nil)
        #expect(BatteryDiagnostics.parse(adapter: nil, pack: nil, telemetry: nil,
                                         battery: pack, state: .charging) == nil)
        let unsignedPack = ["Voltage": 12_000, "Amperage": Int(UInt32(bitPattern: -1_500))]
        #expect(BatteryDiagnostics.parse(adapter: nil, pack: nil, telemetry: nil,
                                         battery: unsignedPack, state: .onBattery)?.batteryWatts == 18)
    }

    @Test("Les anciennes préférences gardent leurs seuils et les alertes batterie sont facultatives")
    func legacyPreferences() {
        let old = WatchSettings.decode(Data(#"{"alertsLowDisk":false}"#.utf8))
        #expect(!old.alertsLowDisk)
        #expect(old.batteryAlerts == .init())
        var new = old
        new.batteryAlerts = .init(warnsLow: true, warnsCharged: true, low: 15, high: 85)
        #expect(WatchSettings.decode(new.encoded()) == new)
    }
}
