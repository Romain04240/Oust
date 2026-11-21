import Foundation
import Testing
import OustWatch
@testable import OustModel

@Suite @MainActor struct PowerContinuityRegressionTests {
    private func settings() -> WatchSettings {
        WatchSettings(batteryAlerts: BatteryAlertSettings(warnsConnected: true, notifies: true))
    }
    @Test(arguments: [false, true]) func validationReadMustInvalidateContinuity(_ missing: Bool) async throws {
        let defaults = MemoryDefaults(); defaults.set(settings().encoded(), forKey: "watch.settings")
        let ac = BatteryReading(level: 50, state: .charging)
        var reading: BatteryReading? = ac
        var posts = 0
        let watch = WatchModel(defaults: defaults, powerRead: { reading }, powerPermission: { true }, powerPost: { _,_,_,_,_,_ in posts += 1; return posts > 1 })
        watch.settings.batteryAlerts.low = 19
        try await Task.sleep(for: .milliseconds(1100))
        await watch.waitForAlertDelivery()
        let original = PowerAlertComponent(id: "fictional-old-connection", alert: .connected(ac))
        watch.deliverPowerComponents([original], cycle: watch.batteryAlertCycle)
        await watch.waitForAlertDelivery()
        #expect(posts == 1)
        reading = missing ? nil : BatteryReading(level: 50, state: .onBattery)
        watch.settings.playsAlertSounds.toggle()
        await watch.waitForAlertDelivery()
        #expect(posts == 1)
        reading = ac
        watch.settings.playsAlertSounds.toggle()
        await watch.waitForAlertDelivery()
        // La lecture précédente a constaté une rupture ; l'ancienne A doit rester abandonnée.
        #expect(posts == 1)
    }
    @Test func rejectedConfirmationMustInvalidateContinuity() async throws {
        let defaults = MemoryDefaults(); defaults.set(settings().encoded(), forKey: "watch.settings")
        let ac = BatteryReading(level: 50, state: .charging)
        var reading: BatteryReading? = ac
        var posts = 0
        let watch = WatchModel(defaults: defaults, powerRead: { reading }, powerPermission: { true }, powerPost: { _,_,_,_,_,_ in posts += 1; return posts > 1 })
        watch.settings.batteryAlerts.low = 19
        try await Task.sleep(for: .milliseconds(1100))
        await watch.waitForAlertDelivery()
        watch.settings.batteryAlerts.low = 20
        watch.deliverPowerComponents([PowerAlertComponent(id: "fictional-connection", alert: .connected(ac))], cycle: watch.batteryAlertCycle)
        await watch.waitForAlertDelivery()
        #expect(posts == 1)
        reading = BatteryReading(level: 50, state: .onBattery)
        // Le second relevé réel du contrôle voit une autre source, sans callback IOPS séparé.
        try await Task.sleep(for: .milliseconds(1100))
        reading = ac
        watch.settings.playsAlertSounds.toggle()
        await watch.waitForAlertDelivery()
        #expect(posts == 1)
    }
    @Test func firstLowSampleCatchesUpWithoutRepeating() async throws {
        let defaults = MemoryDefaults()
        defaults.set(WatchSettings(batteryAlerts: BatteryAlertSettings(warnsLow: true, notifies: true)).encoded(), forKey: "watch.settings")
        let reading = BatteryReading(level: 10, state: .onBattery)
        var posts = 0, shown = 0
        let watch = WatchModel(defaults: defaults, powerRead: { reading }, powerPermission: { true }, powerPost: { _,_,_,_,_,_ in posts += 1; return true })
        watch.onPowerAlert = { _,_,_,prepare in
            if let packet = prepare(), packet.acknowledge() { shown += 1 }
        }
        watch.settings.batteryAlerts.low = 19
        try await Task.sleep(for: .milliseconds(1100)); await watch.waitForAlertDelivery()
        #expect(posts == 1 && shown == 1)
        watch.settings.batteryAlerts.low = 20
        try await Task.sleep(for: .milliseconds(1100)); await watch.waitForAlertDelivery()
        #expect(posts == 1 && shown == 1)
    }
    @Test func nilGapHasSilentSourceBaselineAndFreshLowCatchup() async throws {
        let defaults = MemoryDefaults()
        defaults.set(WatchSettings(batteryAlerts: BatteryAlertSettings(warnsLow: true, warnsConnected: true, warnsDisconnected: true, notifies: true)).encoded(), forKey: "watch.settings")
        var reading: BatteryReading? = .init(level: 50, state: .charging)
        var posts = 0
        var shown: [BatteryAlert] = []
        let watch = WatchModel(defaults: defaults, powerRead: { reading }, powerPermission: { true }, powerPost: { _,_,_,_,_,_ in posts += 1; return true })
        watch.onPowerAlert = { _,_,_,prepare in
            if let packet = prepare(), packet.acknowledge() { shown.append(packet.value) }
        }
        watch.settings.batteryAlerts.low = 19
        try await Task.sleep(for: .milliseconds(1100)); await watch.waitForAlertDelivery()
        #expect(posts == 0 && shown.isEmpty)
        reading = nil
        watch.settings.batteryAlerts.low = 20
        reading = .init(level: 10, state: .onBattery)
        watch.settings.batteryAlerts.low = 19
        try await Task.sleep(for: .milliseconds(1100)); await watch.waitForAlertDelivery()
        #expect(shown == [.low(.init(level: 10, state: .onBattery))] && posts == 1)
    }

}
