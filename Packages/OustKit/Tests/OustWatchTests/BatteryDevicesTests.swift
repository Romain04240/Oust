import Foundation
import Testing
@testable import OustWatch

struct BatteryDevicesTests {
    private func earbuds(_ fields: String, connected: Bool = true) throws -> BatteryDevice {
        let key = connected ? "device_connected" : "device_not_connected"
        let data = Data("{\"SPBluetoothDataType\":[{\"\(key)\":[{\"Test earbuds\":{\"device_address\":\"02:11:22:33:44:55\",\(fields)}}]}]}".utf8)
        return try #require(BatteryDevice.parse(data)?.first)
    }

    @Test("Separate earbud levels retain the real breakdown and use the lowest reported earbud")
    func separateEarbuds() throws {
        let device = try earbuds(#""device_batteryLevelLeft":"100 %","device_batteryLevelRight":"37 %","device_batteryLevelCase":"12 %","device_batteryLevelMain":"99%""#)
        #expect(device.level == 37)
        #expect(device.components == .init(left: 100, right: 37, chargingCase: 12))
        let one = try earbuds(#""device_batteryLevelLeft":"0%""#)
        #expect(one.level == 0 && one.components?.right == nil && one.components?.chargingCase == nil)
    }

    @Test("Missing, invalid and offline earbud values never become a battery estimate")
    func missingEarbuds() throws {
        let onlyCase = try earbuds(#""device_batteryLevelCase":"100%""#)
        #expect(onlyCase.level == nil && onlyCase.components?.chargingCase == 100)
        let invalid = try earbuds(#""device_batteryLevelLeft":true,"device_batteryLevelRight":"101%","device_batteryLevelCase":-1"#)
        #expect(invalid.level == nil && invalid.components == .init())
        let offline = try earbuds(#""device_batteryLevelLeft":"100%","device_batteryLevelRight":"100%""#, connected: false)
        #expect(offline.level == nil && offline.components == nil)
    }

    @Test("An earbud value disappearing during a Bluetooth read is not copied from the earlier inventory")
    func vanishedEarbud() throws {
        let before = try earbuds(#""device_batteryLevelLeft":"81%","device_batteryLevelCase":"90%""#)
        let after = try earbuds(#""device_batteryLevelCase":"90%""#)
        let report = BluetoothBatterySnapshot(samples: [], names: [:])
        let result = BatteryDevice.merging(report, before: [before], after: [after])
        #expect(result == [after] && result.first?.level == nil)
    }

    @Test("Generic main, HID and BLE readings cannot stand in for missing earbuds")
    func genericReadingsDoNotFillEarbuds() throws {
        let before = try earbuds(#""device_batteryLevelMain":"19%""#)
        let peer = UUID()
        for fields in [#""device_batteryLevelCase":"90%","device_batteryLevelMain":"55%""#,
                       #""device_batteryLevelLeft":null,"device_batteryLevelRight":true,"device_batteryLevelCase":"101%","device_batteryLevelMain":"55%""#] {
            let after = try earbuds(fields)
            #expect(after.level == nil)
            let hid = ConnectedBattery(id: 1, name: after.name, level: 19, deviceID: after.id)
            #expect(BatteryDevice.fillingHID([after], readings: [hid]) == [after])
            #expect(BatteryDevice.fillingHID([before], readings: [hid]) == [before])
            for report in [BluetoothBatterySnapshot(samples: [], names: [:]),
                           .init(samples: [.init(id: peer, name: after.name, level: 19)], names: [peer: after.name])] {
                let result = BatteryDevice.merging(report, before: [before], after: [after])
                #expect(result == [after] && result.first?.level == nil)
            }
        }
        let parts = try earbuds(#""device_batteryLevelLeft":"81%""#)
        let empty = try earbuds(#""device_productID":"0x2027""#)
        let report = BluetoothBatterySnapshot(samples: [.init(id: peer, name: empty.name, level: 81)], names: [peer: empty.name])
        #expect(BatteryDevice.merging(report, before: [parts], after: [empty]) == [empty])
    }

    @Test("Deux appareils de même nom gardent leurs réglages propres après reconnexion")
    func identities() throws {
        let devices = try #require(BatteryDevice.parse(Data(#"""
            {"SPBluetoothDataType":[{
                "device_connected":[{"Souris":{"device_address":"02:11:22:33:44:55","device_batteryLevelMain":"48%"}}],
                "device_not_connected":[{"Souris":{"device_address":"02-11-22-33-44-66","device_batteryLevelMain":88}}]
            }]}
            """#.utf8)))
        let online = try #require(devices.first(where: { $0.connected }))
        let offline = try #require(devices.first(where: { !$0.connected }))
        #expect(online.id == BatteryDevice.id(for: "02-11-22-33-44-55"))
        #expect(online.id != offline.id)
        #expect(online.level == 48)
        #expect(offline.level == nil)
        var preference = BatteryDevicePreference(id: offline.id)
        preference.alias = "Bureau"
        preference.shown = false
        let decoded = try JSONDecoder().decode(BatteryDevicePreference.self, from: JSONEncoder().encode(preference))
        #expect(decoded == preference)
        #expect(BatteryDevicePreference.ordered(devices, using: [decoded]).map(\.id) == [offline.id, online.id])
    }

    @Test("La notification demande un franchissement observé, sans doublon ni données périmées")
    func thresholds() throws {
        var preference = BatteryDevicePreference(id: "test")
        preference.threshold = 20
        let preferences = [preference]
        func device(_ level: Int?, connected: Bool = true) -> BatteryDevice {
            BatteryDevice(id: "test", name: "Test", connected: connected, level: level)
        }
        var tracker = DeviceBatteryAlertTracker()
        #expect(tracker.observe([device(21)], preferences: preferences).isEmpty)
        #expect(tracker.observe([device(nil, connected: false)], preferences: preferences).isEmpty)
        #expect(tracker.observe([device(19)], preferences: preferences).isEmpty)
        #expect(tracker.observe([device(23)], preferences: preferences).isEmpty)
        #expect(tracker.observe([device(20)], preferences: preferences) == [device(20)])
        #expect(tracker.observe([device(19)], preferences: preferences) == [device(19)])
        let pending = try #require(tracker.pendingAlert(for: "test"))
        tracker.acknowledge("test", alert: pending)
        #expect(tracker.observe([device(21)], preferences: preferences).isEmpty)
        #expect(tracker.observe([device(20)], preferences: preferences).isEmpty)
    }

    @Test("Un changement de seuil invalide l'alerte en attente")
    func pendingAlertInvalidation() {
        var preference = BatteryDevicePreference(id: "test")
        preference.threshold = 20
        let above = BatteryDevice(id: "test", name: "Test", connected: true, level: 21)
        let below = BatteryDevice(id: "test", name: "Test", connected: true, level: 19)
        var tracker = DeviceBatteryAlertTracker()
        #expect(tracker.observe([above], preferences: [preference]).isEmpty)
        #expect(tracker.observe([below], preferences: [preference]) == [below])
        tracker.invalidate(preference.id)
        preference.threshold = 30
        #expect(tracker.observe([below], preferences: [preference]).isEmpty)
        #expect(tracker.pendingAlert(for: preference.id) == nil)
    }

    @Test("La fin d'un envoi n'acquitte pas un nouveau franchissement du même seuil")
    func distinctCrossings() throws {
        var preference = BatteryDevicePreference(id: "test")
        preference.threshold = 20
        var tracker = DeviceBatteryAlertTracker()
        func sample(_ level: Int) -> [BatteryDevice] {
            [BatteryDevice(id: preference.id, name: "Test", connected: true, level: level)]
        }
        _ = tracker.observe(sample(21), preferences: [preference])
        _ = tracker.observe(sample(19), preferences: [preference])
        let first = try #require(tracker.pendingAlert(for: preference.id))
        _ = tracker.observe(sample(24), preferences: [preference])
        _ = tracker.observe(sample(18), preferences: [preference])
        let second = try #require(tracker.pendingAlert(for: preference.id))
        #expect(first.threshold == second.threshold)
        #expect(first != second)
        tracker.acknowledge(preference.id, alert: first)
        #expect(tracker.pendingAlert(for: preference.id) == second)
        tracker.acknowledge(preference.id, alert: second)
        #expect(tracker.pendingAlert(for: preference.id) == nil)
    }
}
