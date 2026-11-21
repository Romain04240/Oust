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
    public var warnsConnected: Bool
    public var warnsDisconnected: Bool
    public var notifies: Bool
    public var low: Int
    public var high: Int

    public init(warnsLow: Bool = false, warnsCharged: Bool = false, low: Int = 20, high: Int = 80, warnsConnected: Bool = false, warnsDisconnected: Bool = false, notifies: Bool = false) {
        self.warnsConnected = warnsConnected
        self.warnsDisconnected = warnsDisconnected
        self.notifies = notifies
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
                  high: try fields.decodeIfPresent(Int.self, forKey: .high) ?? 80,
                  warnsConnected: try fields.decodeIfPresent(Bool.self, forKey: .warnsConnected) ?? false,
                  warnsDisconnected: try fields.decodeIfPresent(Bool.self, forKey: .warnsDisconnected) ?? false,
                  notifies: try fields.decodeIfPresent(Bool.self, forKey: .notifies) ?? false)
    }
}

public enum BatteryAlert: Sendable, Equatable, Codable {
    case low(BatteryReading)
    case charged(BatteryReading)
    case connected(BatteryReading)
    case disconnected(BatteryReading)
    case disconnectedLow(BatteryReading)

    public var reading: BatteryReading {
        switch self {
        case .low(let r), .charged(let r), .connected(let r), .disconnected(let r), .disconnectedLow(let r): r
        }
    }

    public func updated(for reading: BatteryReading, settings: BatteryAlertSettings) -> Self? {
        switch self {
        case .low where settings.warnsLow && reading.state == .onBattery && reading.level <= settings.low:
            return .low(reading)
        case .charged where settings.warnsCharged && reading.state != .onBattery && reading.level >= settings.high:
            return .charged(reading)
        case .connected where settings.warnsConnected && reading.state != .onBattery:
            return .connected(reading)
        case .disconnected where settings.warnsDisconnected && reading.state == .onBattery:
            return .disconnected(reading)
        case .disconnectedLow where reading.state == .onBattery:
            if settings.warnsLow && reading.level <= settings.low {
                return settings.warnsDisconnected ? .disconnectedLow(reading) : .low(reading)
            }
            return settings.warnsDisconnected ? .disconnected(reading) : nil
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
