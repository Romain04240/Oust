import CoreFoundation
import Foundation
import IOKit
import IOKit.ps
import OustCore

public struct BatteryDiagnostics: Sendable, Equatable {
    public enum InputPower: Sendable, Equatable {
        case measured(Double)
        case estimated(Double)
    }

    public let temperature: Double?
    public let source: BatteryReading.State?
    public let nominalWatts: Int?
    public let inputPower: InputPower?
    public let macWatts: Double?
    public let batteryWatts: Double?

    public static func read() async -> Self? {
        await checkStorageIO {
            let source = BatteryReading.current()
            let pack = properties(for: "AppleSmartBatteryPack")?["BatteryData"] as? [String: Any]
            let battery = properties(for: "AppleSmartBattery")
            // Si le secteur a changé pendant la lecture, ne pas mélanger les deux états.
            guard source?.state == BatteryReading.current()?.state else { return nil }
            return parseSnapshot(pack: pack, battery: battery, state: source?.state,
                                 allowLegacyTemperature: supportsLegacyTemperature)
        } ?? nil
    }

    static func parseSnapshot(pack: [String: Any]?, battery: [String: Any]?, state: BatteryReading.State?,
                              allowLegacyTemperature: Bool) -> Self? {
        // Le nominal et l'entrée doivent provenir de la même copie du registre,
        // même si deux adaptateurs successifs laissent le Mac dans l'état « en charge ».
        let plugged = battery?["ExternalConnected"] as? Bool
        let onAC = state.map { $0 != .onBattery } == true && plugged == true
        let adapter = onAC ? battery?["AdapterDetails"] as? [String: Any] : nil
        let telemetry = onAC ? battery?["PowerTelemetryData"] as? [String: Any] : nil
        let legacyPack = allowLegacyTemperature ? battery : nil
        let temperaturePack = pack?["Temperature"] == nil ? legacyPack : pack
        let verifiedBattery = (state == .onBattery && plugged == false) || onAC ? battery : nil
        return parse(adapter: adapter, pack: temperaturePack, telemetry: telemetry,
                     battery: verifiedBattery, state: state)
    }

    private static var supportsLegacyTemperature: Bool {
        #if arch(arm64)
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
        #else
        false
        #endif
    }

    static func parse(adapter: [String: Any]?, pack: [String: Any]?, telemetry: [String: Any]?,
                      battery: [String: Any]? = nil, state: BatteryReading.State? = nil) -> Self? {
        let nominal = adapter?[kIOPSPowerAdapterWattsKey] as? Int
        let nominalWatts = nominal.flatMap { (1...300).contains($0) ? $0 : nil }
        // Ce champ du pack a été comparé à l'affichage en degrés sur macOS 27.
        let temperature = (pack?["Temperature"] as? Int)
            .flatMap { (-2_000...8_000).contains($0) && $0 != 0 ? Double($0) / 100 : nil }

        var inputPower: InputPower?
        var macWatts: Double?
        if let telemetry,
           let voltage = telemetry["SystemVoltageIn"] as? Int,
           let current = telemetry["SystemCurrentIn"] as? Int,
           (1_000...60_000).contains(voltage), (0...10_000).contains(current) {
            let expected = Double(voltage) * Double(current) / 1_000
            let limit = (nominalWatts ?? 300) * 1_100
            if let input = telemetry["SystemPowerIn"] as? Int, (0...limit).contains(input),
               abs(expected - Double(input)) <= max(500, expected * 0.08) {
                inputPower = .measured(Double(input) / 1_000)
                if let load = telemetry["SystemLoad"] as? Int, (0...input).contains(load) {
                    macWatts = Double(load) / 1_000
                }
            } else if telemetry["SystemPowerIn"] == nil, expected > 0, expected <= Double(limit) {
                inputPower = .estimated(expected / 1_000)
            }
        }
        let batteryWatts = batteryPower(battery, state: state)
        guard temperature != nil || nominalWatts != nil || inputPower != nil || batteryWatts != nil else { return nil }
        return Self(temperature: temperature, source: state, nominalWatts: nominalWatts, inputPower: inputPower,
                    macWatts: macWatts, batteryWatts: batteryWatts)
    }

    /// IOPMPowerSource publie la tension en mV et le courant signé en mA.
    /// Leur produit estime seulement la puissance au niveau de la batterie.
    private static func batteryPower(_ battery: [String: Any]?, state: BatteryReading.State?) -> Double? {
        guard let voltage = battery?["Voltage"] as? Int, (1_000...30_000).contains(voltage),
              let raw = battery?["Amperage"] as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID(),
              let current = Int32(raw.stringValue) ?? UInt32(raw.stringValue).map(Int32.init(bitPattern:)),
              (-30_000...30_000).contains(current),
              (state == .onBattery && current < 0 || state == .charging && current > 0) else { return nil }
        return Double(voltage) * Double(abs(current)) / 1_000_000
    }

    private static func properties(for serviceClass: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return properties?.takeRetainedValue() as? [String: Any]
    }
}

public struct ConnectedBattery: Sendable, Equatable, Identifiable {
    public let id: UInt64
    public let name: String
    public let level: Int
    let deviceID: String?

    public static func read() async -> [Self]? {
        await checkStorageIO {
            var entries: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                               &entries) == KERN_SUCCESS else { return [] }
            defer { IOObjectRelease(entries) }
            var batteries: [Self] = []
            while case let service = IOIteratorNext(entries), service != 0 {
                defer { IOObjectRelease(service) }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                      let name = property("Product", service: service) as? String,
                      !name.isEmpty,
                      let level = property("BatteryPercent", service: service) as? Int,
                      (0...100).contains(level) else { continue }
                let address = property("DeviceAddress", service: service) as? String
                batteries.append(Self(id: id, name: name, level: level, deviceID: address.flatMap(BatteryDevice.id(for:))))
            }
            return batteries.sorted { ($0.level, $0.id) < ($1.level, $1.id) }
        }
    }

    private static func property(_ key: String, service: io_service_t) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
