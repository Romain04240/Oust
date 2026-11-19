import Foundation
import Testing
@testable import OustWatch

struct BatteryBluetoothTests {
    private func native(_ id: String = "native", name: String = "Test mouse", connected: Bool = true, level: Int? = nil) -> BatteryDevice {
        BatteryDevice(id: id, name: name, connected: connected, level: level)
    }

    private func snapshot(_ name: String = "Test mouse", level: Int = 52) -> BluetoothBatterySnapshot {
        let id = UUID()
        return .init(samples: [.init(id: id, name: name, level: level)], names: [id: name])
    }

    @Test("Automatic matching keeps the native ID and every saved preference")
    func automatic() throws {
        let device = native()
        let merged = BatteryDevice.merging(snapshot(), before: [device], after: [device])
        #expect(merged.count == 1 && merged[0].id == device.id && merged[0].level == 52)
        #expect(merged[0].levelSource == .bluetooth)
        var preference = BatteryDevicePreference(id: device.id)
        preference.alias = "Desk mouse"
        preference.shown = false
        preference.threshold = 20
        let saved = try JSONDecoder().decode([BatteryDevicePreference].self, from: JSONEncoder().encode([preference]))
        #expect(saved == [preference])
        #expect(BatteryDevicePreference.ordered(merged, using: saved).map(\.id) == [device.id])
    }

    @Test("Duplicate native names, including offline devices, block correlation")
    func nativeAmbiguity() {
        let one = native(), other = native("other", connected: false)
        #expect(BatteryDevice.merging(snapshot(), before: [one, other], after: [one, other]).allSatisfy { $0.level == nil })
        #expect(BatteryDevice.merging(snapshot(), before: [one, other], after: [one]).first?.level == nil)
        #expect(BatteryDevice.merging(snapshot(), before: [one], after: [one, other]).allSatisfy { $0.level == nil })
    }

    @Test("Duplicate Bluetooth names block correlation even if only one gave a level")
    func peerAmbiguity() {
        let device = native(), a = UUID(), b = UUID()
        let report = BluetoothBatterySnapshot(samples: [.init(id: a, name: device.name, level: 52)], names: [a: device.name, b: device.name])
        #expect(BatteryDevice.merging(report, before: [device], after: [device]).first?.level == nil)
    }

    @Test("Replacement, disconnection and renamed identities invalidate the level")
    func changesDuringRead() {
        let before = native()
        for after in [native("replacement"), native(connected: false), native(name: "Renamed mouse")] {
            let result = BatteryDevice.merging(snapshot(), before: [before], after: [after])
            #expect(result.count == 1 && result.first?.id == after.id && result.first?.level == nil)
        }
        #expect(BatteryDevice.merging(snapshot(), before: [native(connected: false)], after: [before]).first?.level == nil)
    }

    @Test("System values win; no standalone or duplicate cards are introduced")
    func authoritativeInventory() {
        let before = native(), current = native(level: 73)
        let result = BatteryDevice.merging(snapshot(), before: [before], after: [current])
        #expect(result == [current])
        #expect(BatteryDevice.merging(snapshot(), before: [], after: []).isEmpty)
        #expect(BatteryDevice.merging(snapshot("Unknown"), before: [before], after: [before]) == [before])
    }

    @Test("Invalid values and duplicate samples are not shown", arguments: [-1, 101, 255])
    func invalidLevels(_ value: Int) {
        let device = native()
        #expect(BatteryDevice.merging(snapshot(level: value), before: [device], after: [device]) == [device])
        let id = UUID(), sample = BluetoothBatterySample(id: id, name: device.name, level: 52)
        let duplicate = BluetoothBatterySnapshot(samples: [sample, sample], names: [id: device.name])
        #expect(BatteryDevice.merging(duplicate, before: [device], after: [device]) == [device])
    }

    @Test("A real Bluetooth zero is valid; missing data never becomes zero")
    func emptyAndZero() {
        let device = native()
        #expect(BatteryDevice.merging(snapshot(level: 0), before: [device], after: [device]).first?.level == 0)
        #expect(BatteryDevice.merging(.init(samples: [], names: [:]), before: [device], after: [device]) == [device])
    }
    @Test("A name collision observed during the read invalidates automatic correlation")
    func peerRenameDuringRead() {
        let device = native(), other = native("other", name: "Other")
        let a = UUID(), b = UUID()
        let report = BluetoothBatterySnapshot(samples: [
            .init(id: a, name: device.name, level: 52),
            .init(id: b, name: device.name, level: 18)
        ], names: [a: device.name, b: other.name])
        #expect(BatteryDevice.merging(report, before: [device, other], after: [device, other]) == [device, other])
        let renamed = BluetoothBatterySnapshot(samples: [.init(id: a, name: other.name, level: 52)], names: [a: device.name])
        #expect(BatteryDevice.merging(renamed, before: [device, other], after: [device, other]) == [device, other])
    }

