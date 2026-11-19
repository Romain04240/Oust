import CoreFoundation
import CryptoKit
import Foundation
import OustCore

public struct BatteryDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let connected: Bool
    public let level: Int?
    public enum LevelSource: Sendable, Equatable { case system, bluetooth }
    public let levelSource: LevelSource
    public let bluetoothPeerID: UUID?
    public struct Components: Sendable, Equatable {
        public let left: Int?
        public let right: Int?
        public let chargingCase: Int?

        public init(left: Int? = nil, right: Int? = nil, chargingCase: Int? = nil) {
            self.left = left.flatMap { (0...100).contains($0) ? $0 : nil }
            self.right = right.flatMap { (0...100).contains($0) ? $0 : nil }
            self.chargingCase = chargingCase.flatMap { (0...100).contains($0) ? $0 : nil }
        }

        /// The case is separate: its charge must never stand in for an earbud.
        public var lowestEarbud: Int? { [left, right].compactMap { $0 }.min() }
    }
    public let components: Components?

    public init(id: String, name: String, connected: Bool, level: Int?, levelSource: LevelSource = .system, bluetoothPeerID: UUID? = nil, components: Components? = nil) {
        self.id = id
        self.name = name
        self.connected = connected
        self.level = level
        self.levelSource = levelSource
        self.bluetoothPeerID = bluetoothPeerID
        self.components = connected ? components : nil
    }

    public static func read(requestBluetoothPermission: Bool = false, knownBluetooth: [String: UUID] = [:]) async -> [Self]? {
        let result = await Command.run("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"], timeout: 4)
        guard result.succeeded, !Task.isCancelled, let devices = parse(result.stdout) else { return nil }
        let hid = await ConnectedBattery.read() ?? []
        guard !Task.isCancelled else { return nil }
        let system = fillingHID(devices, readings: hid)
        // Only remember connections whose native paired profile still exists.
        // No scan, pairing request, or connection to an unknown nearby device.
        let pairedIDs = Set(system.map(\.id))
        let owners = Dictionary(grouping: knownBluetooth.values, by: { $0 })
        let remembered = knownBluetooth.filter { pairedIDs.contains($0.key) && owners[$0.value]?.count == 1 }
        let bluetooth = await BatteryBluetooth.snapshot(peers: nil, requestPermission: requestBluetoothPermission,
                                                       knownPeers: Set(remembered.values))
        guard !Task.isCancelled else { return nil }
        guard !bluetooth.samples.isEmpty else { return system }
        let after = await Command.run("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"], timeout: 4)
        guard !Task.isCancelled else { return nil }
        guard after.succeeded, let current = parse(after.stdout) else { return nil }
        return merging(bluetooth, before: system, after: current, knownBluetooth: knownBluetooth)
    }

    static func fillingHID(_ devices: [Self], readings: [ConnectedBattery]) -> [Self] {
        let byID = Dictionary(grouping: readings.compactMap { reading in
            reading.deviceID.map { ($0, reading.level) }
        }, by: { $0.0 })
        return devices.map { device in
            guard device.connected, device.level == nil, device.components == nil,
                  let identified = byID[device.id], Set(identified.map { $0.1 }).count == 1,
                  let level = identified.first?.1 else { return device }
            return Self(id: device.id, name: device.name, connected: true, level: level)
        }
    }

    /// Keep native IDs and preferences. A name is only an automatic correlation,
    /// never a hardware identity guarantee: both inventories must agree on that same ID,
    /// and every native and BLE name must be unique, including offline peers.
    static func merging(_ bluetooth: BluetoothBatterySnapshot, before: [Self], after: [Self], knownBluetooth: [String: UUID] = [:]) -> [Self] {
        let earlier = Dictionary(grouping: before, by: \.id)
        let oldNames = Dictionary(grouping: before, by: { BluetoothBatterySnapshot.nameKey($0.name) })
        let newNames = Dictionary(grouping: after, by: { BluetoothBatterySnapshot.nameKey($0.name) })
        var peerNames: [String: Set<UUID>] = [:]
        for (peer, name) in bluetooth.names {
            if let key = BluetoothBatterySnapshot.nameKey(name) { peerNames[key, default: []].insert(peer) }
        }
        for sample in bluetooth.samples {
            if let key = sample.name.flatMap(BluetoothBatterySnapshot.nameKey) { peerNames[key, default: []].insert(sample.id) }
        }
        let samples = Dictionary(grouping: bluetooth.samples, by: \.id)
        let bindingOwners = Dictionary(grouping: knownBluetooth.values, by: { $0 })
        return after.map { device in
            guard let previous = earlier[device.id], previous.count == 1, let old = previous.first,
                  old.name == device.name else { return device }
            if device.connected, device.level != nil { return device }
            // Generic HID/BLE/earlier "main" readings do not identify an
            // earbud or its case, so they cannot fill a missing component.
            if device.components != nil || old.components != nil { return device }
            if device.connected, old.connected, old.components == nil, let level = old.level {
                // Preserve only a current component breakdown. A prior reading
                // must not make a disappeared earbud/case value look current.
                return Self(id: device.id, name: device.name, connected: true, level: level, components: device.components)
            }
            let remembered = knownBluetooth[device.id]
            guard (device.connected && old.connected) || remembered != nil else { return device }
            guard let name = BluetoothBatterySnapshot.nameKey(device.name),
                  oldNames[name]?.count == 1, newNames[name]?.count == 1,
                  let peers = peerNames[name], peers.count == 1, let peer = peers.first,
                  remembered.map({ $0 == peer && bindingOwners[peer]?.count == 1 }) ?? (bindingOwners[peer] == nil),
                  bluetooth.names[peer].flatMap(BluetoothBatterySnapshot.nameKey) == name,
                  let readings = samples[peer], readings.count == 1, let reading = readings.first,
                  reading.name.flatMap(BluetoothBatterySnapshot.nameKey) == name,
                  (0...100).contains(reading.level) else { return device }
            return Self(id: device.id, name: device.name, connected: true, level: reading.level, levelSource: .bluetooth, bluetoothPeerID: peer, components: device.components)
        }
    }

    static func parse(_ data: Data) -> [Self]? {
        guard let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = report["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var devices: [String: Self] = [:]
        for connected in [false, true] {
            let key = connected ? "device_connected" : "device_not_connected"
            for section in sections {
                for group in section[key] as? [[String: [String: Any]]] ?? [] {
                    for (name, properties) in group {
                        guard let address = properties["device_address"] as? String,
                              let id = id(for: address) else { continue }
                        let parts = Components(left: percent(properties["device_batteryLevelLeft"]),
                                               right: percent(properties["device_batteryLevelRight"]),
                                               chargingCase: percent(properties["device_batteryLevelCase"]))
                        let hasParts = ["device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelCase"]
                            .contains { properties.keys.contains($0) }
                        let level = connected ? (hasParts ? parts.lowestEarbud : percent(properties["device_batteryLevelMain"])) : nil
                        devices[id] = Self(id: id, name: name, connected: connected, level: level,
                                           components: hasParts ? parts : nil)
                    }
                }
            }
        }
        return devices.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func id(for address: String) -> String? {
        let normalized = address.lowercased().filter { $0 != ":" && $0 != "-" }
        guard normalized.count == 12, normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              normalized != "000000000000" else { return nil }
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func percent(_ value: Any?) -> Int? {
        let level: Int?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            level = Int(number.stringValue)
        } else if let text = value as? String, text.hasSuffix("%") {
            level = Int(text.dropLast().trimmingCharacters(in: .whitespaces))
        } else {
            level = nil
        }
        return level.flatMap { (0...100).contains($0) ? $0 : nil }
    }
}

public struct BatteryDevicePreference: Sendable, Codable, Equatable {
    public static let maximumShown = 6
    public let id: String
    public var shown = true
    public var alias = ""
    public var threshold: Int?
    public var bluetoothPeer: UUID?

    public init(id: String) { self.id = id }

    /// Persist explicit defaults once, so unchecking a device does not make
    /// another implicit default silently fill the slot on the next refresh.
    public static func reconciled(_ previous: [Self], devices: [BatteryDevice]) -> [Self] {
        var seen: Set<String> = []
        var result = previous.filter { seen.insert($0.id).inserted }
        let known = Set(result.map(\.id))
        for device in devices where !known.contains(device.id) && seen.insert(device.id).inserted {
            var preference = Self(id: device.id)
            preference.shown = device.connected
            result.append(preference)
        }
        let present = Set(devices.map(\.id))
        let connected = Set(devices.filter(\.connected).map(\.id))
        let previousChoices = result.filter { known.contains($0.id) && $0.shown && present.contains($0.id) }
        let initialOrder = previousChoices.count > maximumShown
            ? previousChoices.filter { connected.contains($0.id) } + previousChoices.filter { !connected.contains($0.id) }
            : previousChoices
        var admitted = Set(initialOrder.prefix(maximumShown).map(\.id))
        for preference in result where !known.contains(preference.id) && preference.shown && present.contains(preference.id) {
            if admitted.count < maximumShown { admitted.insert(preference.id) }
        }
        for i in result.indices where present.contains(result[i].id) && result[i].shown && !admitted.contains(result[i].id) {
            result[i].shown = false
        }
        return result
    }

    public static func ordered(_ devices: [BatteryDevice], using preferences: [Self]) -> [BatteryDevice] {
        var remaining = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let ordered = preferences.compactMap { remaining.removeValue(forKey: $0.id) }
        return ordered + devices.filter { remaining[$0.id] != nil }
    }
}

public struct DeviceBatteryAlertTracker: Sendable {
    public struct Pending: Equatable, Sendable {
        public let threshold: Int
        fileprivate let crossing: UUID
    }

    private var previous: [String: Int] = [:]
    private var thresholds: [String: Int] = [:]
    private var sent: Set<String> = []
    private var pending: [String: Pending] = [:]

    public init() {}

    public mutating func observe(_ devices: [BatteryDevice], preferences: [BatteryDevicePreference]) -> [BatteryDevice] {
        let configured = Dictionary(preferences.compactMap { preference -> (String, Int)? in
            guard let threshold = preference.threshold, (1...99).contains(threshold) else { return nil }
            return (preference.id, threshold)
        }, uniquingKeysWith: { first, _ in first })
        for id in sent where configured[id] != thresholds[id] { sent.remove(id) }
        var next: [String: Int] = [:]
        pending = pending.filter { configured[$0.key] == $0.value.threshold }
        for device in devices {
            guard device.connected, let level = device.level, let threshold = configured[device.id] else { continue }
            next[device.id] = level
            if level >= min(100, threshold + 3) { sent.remove(device.id) }
            if thresholds[device.id] == threshold, let before = previous[device.id], before > threshold,
               level <= threshold, !sent.contains(device.id) {
                pending[device.id] = Pending(threshold: threshold, crossing: UUID())
            }
        }
        pending = pending.filter { id, alert in next[id].map { $0 <= alert.threshold } ?? false }
        previous = next
        thresholds = configured
        return devices.filter { pending[$0.id] != nil }
    }

    public func pendingAlert(for id: String) -> Pending? { pending[id] }

    public mutating func acknowledge(_ id: String, alert: Pending) {
        guard pending[id] == alert else { return }
        pending[id] = nil
        sent.insert(id)
    }

    public mutating func invalidate(_ id: String) {
        pending[id] = nil
        previous[id] = nil
        thresholds[id] = nil
        sent.remove(id)
    }
}
