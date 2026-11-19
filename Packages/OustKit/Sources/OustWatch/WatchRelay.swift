import CoreFoundation
import Foundation
import OustCore

public struct WatchRelayBinding: Codable, Equatable, Hashable, Sendable {
    public let watchID: String
    public let phoneID: String
    public init(watchID: String, phoneID: String) { self.watchID = watchID; self.phoneID = phoneID }
    var isValid: Bool { Self.digest(watchID) && Self.digest(phoneID) }
    private static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// A value relayed by an iPhone. receivedAt is a collection time, not a sensor
/// timestamp. This must never serve as a direct-connection or alert reading.
public struct WatchRelayReading: Sendable, Equatable {
    public let binding: WatchRelayBinding
    public let level: Int
    public let receivedAt: Date
    public init(binding: WatchRelayBinding, level: Int, receivedAt: Date) {
        self.binding = binding; self.level = level; self.receivedAt = receivedAt
    }
    public func isRecent(at now: Date) -> Bool {
        let age = now.timeIntervalSince(receivedAt)
        return binding.isValid && (0...100).contains(level) && age.isFinite && (0...45).contains(age)
    }
}

struct WatchRelaySample: Sendable, Equatable {
    let binding: WatchRelayBinding
    let name: String
    let level: Int
}

struct WatchRelaySnapshot: Sendable {
    let samples: [WatchRelaySample]
    let receivedAt: Date
}

enum WatchRelay {
    static func read() async -> WatchRelaySnapshot? {
        guard Bundle.main.bundleIdentifier == "fr.meaillais.oust", !Task.isCancelled else { return nil }
        // No PATH lookup or fallback to a separately installed tool.
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/oust-cli")
        guard let data = await BoundedCommand.run(executable.path, ["--internal-watch-battery-snapshot-v1"],
                                                 timeout: 6, maximumOutputBytes: 32_768),
              !Task.isCancelled else { return nil }
        return parse(data, receivedAt: Date())
    }

    static func parse(_ data: Data, receivedAt: Date) -> WatchRelaySnapshot? {
        guard data.count <= 32_768, receivedAt.timeIntervalSince1970.isFinite,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              integer(root["schema"]) == 1, let rows = root["samples"] as? [[String: Any]], rows.count <= 6 else { return nil }
        var samples: [WatchRelaySample] = []
        var seen = Set<String>()
        for row in rows {
            guard let watch = row["watchID"] as? String, let phone = row["phoneID"] as? String,
                  let name = row["name"] as? String, name.utf8.count <= 512,
                  !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  BluetoothBatterySnapshot.nameKey(name) != nil,
                  let product = row["productType"] as? String, product.utf8.count <= 32,
                  product.range(of: "^Watch[0-9]{1,3},[0-9]{1,3}$", options: .regularExpression) != nil,
                  let level = integer(row["level"]), (0...100).contains(level) else { return nil }
            let binding = WatchRelayBinding(watchID: watch, phoneID: phone)
            guard binding.isValid, seen.insert(watch).inserted else { return nil }
            samples.append(WatchRelaySample(binding: binding, name: name, level: level))
        }
        return WatchRelaySnapshot(samples: samples, receivedAt: receivedAt)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }

    static func isWatchProfile(_ device: BatteryDevice, known: [String: WatchRelayBinding]) -> Bool {
        known[device.id] != nil || BluetoothBatterySnapshot.nameKey(device.name)?.hasPrefix("apple watch") == true
    }

    static func merging(_ snapshot: WatchRelaySnapshot, before: [BatteryDevice], after: [BatteryDevice],
                        known: [String: WatchRelayBinding], now: Date = Date()) -> [BatteryDevice] {
        let nativeAfter = after.map { $0.droppingWatchRelay() }
        let earlier = Dictionary(grouping: before, by: \.id)
        let current = Dictionary(grouping: after, by: \.id)
        let oldNames = Dictionary(grouping: before, by: { BluetoothBatterySnapshot.nameKey($0.name) })
        let newNames = Dictionary(grouping: after, by: { BluetoothBatterySnapshot.nameKey($0.name) })
        let sourceNames = Dictionary(grouping: snapshot.samples, by: { BluetoothBatterySnapshot.nameKey($0.name) })
        let sourceIDs = Dictionary(grouping: snapshot.samples, by: { $0.binding.watchID })
        let owners = Dictionary(grouping: known.values, by: \.watchID)
        return nativeAfter.map { device in
            guard isWatchProfile(device, known: known), device.level == nil, device.components == nil,
                  current[device.id]?.count == 1, let prior = earlier[device.id], prior.count == 1,
                  prior.first?.name == device.name,
                  let name = BluetoothBatterySnapshot.nameKey(device.name),
                  oldNames[name]?.count == 1, newNames[name]?.count == 1,
                  let matches = sourceNames[name], matches.count == 1, let sample = matches.first,
                  sourceIDs[sample.binding.watchID]?.count == 1,
                  known[device.id].map({ $0 == sample.binding && owners[$0.watchID]?.count == 1 })
                    ?? (owners[sample.binding.watchID] == nil) else { return device }
            let reading = WatchRelayReading(binding: sample.binding, level: sample.level, receivedAt: snapshot.receivedAt)
            guard reading.isRecent(at: now) else { return device }
            return BatteryDevice(id: device.id, name: device.name, connected: device.connected, level: nil,
                                 watchRelay: reading)
        }
    }
}