    @Test("Six displayed devices maximum, without losing aliases, alerts or order")
    func displayLimit() throws {
        let devices = (0..<8).map { native("device-\($0)", name: "Device \($0)") }
        var preferences = devices.map { BatteryDevicePreference(id: $0.id) }
        preferences[2].alias = "Desk"
        preferences[2].threshold = 18
        let result = BatteryDevicePreference.reconciled(preferences, devices: devices)
        #expect(result.filter(\.shown).count == 6)
        #expect(result.map(\.id) == preferences.map(\.id))
        #expect(result[2].alias == "Desk" && result[2].threshold == 18)
        var unchecked = result
        unchecked[0].shown = false
        let refreshed = BatteryDevicePreference.reconciled(unchecked, devices: devices)
        #expect(refreshed == unchecked && refreshed.filter(\.shown).count == 5)
        let saved = try JSONDecoder().decode([BatteryDevicePreference].self, from: JSONEncoder().encode(refreshed))
        #expect(saved == refreshed)
    }

    @Test("New offline devices stay available for selection without filling the menu")
    func offlineSelection() {
        let connected = native("online"), offline = native("offline", name: "Offline", connected: false)
        let selected = BatteryDevicePreference.reconciled([], devices: [offline, connected])
        #expect(selected.first(where: { $0.id == connected.id })?.shown == true)
        #expect(selected.first(where: { $0.id == offline.id })?.shown == false)
        var explicit = selected
        explicit[0].shown = true
        #expect(BatteryDevicePreference.reconciled(explicit, devices: [offline, connected]) == explicit)
    }

    @Test("A newly connected device cannot evict an explicit offline selection")
    func newDeviceRespectsSelection() {
        let selected = (0..<6).map { native("saved-\($0)", name: "Saved \($0)", connected: $0 != 0) }
        let saved = selected.map { BatteryDevicePreference(id: $0.id) }
        let newcomer = native("new", name: "New device")
        let result = BatteryDevicePreference.reconciled(saved, devices: selected + [newcomer])
        #expect(result.prefix(6).elementsEqual(saved))
        #expect(result.last?.id == newcomer.id && result.last?.shown == false)
        #expect(result.filter(\.shown).count == 6)
    }

    @Test("Remembered Bluetooth peers reconnect to the same paired native identity")
    func rememberedIdentity() throws {
        let device = native(connected: false), peer = UUID()
        let report = BluetoothBatterySnapshot(samples: [.init(id: peer, name: device.name, level: 65)], names: [peer: device.name])
        let result = try #require(BatteryDevice.merging(report, before: [device], after: [device], knownBluetooth: [device.id: peer]).first)
        #expect(result.id == device.id && result.connected && result.level == 65 && result.bluetoothPeerID == peer)
        #expect(BatteryDevice.merging(report, before: [device], after: [device]).first?.level == nil)
        #expect(BatteryDevice.merging(report, before: [], after: [device], knownBluetooth: [device.id: peer]).first?.level == nil)
        #expect(BatteryDevice.merging(report, before: [device], after: [], knownBluetooth: [device.id: peer]).isEmpty)
    }

    @Test("A remembered peer cannot be substituted or assigned to a second native identity")
    func pinnedPeer() {
        let device = native(), peer = UUID(), replacement = UUID()
        let report = BluetoothBatterySnapshot(samples: [.init(id: replacement, name: device.name, level: 19)], names: [replacement: device.name])
        #expect(BatteryDevice.merging(report, before: [device], after: [device], knownBluetooth: [device.id: peer]).first?.level == nil)
        let existing = BluetoothBatterySnapshot(samples: [.init(id: peer, name: device.name, level: 19)], names: [peer: device.name])
        #expect(BatteryDevice.merging(existing, before: [device], after: [device], knownBluetooth: ["different owner": peer]).first?.level == nil)
        #expect(BatteryDevice.merging(existing, before: [device], after: [device], knownBluetooth: [device.id: peer, "different owner": peer]).first?.level == nil)
    }

    @Test("Remembered peers survive reload without changing display or notification settings")
    func savedPeer() throws {
        var preference = BatteryDevicePreference(id: "test")
        preference.bluetoothPeer = UUID()
        preference.alias = "Phone"
        preference.shown = false
        preference.threshold = 18
        let decoded = try JSONDecoder().decode(BatteryDevicePreference.self, from: JSONEncoder().encode(preference))
        #expect(decoded == preference)
        let legacy = try JSONDecoder().decode(BatteryDevicePreference.self, from: Data(#"{"id":"legacy","shown":true,"alias":"Desk"}"#.utf8))
        #expect(legacy.bluetoothPeer == nil && legacy.alias == "Desk" && legacy.shown)
    }

}
