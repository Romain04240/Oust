import Foundation

public enum MenuBarContents: String, Codable, CaseIterable, Identifiable, Sendable {
    case storage, battery, both

    public var id: Self { self }
    public var showsStorage: Bool { self != .battery }
    public var showsBattery: Bool { self != .storage }
    public var localizationKey: String { "settings.general.menubar_\(rawValue)" }
}

public struct BatteryAlertSettings: Sendable, Hashable, Codable {
    public var warnsLow: Bool
    public var warnsCharged: Bool
    public var low: Int
    public var high: Int

    public init(warnsLow: Bool = false, warnsCharged: Bool = false, low: Int = 20, high: Int = 80) {
        self.warnsLow = warnsLow
        self.warnsCharged = warnsCharged
        self.low = min(99, max(1, low))
        self.high = min(100, max(self.low + 1, high))
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(warnsLow: try fields.decodeIfPresent(Bool.self, forKey: .warnsLow) ?? false,
                  warnsCharged: try fields.decodeIfPresent(Bool.self, forKey: .warnsCharged) ?? false,
                  low: try fields.decodeIfPresent(Int.self, forKey: .low) ?? 20,
                  high: try fields.decodeIfPresent(Int.self, forKey: .high) ?? 80)
    }
}

public enum BatteryAlert: Sendable, Equatable {
    case low(BatteryReading)
    case charged(BatteryReading)

    public func updated(for reading: BatteryReading, settings: BatteryAlertSettings) -> Self? {
        switch self {
        case .low where settings.warnsLow && reading.state == .onBattery && reading.level <= settings.low:
            return .low(reading)
        case .charged where settings.warnsCharged && reading.state != .onBattery && reading.level >= settings.high:
            return .charged(reading)
        default:
            return nil
        }
    }
}

public struct BatteryAlertTracker: Sendable {
    private var previous: BatteryReading?
    private var lowSent = false
    private var chargedSent = false

    public init() {}

    public mutating func resetBaseline() { previous = nil }

    public mutating func observe(_ reading: BatteryReading?, settings: BatteryAlertSettings) -> BatteryAlert? {
        defer { previous = reading }
        guard let reading else { return nil }
        if reading.level >= min(settings.low + 3, 100) { lowSent = false }
        if reading.state == .onBattery { chargedSent = false }
        guard let previous else { return nil }

        if settings.warnsLow, !lowSent, previous.state == .onBattery, reading.state == .onBattery,
           previous.level > settings.low, reading.level <= settings.low {
            lowSent = true
            return .low(reading)
        }
        if settings.warnsCharged, !chargedSent, previous.state == .charging, reading.state != .onBattery,
           previous.level < settings.high, reading.level >= settings.high {
            chargedSent = true
            return .charged(reading)
        }
        return nil
    }
}
