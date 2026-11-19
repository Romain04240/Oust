import Foundation
import Testing
@testable import OustWatch

struct WatchRelayTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private var binding: WatchRelayBinding { .init(watchID: String(repeating: "a", count: 64), phoneID: String(repeating: "b", count: 64)) }
    private func device(_ id: String = "native", name: String = "Apple Watch Test", connected: Bool = false, level: Int? = nil,
                        reading: WatchRelayReading? = nil) -> BatteryDevice {
        .init(id: id, name: name, connected: connected, level: level, watchRelay: reading)
    }
    private func sample(_ name: String = "Apple Watch Test", level: Int = 55, binding: WatchRelayBinding? = nil) -> WatchRelaySample {
        .init(binding: binding ?? self.binding, name: name, level: level)
    }
    private func snapshot(_ samples: [WatchRelaySample]? = nil) -> WatchRelaySnapshot {
        .init(samples: samples ?? [sample()], receivedAt: now)
    }
    private func row() -> [String: Any] {
        ["watchID": binding.watchID, "phoneID": binding.phoneID, "name": "Apple Watch Test", "productType": "Watch7,3", "level": 55]
    }
    private func encoded(_ rows: [[String: Any]], schema: Any = 1) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["schema": schema, "samples": rows], format: .binary, options: 0)
    }

    @Test("Versioned relay data is strict and carries only hashed identities")
    func parsing() throws {
        let result = try #require(WatchRelay.parse(encoded([row()]), receivedAt: now))
        #expect(result.samples == [sample()])
        #expect(WatchRelay.parse(try encoded([], schema: true), receivedAt: now) == nil)
        #expect(WatchRelay.parse(try encoded([], schema: 2), receivedAt: now) == nil)
        #expect(WatchRelay.parse(Data(repeating: 0, count: 32769), receivedAt: now) == nil)
        for (key, bad) in [("level", -1 as Any), ("level", 101), ("level", true), ("level", 55.5),
                           ("watchID", "raw-device-id"), ("phoneID", ""), ("name", "\nInjected"), ("name", "  "),
                           ("productType", "iPhone17,3"), ("productType", "WatchWrong")] {
            var entry = row(); entry[key] = bad
            #expect(WatchRelay.parse(try encoded([entry]), receivedAt: now) == nil)
        }
        #expect(WatchRelay.parse(try encoded([row(), row()]), receivedAt: now) == nil)
    }

    @Test("A relay reuses the native card without claiming a direct connection")
    func nativeCard() throws {
        let native = device()
        let merged = WatchRelay.merging(snapshot(), before: [native], after: [native], known: [:], now: now)
        let item = try #require(merged.first)
        #expect(merged.count == 1 && item.id == native.id && item.name == native.name)
        #expect(!item.connected && item.level == nil && item.watchRelay?.level == 55)
        var preference = BatteryDevicePreference(id: native.id)
        preference.alias = "My watch"; preference.shown = false; preference.threshold = 20
        preference.bluetoothPeer = UUID(); preference.watchRelayBinding = item.watchRelay?.binding
        let saved = try JSONDecoder().decode(BatteryDevicePreference.self, from: JSONEncoder().encode(preference))
        #expect(saved == preference)
        #expect(BatteryDevicePreference.ordered(merged, using: [saved]).map(\.id) == [native.id])
        let old = try JSONDecoder().decode(BatteryDevicePreference.self, from: Data(#"{"id":"native","shown":true,"alias":"Old","threshold":20}"#.utf8))
        #expect(old.watchRelayBinding == nil && old.alias == "Old")
    }

    @Test("Missing parents or changed identities never keep the old relay")
    func missingOrChanged() {
        let native = device(), relayed = device(reading: .init(binding: binding, level: 55, receivedAt: now))
        #expect(WatchRelay.merging(snapshot([]), before: [relayed], after: [relayed], known: [:], now: now) == [native])
        for after in [device("replacement"), device(name: "Apple Watch Renamed")] {
            #expect(WatchRelay.merging(snapshot(), before: [native], after: [after], known: [:], now: now) == [after])
        }
        #expect(WatchRelay.merging(snapshot(), before: [], after: [native], known: [:], now: now) == [native])
        let otherPhone = WatchRelayBinding(watchID: binding.watchID, phoneID: String(repeating: "c", count: 64))
        #expect(WatchRelay.merging(snapshot(), before: [native], after: [native], known: [native.id: otherPhone], now: now) == [native])
    }

    @Test("Ambiguous profiles, sources and saved owners block automatic matching")
    func ambiguity() {
        let native = device(), other = device("other")
        #expect(WatchRelay.merging(snapshot(), before: [native, other], after: [native, other], known: [:], now: now) == [native, other])
        let second = WatchRelayBinding(watchID: String(repeating: "c", count: 64), phoneID: binding.phoneID)
        for samples in [[sample(), sample(binding: second)], [sample(), sample()]] {
            #expect(WatchRelay.merging(snapshot(samples), before: [native], after: [native], known: [:], now: now) == [native])
        }
        #expect(WatchRelay.merging(snapshot(), before: [native], after: [native], known: [native.id: binding, other.id: binding], now: now) == [native])
        let mouse = device(name: "Mouse")
        #expect(WatchRelay.merging(snapshot([sample("Mouse")]), before: [mouse], after: [mouse], known: [:], now: now) == [mouse])
    }

    @Test("Direct readings take priority; relayed and expired values never trigger alerts")
    func noAlertsOrFalseFreshness() {
        let direct = device(connected: true, level: 61)
        #expect(WatchRelay.merging(snapshot(), before: [direct], after: [direct], known: [:], now: now) == [direct])
        let reading = WatchRelayReading(binding: binding, level: 19, receivedAt: now)
        #expect(reading.isRecent(at: now) && !reading.isRecent(at: now.addingTimeInterval(46)))
        #expect(!reading.isRecent(at: now.addingTimeInterval(-1)))
        var preference = BatteryDevicePreference(id: "native"); preference.threshold = 20
        var tracker = DeviceBatteryAlertTracker()
        #expect(tracker.observe([device(connected: true, level: 25)], preferences: [preference]).isEmpty)
        #expect(tracker.observe([device(connected: true, level: 19, reading: reading)], preferences: [preference]).isEmpty)
        #expect(tracker.pendingAlert(for: "native") == nil)
        #expect(tracker.observe([device(connected: true, level: 25)], preferences: [preference]).isEmpty)
        #expect(tracker.observe([device(connected: true, level: 19)], preferences: [preference]).count == 1)
        #expect(tracker.observe([device(reading: reading)], preferences: [preference]).isEmpty)
        #expect(tracker.pendingAlert(for: "native") == nil)
    }
}
