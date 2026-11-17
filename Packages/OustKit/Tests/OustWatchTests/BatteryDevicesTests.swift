import Foundation
import Testing
@testable import OustWatch

struct BatteryDevicesTests {
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
