import Combine
import CoreBluetooth
import DivelogCore

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String?
    let rssi: Int
    let knownComputer: KnownDiveComputer?
    var lastSeen: Date
}

class BLEScanner: NSObject, ObservableObject {
    @Published var managerState: CBManagerState = .unknown
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedPeripheral: CBPeripheral?
    /// Published once service/characteristic discovery completes after connection.
    @Published var transport: BLEPeripheralTransport?
    /// The known dive computer matched during scan (available after connection).
    @Published var connectedKnownComputer: KnownDiveComputer?

    private var centralManager: CBCentralManager!
    /// Strong references to peripherals (CoreBluetooth doesn't retain them).
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// The known computer matched for the peripheral being connected.
    /// Accessed from nonisolated CBPeripheralDelegate callbacks; safe because
    /// it is only written on the main actor before connection and read from
    /// CoreBluetooth callbacks that fire sequentially after connection.
    nonisolated(unsafe) private var pendingKnownComputer: KnownDiveComputer?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        discoveredDevices.removeAll()
        peripherals.removeAll()
        let serviceUUIDs = KnownDiveComputer.allServiceUUIDs.map { CBUUID(string: $0) }
        centralManager.scanForPeripherals(
            withServices: serviceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
    }

    func connect(_ peripheral: CBPeripheral) {
        stopScanning()
        // Find the matching known computer for characteristic discovery
        if let device = discoveredDevices.first(where: { $0.peripheral.identifier == peripheral.identifier }) {
            pendingKnownComputer = device.knownComputer
        }
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let t = transport {
            try? t.close()
        }
        transport = nil
        connectedKnownComputer = nil
        pendingKnownComputer = nil
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor [weak self] in
            self?.managerState = state
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssiValue = RSSI.intValue
        let deviceId = peripheral.identifier
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        let knownComputer = serviceUUIDs?.lazy.compactMap { uuid in
            KnownDiveComputer.from(serviceUUID: uuid.uuidString)
        }.first
        let displayName = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.peripherals[deviceId] = peripheral

            if let index = self.discoveredDevices.firstIndex(where: { $0.id == deviceId }) {
                self.discoveredDevices[index].lastSeen = Date()
                if rssiValue != 127 {
                    self.discoveredDevices[index] = DiscoveredDevice(
                        id: deviceId,
                        peripheral: peripheral,
                        name: displayName ?? self.discoveredDevices[index].name,
                        rssi: rssiValue,
                        knownComputer: knownComputer ?? self.discoveredDevices[index].knownComputer,
                        lastSeen: Date()
                    )
                }
            } else {
                self.discoveredDevices.append(DiscoveredDevice(
                    id: deviceId,
                    peripheral: peripheral,
                    name: displayName,
                    rssi: rssiValue,
                    knownComputer: knownComputer,
                    lastSeen: Date()
                ))
            }

            self.discoveredDevices.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        // After GATT connection, discover services for data transfer
        let knownComputer = pendingKnownComputer
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectedPeripheral = peripheral
            peripheral.delegate = self

            if let known = knownComputer {
                let serviceUUID = CBUUID(string: known.serviceUUID)
                peripheral.discoverServices([serviceUUID])
            } else {
                // No known computer — discover all services
                peripheral.discoverServices(nil)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.connectedPeripheral = nil
            self?.pendingKnownComputer = nil
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let disconnectedId = peripheral.identifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.connectedPeripheral?.identifier == disconnectedId {
                if let t = self.transport {
                    try? t.close()
                }
                self.transport = nil
                self.connectedKnownComputer = nil
                self.connectedPeripheral = nil
            }
        }
    }
}

// MARK: - CBPeripheralDelegate (Service/Characteristic Discovery)

extension BLEScanner: CBPeripheralDelegate {
    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard error == nil, let services = peripheral.services else { return }

        let knownComputer = pendingKnownComputer

        for service in services {
            if let known = knownComputer {
                let targetCharUUID = CBUUID(string: known.characteristicUUID)
                peripheral.discoverCharacteristics([targetCharUUID], for: service)
            } else {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else { return }

        let knownComputer = pendingKnownComputer

        // Find the data transfer characteristic
        let targetChar: CBCharacteristic? = {
            if let known = knownComputer {
                let targetUUID = CBUUID(string: known.characteristicUUID)
                return characteristics.first { $0.uuid == targetUUID }
            }
            // Fallback: pick the first characteristic that supports notify + write
            return characteristics.first { char in
                char.properties.contains(.notify) &&
                    (char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse))
            }
        }()

        guard let characteristic = targetChar else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let bleTransport = BLEPeripheralTransport(
                peripheral: peripheral,
                characteristic: characteristic
            )
            self.transport = bleTransport
            self.connectedKnownComputer = knownComputer
        }
    }
}
