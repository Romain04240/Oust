import Foundation
import Testing
import OustWatch

@Suite struct PowerAlertEpisodeTests {
    let settings = BatteryAlertSettings(warnsLow: true, warnsCharged: true, warnsConnected: true, warnsDisconnected: true, notifies: true)

    @Test func startupCatchupAndPersistence() throws {
        var episodes = PowerAlertEpisodes()
        let first = try #require(episodes.observe(.init(level: 10, state: .onBattery), settings: settings).first)
        #expect(first.1 == .low(.init(level: 10, state: .onBattery)))
        var ledger = AlertDeliveryLedger()
        let result1 = ledger.reserve(first.0, channel: .capsule)
        #expect(result1)
        var restored = try JSONDecoder().decode(PowerAlertEpisodes.self, from: JSONEncoder().encode(episodes))
        let savedLedger = try JSONDecoder().decode(AlertDeliveryLedger.self, from: JSONEncoder().encode(ledger))
        let next = try #require(restored.observe(.init(level: 8, state: .onBattery), settings: settings).first)
        #expect(first.0 == next.0)
        #expect(savedLedger.contains(next.0, channel: .capsule))
        #expect(!savedLedger.contains(next.0, channel: .notification))
    }
    @Test func wakeAndPlugDoNotRearm() throws {
        var e = PowerAlertEpisodes()
        let id = try #require(e.observe(.init(level: 10, state: .onBattery), settings: settings).first?.0)
        _ = e.observe(.init(level: 12, state: .onAC), settings: settings)
        e.baseline()
        let result2 = e.observe(.init(level: 12, state: .onBattery), settings: settings).first?.0 == id
        #expect(result2)
        _ = e.observe(.init(level: 23, state: .charging), settings: settings)
        #expect(e.lowID == nil)
        let result3 = e.observe(.init(level: 20, state: .onBattery), settings: settings).first?.0 != id
        #expect(result3)
    }
    @Test func sourceBaselineAndFusion() {
        var e = PowerAlertEpisodes()
        let result4 = e.observe(.init(level: 50, state: .onAC), settings: settings).isEmpty
        #expect(result4)
        let result5 = e.observe(.init(level: 50, state: .charging), settings: settings).isEmpty
        #expect(result5)
        let events = e.observe(.init(level: 18, state: .onBattery), settings: settings)
        #expect(events.count == 1)
        #expect(events.first?.1 == .disconnectedLow(.init(level: 18, state: .onBattery)))
    }
    @Test func subsequentUnplugHasOwnIdentity() throws {
        var e = PowerAlertEpisodes()
        let id = try #require(e.observe(.init(level: 10, state: .onBattery), settings: settings).first?.0)
        _ = e.observe(.init(level: 10, state: .onAC), settings: settings)
        let events = e.observe(.init(level: 10, state: .onBattery), settings: settings)
        #expect(events.count == 2)
        #expect(events.last?.0 != id)
    }
    @Test func thresholdChangesDoNotInventRecharge() {
        var e = PowerAlertEpisodes()
        _ = e.observe(.init(level: 15, state: .onBattery), settings: settings)
        let id = e.lowID
        var changed = settings; changed.low = 10
        _ = e.observe(.init(level: 15, state: .onBattery), settings: changed)
        #expect(e.lowID == id)
        #expect(e.rearm == 23)
        changed.low = 30
        _ = e.observe(.init(level: 25, state: .onBattery), settings: changed)
        #expect(e.rearm == 33)
        #expect(e.lowID == id)
    }
    @Test func nilAndDisabledPreserveEpisode() {
        var e = PowerAlertEpisodes()
        _ = e.observe(.init(level: 15, state: .onBattery), settings: settings)
        let id = e.lowID
        _ = e.observe(nil, settings: settings)
        #expect(e.lowID == id)
        var disabled = settings; disabled.warnsLow = false
        let result6 = e.observe(.init(level: 14, state: .onBattery), settings: disabled).isEmpty
        #expect(result6)
        let result7 = e.observe(.init(level: 14, state: .onBattery), settings: settings).first?.0 == id
        #expect(result7)
    }
    @Test func chargedNeedsObservedCrossing() {
        var e = PowerAlertEpisodes()
        let result8 = e.observe(.init(level: 100, state: .charged), settings: settings).isEmpty
        #expect(result8)
        _ = e.observe(.init(level: 79, state: .charging), settings: settings)
        let result9 = e.observe(.init(level: 80, state: .charging), settings: settings).first?.1 == .charged(.init(level: 80, state: .charging))
        #expect(result9)
    }
    @Test func ledgerChannelsAndOccurrences() throws {
        var l = AlertDeliveryLedger()
        let result10 = l.reserve("a", channel: .notification)
        #expect(result10)
        let result11 = !l.reserve("a", channel: .notification)
        #expect(result11)
        let result12 = l.reserve("a", channel: .capsule)
        #expect(result12)
        let result13 = l.reserve("b", channel: .notification)
        #expect(result13)
        l.failed("a", channel: .notification)
        #expect(!l.contains("a", channel: .notification))
        #expect(l.contains("a", channel: .capsule))
    }
    @Test func oldSettingsMigrateWithoutEnablingNewChannels() throws {
        let old = Data(#"{"warnsLow":true,"warnsCharged":true,"low":20,"high":80}"#.utf8)
        let decoded = try JSONDecoder().decode(BatteryAlertSettings.self, from: old)
        #expect(decoded.warnsLow && decoded.warnsCharged)
        #expect(!decoded.warnsConnected && !decoded.warnsDisconnected && !decoded.notifies)
        #expect(decoded.low == 20 && decoded.high == 80)
    }
    @Test func fictionalFileSurvivesRelaunchAndCorruptionIsDetected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("alert-ledger.json")
        var ledger = AlertDeliveryLedger()
        _ = ledger.reserve("fictional-low-episode", channel: .notification)
        try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
        let restored = try JSONDecoder().decode(AlertDeliveryLedger.self, from: Data(contentsOf: file))
        #expect(restored.contains("fictional-low-episode", channel: .notification))
        #expect(!restored.contains("fictional-low-episode", channel: .capsule))
        try Data("{truncated".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(AlertDeliveryLedger.self, from: Data(contentsOf: file))
        }
    }

    @Test func diskThresholdDoesNotInventRecovery() throws {
        var alarm = LowDiskAlarm()
        let first = alarm.observe(available: 10_000_000_000, total: 100_000_000_000, threshold: .gigabytes(20))
        #expect(first == .alert)
        _ = alarm.observe(available: 10_000_000_000, total: 100_000_000_000, threshold: .gigabytes(5))
        #expect(alarm.hasFired)
        let restored = try JSONDecoder().decode(LowDiskAlarm.self, from: JSONEncoder().encode(alarm))
        #expect(restored.hasFired)
        _ = alarm.observe(available: 22_000_000_000, total: 100_000_000_000, threshold: .gigabytes(5))
        #expect(!alarm.hasFired)
    }

}
