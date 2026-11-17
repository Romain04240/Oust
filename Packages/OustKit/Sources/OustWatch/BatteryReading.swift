import Foundation
import IOKit.ps

public struct BatteryReading: Sendable, Equatable {
    public enum State: String, Sendable {
        case onBattery, charging, charged, onAC

        public var localizationKey: String { "menubar.battery_state.\(rawValue)" }
    }

    public let level: Int
    public let state: State
    public let minutes: Int?

    public init(level: Int, state: State, minutes: Int? = nil) {
        self.level = level
        self.state = state
        self.minutes = minutes
    }

    public var symbol: String {
        if state == .charging { return "battery.100percent.bolt" }
        switch level {
        case 0...12: return "battery.0percent"
        case 13...37: return "battery.25percent"
        case 38...62: return "battery.50percent"
        case 63...87: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    public static func current() -> Self? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [AnyObject] else { return nil }
        return sources.lazy.compactMap { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any] else { return nil }
            return Self.parse(description, fallbackTimeRemaining: IOPSGetTimeRemainingEstimate)
        }.first
    }

    static func parse(_ description: [String: Any], fallbackTimeRemaining: () -> Double = { -1 }) -> Self? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              description[kIOPSIsPresentKey] as? Bool == true,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0,
              (0...maximum).contains(current) else { return nil }
        let level = Int((Double(current) / Double(maximum) * 100).rounded())
        let state: State
        let timeKey: String?
        switch description[kIOPSPowerSourceStateKey] as? String {
        case kIOPSBatteryPowerValue:
            state = .onBattery
            timeKey = kIOPSTimeToEmptyKey
        case kIOPSACPowerValue:
            if description[kIOPSIsChargingKey] as? Bool == true {
                state = .charging
                timeKey = kIOPSTimeToFullChargeKey
            } else {
                state = description[kIOPSIsChargedKey] as? Bool == true ? .charged : .onAC
                timeKey = nil
            }
        default: return nil
        }
        var minutes = timeKey.flatMap { description[$0] as? Int }.flatMap { (1...1440).contains($0) ? $0 : nil }
        if minutes == nil, state == .onBattery {
            let seconds = fallbackTimeRemaining()
            if (1...86_400).contains(seconds) { minutes = Int((seconds / 60).rounded(.up)) }
        }
        return Self(level: level, state: state, minutes: minutes)
    }
}

/// La source est inscrite uniquement sur la boucle principale, puis invalidée
/// avant que l'objet qui sert de contexte puisse disparaître.
@MainActor
public final class BatteryPowerObserver {
    private let changed: @MainActor () -> Void
    private var source: CFRunLoopSource?

    public init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<BatteryPowerObserver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observer.changed() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    isolated deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
    }
}
