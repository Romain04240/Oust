import Foundation
import Testing
import OustWatch
@testable import OustModel

@Suite @MainActor struct AlertOccurrenceRegressionTests {
    @Test(arguments: [false, true]) func failedOccurrenceMustNotBeRebasedAfterNewEpisode(_ charged: Bool) async throws {
        let defaults = MemoryDefaults()
        let alerts = BatteryAlertSettings(warnsCharged: true, warnsConnected: true, notifies: true)
        defaults.set(WatchSettings(batteryAlerts: alerts).encoded(), forKey: "watch.settings")
        var reading = BatteryReading(level: charged ? 80 : 50, state: .charging)
        var posts = 0
        let watch = WatchModel(defaults: defaults, powerRead: { reading }, powerPermission: { true }, powerPost: { _,_,_,_,file,_ in
            if file != (charged ? "oust-charged-v1.wav" : "oust-connect-v1.wav") { return true }
            posts += 1; return posts > 1
        })
        let a = PowerAlertComponent(id: "fictional-A", alert: charged ? .charged(reading) : .connected(reading))
        watch.deliverPowerComponents([a], cycle: watch.batteryAlertCycle)
        await watch.waitForAlertDelivery()
        #expect(posts == 1)
        reading = .init(level: charged ? 79 : 50, state: .onBattery)
        // Ces changements externes font réellement observer les sources injectées.
        watch.settings.batteryAlerts.low = 19
        try await Task.sleep(for: .milliseconds(1100))
        await watch.waitForAlertDelivery()
        #expect(posts == 1)
        if charged {
            reading = .init(level: 79, state: .charging)
            watch.settings.batteryAlerts.low = 20
            try await Task.sleep(for: .milliseconds(1100))
            await watch.waitForAlertDelivery()
        }
        reading = .init(level: charged ? 80 : 50, state: .charging)
        watch.settings.batteryAlerts.low = charged ? 19 : 20
        // La source puis le nouveau franchissement sont réellement confirmés.
        try await Task.sleep(for: .milliseconds(1100))
        await watch.waitForAlertDelivery()
        // A était un ancien épisode ; seuls son échec et l'envoi de B sont attendus.
        #expect(posts == 2)
    }
    @Test func capsuleMessageMustMatchReservedComponents() throws {
        let defaults = MemoryDefaults()
        let alerts = BatteryAlertSettings(warnsLow: true, warnsDisconnected: true)
        defaults.set(WatchSettings(batteryAlerts: alerts).encoded(), forKey: "watch.settings")
        var episodes = PowerAlertEpisodes()
        let initial = BatteryReading(level: 20, state: .onBattery)
        let low = try #require(episodes.observe(initial, settings: alerts).first)
        defaults.set(try JSONEncoder().encode(episodes), forKey: "watch.powerEpisodes")
        var reading = initial
        let watch = WatchModel(defaults: defaults, powerRead: { reading })
        var current: (@MainActor () -> BatteryAlert?)?
        var presented: (@MainActor () -> PreparedWatchAlert<BatteryAlert>?)?
        watch.onPowerAlert = { _,_,fresh,ack in current = fresh; presented = ack }
        watch.deliverPowerComponents([PowerAlertComponent(id: low.0, alert: .low(initial)), PowerAlertComponent(id: "fictional-unplug", alert: .disconnected(initial))], cycle: watch.batteryAlertCycle)
        _ = try #require(current?())
        reading = .init(level: 21, state: .onBattery)
        let prepared = try #require(presented?())
        let allowed = prepared.acknowledge()
        let ledgerData = try #require(defaults.data(forKey: "watch.alertLedger"))
        let ledger = try JSONDecoder().decode(AlertDeliveryLedger.self, from: ledgerData)
        #expect(ledger.contains("fictional-unplug", channel: .capsule))
        #expect(!ledger.contains(low.0, channel: .capsule))
        // Le presenter affiche exactement la valeur du paquet acquitté.
        #expect(allowed && prepared.value == .disconnected(reading))
    }
    @Test func freshWallDateCannotRenewExpiredDeadline() async {
        let defaults = MemoryDefaults()
        defaults.set(WatchSettings(batteryAlerts: BatteryAlertSettings(warnsConnected: true, notifies: true)).encoded(), forKey: "watch.settings")
        let reading = BatteryReading(level: 50, state: .charging)
        var posts = 0
        let watch = WatchModel(defaults: defaults, powerRead: { reading }, powerPermission: { true }, powerPost: { _,_,_,_,_,_ in posts += 1; return true })
        watch.deliverPowerComponents([PowerAlertComponent(id: "expired", alert: .connected(reading))], cycle: watch.batteryAlertCycle,
                                     observedAt: Date(), deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
        await watch.waitForAlertDelivery()
        #expect(posts == 0)
    }

}
