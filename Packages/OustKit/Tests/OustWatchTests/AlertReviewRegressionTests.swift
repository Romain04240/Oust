import Foundation
import Testing
import OustWatch

@Suite struct AlertReviewRegressionTests {
    let settings = BatteryAlertSettings(warnsLow: true, warnsCharged: true, warnsConnected: true, warnsDisconnected: true, notifies: true)
    @Test func chargedOscillationAndRelaunch() throws {
        var e = PowerAlertEpisodes()
        _ = e.observe(.init(level: 79, state: .charging), settings: settings)
        let first = e.observe(.init(level: 80, state: .charging), settings: settings)
        #expect(first.count == 1)
        _ = e.observe(.init(level: 79, state: .charging), settings: settings)
        let repeatAlert = e.observe(.init(level: 80, state: .charging), settings: settings)
        #expect(repeatAlert.isEmpty)
        var restored = try JSONDecoder().decode(PowerAlertEpisodes.self, from: JSONEncoder().encode(e))
        _ = restored.observe(.init(level: 79, state: .charging), settings: settings)
        let afterRestart = restored.observe(.init(level: 80, state: .charging), settings: settings)
        #expect(afterRestart.isEmpty)
        _ = restored.observe(.init(level: 79, state: .onBattery), settings: settings)
        _ = restored.observe(.init(level: 79, state: .charging), settings: settings)
        let next = restored.observe(.init(level: 80, state: .charging), settings: settings)
        #expect(next.count == 1)
    }
    @Test func failureRetriesOnlyAfterExternalChange() throws {
        var ledger = AlertDeliveryLedger()
        _ = ledger.reserve("low", channel: .capsule)
        _ = ledger.reserve("low", channel: .notification)
        ledger.completed("low", channel: .notification, accepted: false)
        #expect(!ledger.contains("low", channel: .notification))
        #expect(!ledger.canAttempt("low", channel: .notification))
        var restarted = try JSONDecoder().decode(AlertDeliveryLedger.self, from: JSONEncoder().encode(ledger))
        restarted.retryFailures()
        #expect(restarted.canAttempt("low", channel: .notification))
        #expect(restarted.contains("low", channel: .capsule))
        _ = restarted.reserve("ambiguous", channel: .notification)
        restarted.retryFailures()
        #expect(!restarted.canAttempt("ambiguous", channel: .notification))
    }
    @Test func fusionIsPerChannel() throws {
        var e = PowerAlertEpisodes()
        let old = try #require(e.observe(.init(level: 10, state: .onBattery), settings: settings).first)
        var ledger = AlertDeliveryLedger(); _ = ledger.reserve(old.0, channel: .capsule)
        _ = e.observe(.init(level: 10, state: .onAC), settings: settings)
        let events = PowerAlertComponent.split(e.observe(.init(level: 10, state: .onBattery), settings: settings))
        let capsule = events.filter { !ledger.contains($0.id, channel: .capsule) }
        let os = events.filter { !ledger.contains($0.id, channel: .notification) }
        #expect(PowerAlertComponent.message(capsule) == .disconnected(.init(level: 10, state: .onBattery)))
        #expect(PowerAlertComponent.message(os) == .disconnectedLow(.init(level: 10, state: .onBattery)))
    }
    @Test(arguments: [true, false]) func sourceSurvivesInvalidLow(_ disabled: Bool) {
        var changed = settings; changed.warnsLow = !disabled
        let reading = BatteryReading(level: disabled ? 18 : 21, state: .onBattery)
        let result = BatteryAlert.disconnectedLow(.init(level: 18, state: .onBattery)).updated(for: reading, settings: changed)
        #expect(result == .disconnected(reading))
    }
}
