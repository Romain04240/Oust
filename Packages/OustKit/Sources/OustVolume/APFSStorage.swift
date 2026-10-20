import CoreFoundation
import Foundation
import OustCore

/// Les volumes qui se partagent un conteneur APFS. Leurs consommations sont
/// des mesures de disque, distinctes des catégories de fichiers de l'analyse.
public struct APFSContainerUsage: Sendable {
    public let identifier: String
    public let capacity: Int64
    public let free: Int64
    public let selectedVolume: String
    public let volumes: [APFSVolumeUsage]
    public let metadataBytes: Int64?

    public static func read(for mount: URL) async -> APFSContainerUsage? {
        let info = await Command.run("/usr/sbin/diskutil", ["info", "-plist", mount.path], timeout: 10)
        guard info.succeeded,
              let object = try? PropertyListSerialization.propertyList(from: info.stdout, format: nil) as? [String: Any],
              let reference = object["APFSContainerReference"] as? String,
              let selected = object["DeviceIdentifier"] as? String else { return nil }
        let list = await Command.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 10)
        guard list.succeeded else { return nil }
        return parse(list.stdout, reference: reference, selectedVolume: selected)
    }

    static func parse(_ data: Data, reference: String, selectedVolume: String) -> APFSContainerUsage? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]],
              let container = containers.first(where: { $0["ContainerReference"] as? String == reference }),
              let capacity = bytes(container["CapacityCeiling"]), let free = bytes(container["CapacityFree"]),
              free <= capacity, let entries = container["Volumes"] as? [[String: Any]] else { return nil }
        var volumes: [APFSVolumeUsage] = []
        var total: Int64 = 0
        for entry in entries {
            guard let identifier = entry["DeviceIdentifier"] as? String,
                  let name = entry["Name"] as? String,
                  let used = bytes(entry["CapacityInUse"]), used <= capacity else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(used)
            guard !overflow, !volumes.contains(where: { $0.id == identifier }) else { return nil }
            total = sum
            volumes.append(APFSVolumeUsage(id: identifier, name: name, used: used,
                                           roles: entry["Roles"] as? [String] ?? []))
        }
        guard volumes.contains(where: { $0.id == selectedVolume }) else { return nil }
        let occupied = capacity - free
        return APFSContainerUsage(identifier: reference, capacity: capacity, free: free, selectedVolume: selectedVolume,
                                  volumes: volumes.sorted { $0.used > $1.used },
                                  metadataBytes: total <= occupied ? occupied - total : nil)
    }

    private static func bytes(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue < Double(Int64.max) else { return nil }
        return number.int64Value
    }
}

public struct APFSVolumeUsage: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let used: Int64
    public let roles: [String]

    public var roleKey: String {
        for (role, key) in [("System", "system"), ("Data", "data"), ("VM", "memory"),
                            ("Preboot", "startup"), ("Recovery", "recovery"), ("Update", "updates")] {
            if roles.contains(role) { return "storage.apfs." + key }
        }
        return "storage.apfs.other"
    }
}
