import Foundation

/// Une tentative externe persistée reste ambiguë après un arrêt : pas de rejeu.
public struct AlertDeliveryLedger: Codable, Sendable {
    public enum Channel: String, Codable, Sendable { case capsule, notification }
    private var attempts: Set<String> = []
    private var failures: Set<String> = []
    public init() {}
    public func contains(_ id: String, channel: Channel) -> Bool { attempts.contains(channel.rawValue + ":" + id) }
    public mutating func reserve(_ id: String, channel: Channel) -> Bool { attempts.insert(channel.rawValue + ":" + id).inserted }
    public mutating func failed(_ id: String, channel: Channel) { attempts.remove(channel.rawValue + ":" + id) }
    public mutating func completed(_ id: String, channel: Channel, accepted: Bool) {
        if !accepted { failed(id, channel: channel); failures.insert(channel.rawValue + ":" + id) }
    }
    public func canAttempt(_ id: String, channel: Channel) -> Bool {
        !contains(id, channel: channel) && !failures.contains(channel.rawValue + ":" + id)
    }
    public mutating func retryFailures() { failures.removeAll() }
    private enum CodingKeys: String, CodingKey { case attempts, failures }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attempts = try c.decodeIfPresent(Set<String>.self, forKey: .attempts) ?? []
        failures = try c.decodeIfPresent(Set<String>.self, forKey: .failures) ?? []
    }
}

public struct PowerAlertEpisodes: Codable, Sendable {
    public private(set) var lowID: String?
    public private(set) var rearm = 23
    private var previousOnBattery: Bool?
    private var previousLevel: Int?
    private var previousCharging = false
    private var chargedSent = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case lowID, rearm, chargedSent }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowID = try c.decodeIfPresent(String.self, forKey: .lowID)
        rearm = try c.decodeIfPresent(Int.self, forKey: .rearm) ?? 23
        chargedSent = try c.decodeIfPresent(Bool.self, forKey: .chargedSent) ?? false
    }
    public mutating func baseline() { previousOnBattery = nil; previousLevel = nil; previousCharging = false }
    /// Après confirmation native, jamais depuis les chiffres d'affichage en cache.
    public mutating func observe(_ reading: BatteryReading?, settings: BatteryAlertSettings) -> [(String, BatteryAlert)] {
        guard let reading, (0...100).contains(reading.level) else { baseline(); return [] }
        let onBattery = reading.state == .onBattery
        let oldSource = previousOnBattery, oldLevel = previousLevel, oldCharging = previousCharging
        defer { previousOnBattery = onBattery; previousLevel = reading.level; previousCharging = reading.state == .charging }
        if lowID != nil {
            rearm = max(rearm, min(100, settings.low + 3))
            if reading.level >= rearm { lowID = nil }
        }
        let newlyLow = lowID == nil
        var result: [(String, BatteryAlert)] = []
        if settings.warnsLow, onBattery, reading.level <= settings.low {
            if lowID == nil { lowID = UUID().uuidString; rearm = min(100, settings.low + 3) }
            if let lowID { result.append((lowID, .low(reading))) }
        }
        if let oldSource, oldSource != onBattery {
            if onBattery, settings.warnsDisconnected {
                if newlyLow, let first = result.first { result = [(first.0, .disconnectedLow(reading))] }
                else { result.append((UUID().uuidString, .disconnected(reading))) }
            } else if !onBattery, settings.warnsConnected { result.append((UUID().uuidString, .connected(reading))) }
        }
        if onBattery { chargedSent = false }
        if settings.warnsCharged, !chargedSent, oldCharging, let oldLevel, oldLevel < settings.high, !onBattery, reading.level >= settings.high {
            chargedSent = true
            result.append((UUID().uuidString, .charged(reading)))
        }
        return result
    }
}

/// Les identités restent celles des composants, même lorsque l'affichage fusionne.
public struct PowerAlertComponent: Sendable, Codable {
    public let id: String
    public let alert: BatteryAlert
    public init(id: String, alert: BatteryAlert) { self.id = id; self.alert = alert }
    public static func split(_ events: [(String, BatteryAlert)]) -> [Self] {
        events.flatMap { id, alert -> [Self] in
            if case .disconnectedLow(let r) = alert {
                return [Self(id: id, alert: .low(r)), Self(id: UUID().uuidString, alert: .disconnected(r))]
            }
            return [Self(id: id, alert: alert)]
        }
    }
    public static func message(_ components: [Self]) -> BatteryAlert? {
        if let low = components.first(where: { if case .low = $0.alert { true } else { false } }) {
            if components.contains(where: { if case .disconnected = $0.alert { true } else { false } }) { return .disconnectedLow(low.alert.reading) }
            return low.alert
        }
        return components.first?.alert
    }
}

/// Seulement les erreurs certaines, jamais les envois ambigus après interruption.
public struct FailedPowerIntents: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let components: [PowerAlertComponent]
        public let observedAt: Date
        public let occurrence: UUID?
        public let deadline: ContinuousClock.Instant?
        private enum CodingKeys: String, CodingKey { case components, observedAt, occurrence }
        init(components: [PowerAlertComponent], observedAt: Date, occurrence: UUID, deadline: ContinuousClock.Instant) {
            self.components = components; self.observedAt = observedAt; self.occurrence = occurrence; self.deadline = deadline
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            components = try c.decode([PowerAlertComponent].self, forKey: .components)
            observedAt = try c.decode(Date.self, forKey: .observedAt)
            occurrence = try c.decodeIfPresent(UUID.self, forKey: .occurrence)
            // Une relance ne prouve pas la fraîcheur monotone de l'ancienne session.
            deadline = nil
        }
    }
    private var entries: [String: Entry] = [:]
    public init() {}
    public mutating func record(id: String, components: [PowerAlertComponent], observedAt: Date,
                                occurrence: UUID, deadline: ContinuousClock.Instant) {
        entries[id] = Entry(components: components, observedAt: observedAt, occurrence: occurrence, deadline: deadline)
    }
    public mutating func remove(_ id: String) { entries[id] = nil }
    public mutating func pending(now: ContinuousClock.Instant, occurrence: UUID) -> [Entry] {
        entries = entries.filter { $0.value.occurrence == occurrence && $0.value.deadline.map { now < $0 } == true }
        return Array(entries.values)
    }
}

/// Le contenu et son acquittement décrivent le même instantané. La préparation
/// ne consomme rien si le panneau attend encore ou si aucun écran n'est disponible.
@MainActor public struct PreparedWatchAlert<Value: Sendable> {
    public let value: Value
    public let acknowledge: @MainActor () -> Bool
    public init(value: Value, acknowledge: @escaping @MainActor () -> Bool) {
        self.value = value; self.acknowledge = acknowledge
    }
}
