import CoreFoundation
import CryptoKit
import Foundation
import OustCore

public struct BatteryDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let connected: Bool
    public let level: Int?

    public static func read() async -> [Self]? {
        let result = await Command.run("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"], timeout: 4)
        guard result.succeeded, !Task.isCancelled, let devices = parse(result.stdout) else { return nil }
        let hid = await ConnectedBattery.read() ?? []
        guard !Task.isCancelled else { return nil }
        let byID = Dictionary(grouping: hid.compactMap { reading in
            reading.deviceID.map { ($0, reading.level) }
        }, by: { $0.0 })
        return devices.map { device in
            guard device.connected, device.level == nil,
                  let identified = byID[device.id], Set(identified.map { $0.1 }).count == 1,
                  let level = identified.first?.1 else { return device }
            return Self(id: device.id, name: device.name, connected: true, level: level)
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
                        let level = connected ? percent(properties["device_batteryLevelMain"]) : nil
                        devices[id] = Self(id: id, name: name, connected: connected, level: level)
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
    public let id: String
    public var shown = true
    public var alias = ""
    public var threshold: Int?

    public init(id: String) { self.id = id }

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
