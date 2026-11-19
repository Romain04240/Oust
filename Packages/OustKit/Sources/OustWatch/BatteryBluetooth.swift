import CoreBluetooth
import Foundation

public struct BluetoothBatterySample: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let level: Int

    public init(id: UUID, name: String?, level: Int) {
        self.id = id
        self.name = name
        self.level = level
    }
}

public struct BluetoothBatterySnapshot: Sendable {
    public let samples: [BluetoothBatterySample]
    let names: [UUID: String]

    public init(samples: [BluetoothBatterySample], names: [UUID: String]) {
        self.samples = samples
        self.names = names
    }

    public func unambiguous(_ peer: UUID) -> Bool {
        guard let name = names[peer], let key = Self.nameKey(name) else { return false }
        return names.values.filter { Self.nameKey($0) == key }.count == 1
    }

    public static func nameKey(_ name: String) -> String? {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                    locale: Locale(identifier: "en_US_POSIX"))
    }
}

public enum BatteryBluetooth {
    @MainActor public static var needsAuthorization: Bool { CBManager.authorization == .notDetermined }
    /// Les appareils sont déjà connectés au système. Une connexion locale
    /// bornée au processus permet de lire la caractéristique, sans balayage.
    @MainActor public static func read(peers: Set<UUID>?, requestPermission: Bool = false) async -> [BluetoothBatterySample] {
        await snapshot(peers: peers, requestPermission: requestPermission).samples
    }

    @MainActor public static func snapshot(peers: Set<UUID>?, requestPermission: Bool = false, knownPeers: Set<UUID> = []) async -> BluetoothBatterySnapshot {
        let authorization = CBManager.authorization
        guard authorization == .allowedAlways || (requestPermission && authorization == .notDetermined),
              peers?.isEmpty != true, !Task.isCancelled else { return .init(samples: [], names: [:]) }
        return await perform(BatteryBluetoothRead(peers: peers, knownPeers: knownPeers))
    }

    @MainActor private static func perform(_ reader: BatteryBluetoothRead) async -> BluetoothBatterySnapshot {
        return await withTaskCancellationHandler {
            await reader.read()
        } onCancel: {
            Task { @MainActor in reader.finish() }
        }
    }
}

@MainActor private final class BatteryBluetoothRead: NSObject,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private let service = CBUUID(string: "180F")
    private let level = CBUUID(string: "2A19")
    private let peers: Set<UUID>?
    private let knownPeers: Set<UUID>
    private var central: CBCentralManager?
    private var request: CheckedContinuation<BluetoothBatterySnapshot, Never>?
    private var timeout: Task<Void, Never>?
    private var queried = false
    private var devices: [UUID: CBPeripheral] = [:]
    private var samples: [BluetoothBatterySample] = []
    private var names: [UUID: String] = [:]
    init(peers: Set<UUID>?, knownPeers: Set<UUID>) {
        self.peers = peers
        self.knownPeers = knownPeers
    }

    func read() async -> BluetoothBatterySnapshot {
        guard !Task.isCancelled else { return .init(samples: [], names: [:]) }
        return await withCheckedContinuation { continuation in
            request = continuation
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                self?.finish()
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard request != nil, central === self.central else { return }
        switch central.state {
        case .poweredOn:
            guard !queried else { return }
            queried = true
            let connected = central.retrieveConnectedPeripherals(withServices: [service])
            let remembered = central.retrievePeripherals(withIdentifiers: Array(knownPeers))
            for device in connected + remembered
            where (peers?.contains(device.identifier) ?? true) && devices[device.identifier] == nil {
                devices[device.identifier] = device
                names[device.identifier] = device.name
                device.delegate = self
                central.connect(device, options: nil)
            }
            if devices.isEmpty { finish() }
        case .unknown, .resetting: break
        default: finish()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard request != nil, central === self.central, devices[peripheral.identifier] === peripheral else { return }
        if names[peripheral.identifier] == nil { names[peripheral.identifier] = peripheral.name }
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        complete(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        complete(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard request != nil, devices[peripheral.identifier] === peripheral else { return }
        let batteries = peripheral.services?.filter { $0.uuid == service } ?? []
        guard error == nil, batteries.count == 1, let battery = batteries.first else {
            complete(peripheral)
            return
        }
        peripheral.discoverCharacteristics([level], for: battery)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard request != nil, devices[peripheral.identifier] === peripheral else { return }
        let readings = service.characteristics?.filter { $0.uuid == level } ?? []
        guard error == nil, service.uuid == self.service, readings.count == 1, let reading = readings.first else {
            complete(peripheral)
            return
        }
        peripheral.readValue(for: reading)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard request != nil, devices[peripheral.identifier] === peripheral, characteristic.uuid == level,
              characteristic.service?.uuid == service else { return }
        if error == nil, let data = characteristic.value, data.count == 1, let value = data.first, value <= 100 {
            guard peripheral.state == .connected else { complete(peripheral); return }
            samples.append(BluetoothBatterySample(id: peripheral.identifier, name: peripheral.name, level: Int(value)))
        }
        complete(peripheral)
    }

    private func complete(_ device: CBPeripheral) {
        guard devices.removeValue(forKey: device.identifier) != nil else { return }
        device.delegate = nil
        central?.cancelPeripheralConnection(device)
        if devices.isEmpty { finish() }
    }

    func finish() {
        guard let request else { return }
        self.request = nil
        timeout?.cancel()
        timeout = nil
        central?.delegate = nil
        for device in devices.values {
            device.delegate = nil
            central?.cancelPeripheralConnection(device)
        }
        devices.removeAll()
        central = nil
        request.resume(returning: BluetoothBatterySnapshot(samples: samples, names: names))
    }
}
