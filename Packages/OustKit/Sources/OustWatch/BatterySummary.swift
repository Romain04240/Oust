import CoreFoundation
import Foundation
import OustCore

/// Les deux mesures utiles pour suivre l’usure d’un portable, quand macOS les fournit.
public struct BatterySummary: Equatable, Sendable {
    public let maximumCapacity: Int?
    public let cycleCount: Int?

    public static func read() async -> Self? {
        let result = await Command.run("/usr/sbin/system_profiler", ["-json", "SPPowerDataType"], timeout: 4)
        guard result.succeeded, !Task.isCancelled else { return nil }
        return parse(result.stdout)
    }

    static func parse(_ data: Data) -> Self? {
        guard let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = report["SPPowerDataType"] as? [[String: Any]] else { return nil }
        let batteries = sections.compactMap { $0["sppower_battery_health_info"] as? [String: Any] }
        guard batteries.count == 1, let battery = batteries.first else { return nil }

        let rawCycles = battery["sppower_battery_cycle_count"] as? NSNumber
        let cycles = rawCycles.flatMap { value in
            CFGetTypeID(value) != CFBooleanGetTypeID() ? Int(value.stringValue) : nil
        }.flatMap { $0 >= 0 ? $0 : nil }
        let capacity = (battery["sppower_battery_health_maximum_capacity"] as? String).flatMap { reported -> Int? in
            let trimmed = reported.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix("%") else { return nil }
            let number = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
            guard let percent = Int(number), (1...100).contains(percent) else { return nil }
            return percent
        }
        guard capacity != nil || cycles != nil else { return nil }
        return Self(maximumCapacity: capacity, cycleCount: cycles)
    }
}
