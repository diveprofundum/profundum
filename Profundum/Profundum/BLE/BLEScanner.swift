import Combine
import CoreBluetooth
import DivelogCore
import os

private let scanLog = Logger(subsystem: "com.divelog.profundum", category: "BLEScanner")

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String?
    let rssi: Int
    let knownComputer: KnownDiveComputer?
    var lastSeen: Date
}

/// Manages BLE scanning, connection, and service/characteristic discovery for
/// dive computers.
///
/// ## Thread Safety
///
/// `BLEScanner` is an `ObservableObject` whose `@Published` properties and
/// mutable state (`isConnecting`, `pendingKnownComputer`) are only mutated
/// on the **MainActor**. CoreBluetooth delegate callbacks arrive on an
/// unspecified queue (`CBCentralManager(delegate:queue: nil)` → main queue),
/// but all state mutations are dispatched to `@MainActor` via `Task`.
///
/// `pendingKnownComputer` is `nonisolated(unsafe)` because it is read from
/// nonisolated delegate callbacks. Safety is ensured by:
/// 1. Writes only happen on the MainActor (in `connect()`, `disconnect()`, and
///    delegate `Task { @MainActor ... }` blocks).
/// 2. `isConnecting` prevents concurrent `connect()` calls, so the value
///    cannot change while connection callbacks are in flight.
/// 3. Delegate callbacks capture the value into a local `let` before dispatching.
class BLEScanner: NSObject, ObservableObject {
    @Published var managerState: CBManagerState = .unknown
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedPeripheral: CBPeripheral?
    /// Published once service/characteristic discovery completes after connection.
    @Published var transport: BLEPeripheralTransport?
    /// The known dive computer matched during scan (available after connection).
    @Published var connectedKnownComputer: KnownDiveComputer?

    /// Guards against overlapping `connect()` calls. MainActor-isolated.
    private var isConnecting = false

    private var centralManager: CBCentralManager!
    /// Strong references to peripherals (CoreBluetooth doesn't retain them).
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// The known computer matched for the peripheral being connected.
    /// Accessed from nonisolated CBPeripheralDelegate callbacks; safe because
    /// it is only written on the main actor before connection and read from
    /// CoreBluetooth callbacks that fire sequentially after connection.
    /// See class-level doc comment for the full thread safety rationale.
    nonisolated(unsafe) private var pendingKnownComputer: KnownDiveComputer?

    /// Accumulated Rx/Tx characteristics across service discovery callbacks.
    /// For split Rx/Tx devices (e.g. Halcyon), Rx and Tx may be in different
    /// GATT services. We accumulate them across `didDiscoverCharacteristicsFor`
    /// callbacks and only create the transport when both are found.
    /// Same safety model as `pendingKnownComputer` — see class-level doc.
    nonisolated(unsafe) private var pendingRxChar: CBCharacteristic?
    nonisolated(unsafe) private var pendingTxChar: CBCharacteristic?

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
        guard !isConnecting else { return }
        isConnecting = true
        stopScanning()
        // Find the matching known computer for characteristic discovery
        if let device = discoveredDevices.first(where: { $0.peripheral.identifier == peripheral.identifier }) {
            pendingKnownComputer = device.knownComputer
        }
        pendingRxChar = nil
        pendingTxChar = nil
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        isConnecting = false
        if let t = transport {
            try? t.close()
        }
        transport = nil
        connectedKnownComputer = nil
        pendingKnownComputer = nil
        pendingRxChar = nil
        pendingTxChar = nil
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
        // Capture before dispatching to MainActor
        let knownComputer = pendingKnownComputer
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectedPeripheral = peripheral
            peripheral.delegate = self

            if let known = knownComputer {
                // Use the data service UUID when it differs from the scan UUID
                // (e.g. Halcyon Symbios advertises one UUID but communicates on another).
                let dataUUID = CBUUID(string: known.dataServiceUUID ?? known.serviceUUID)
                peripheral.discoverServices([dataUUID])
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
            self?.isConnecting = false
            self?.connectedPeripheral = nil
            self?.pendingKnownComputer = nil
            self?.pendingRxChar = nil
            self?.pendingTxChar = nil
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
            self.isConnecting = false
            if self.connectedPeripheral?.identifier == disconnectedId {
                if let t = self.transport {
                    try? t.close()
                }
                self.transport = nil
                self.connectedKnownComputer = nil
                self.pendingRxChar = nil
                self.pendingTxChar = nil
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
        if let error {
            scanLog.error("Service discovery failed: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor [weak self] in self?.isConnecting = false }
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            // Capture before use — pendingKnownComputer is nonisolated(unsafe)
            let knownComputer = pendingKnownComputer
            if knownComputer != nil {
                // Targeted discovery found nothing — retry with full discovery.
                // Clear pendingKnownComputer so the second callback (if also empty)
                // takes the "no known computer" path and resets isConnecting instead
                // of looping.
                scanLog.info("Targeted service discovery found nothing — falling back to full discovery")
                pendingKnownComputer = nil
                peripheral.discoverServices(nil)
                return
            }
            scanLog.error("Service discovery returned no services")
            Task { @MainActor [weak self] in self?.isConnecting = false }
            return
        }

        // Capture before iterating — pendingKnownComputer is nonisolated(unsafe)
        let knownComputer = pendingKnownComputer

        for service in services {
            if let known = knownComputer {
                // Build the list of characteristic UUIDs to discover.
                // Always include the Rx characteristic; add the separate Tx
                // characteristic when the device uses split Rx/Tx (e.g. Halcyon).
                var charUUIDs = [CBUUID(string: known.characteristicUUID)]
                if let writeUUID = known.writeCharacteristicUUID {
                    charUUIDs.append(CBUUID(string: writeUUID))
                }
                peripheral.discoverCharacteristics(charUUIDs, for: service)
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
        if let error {
            let svcUUID = service.uuid.uuidString
            let errMsg = error.localizedDescription
            scanLog.error(
                "Char discovery failed \(svcUUID, privacy: .public): \(errMsg, privacy: .public)"
            )
            Task { @MainActor [weak self] in self?.isConnecting = false }
            return
        }
        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            scanLog.error("Characteristic discovery returned no characteristics for \(service.uuid, privacy: .public)")
            // Don't reset isConnecting — other services may still report characteristics.
            return
        }

        // Dump all discovered characteristics — critical for diagnosing BLE protocol issues.
        for char in characteristics {
            let props = String(char.properties.rawValue, radix: 16)
            scanLog.notice("  Characteristic \(char.uuid, privacy: .public) properties=0x\(props, privacy: .public)")
        }

        // Capture before use — pendingKnownComputer is nonisolated(unsafe)
        let knownComputer = pendingKnownComputer

        if let known = knownComputer {
            let rxUUID = CBUUID(string: known.characteristicUUID)
            let foundRx = characteristics.first { $0.uuid == rxUUID }

            if let writeUUID = known.writeCharacteristicUUID {
                // Split Rx/Tx device (e.g. Halcyon Symbios).
                // Accumulate discovered chars across service callbacks — Rx and Tx
                // may be in different GATT services.
                let txUUID = CBUUID(string: writeUUID)
                let foundTx = characteristics.first { $0.uuid == txUUID }

                if let rx = foundRx { pendingRxChar = rx }
                if let tx = foundTx { pendingTxChar = tx }

                // Only create the transport when both Rx and Tx are found.
                guard let rxChar = pendingRxChar, let txChar = pendingTxChar else {
                    let haveRx = pendingRxChar != nil
                    let haveTx = pendingTxChar != nil
                    let svcUUID = service.uuid.uuidString
                    scanLog.info("Service \(svcUUID, privacy: .public): Rx=\(haveRx) Tx=\(haveTx) — waiting")
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self, self.transport == nil else { return }
                    self.isConnecting = false
                    self.pendingRxChar = nil
                    self.pendingTxChar = nil
                    let bleTransport = BLEPeripheralTransport(
                        peripheral: peripheral,
                        characteristic: rxChar,
                        writeCharacteristic: txChar
                    )
                    self.transport = bleTransport
                    self.connectedKnownComputer = knownComputer
                }
            } else {
                // Single-characteristic device (e.g. Shearwater) — create transport immediately.
                guard let rxChar = foundRx else {
                    scanLog.error("No Rx characteristic found in service \(service.uuid, privacy: .public)")
                    // Don't reset isConnecting — other services may still have it.
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self, self.transport == nil else { return }
                    self.isConnecting = false
                    let bleTransport = BLEPeripheralTransport(
                        peripheral: peripheral,
                        characteristic: rxChar
                    )
                    self.transport = bleTransport
                    self.connectedKnownComputer = knownComputer
                }
            }
        } else {
            // Fallback: pick the first characteristic that supports notify/indicate + write
            let rxChar = characteristics.first { char in
                (char.properties.contains(.notify) || char.properties.contains(.indicate)) &&
                    (char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse))
            }

            guard let characteristic = rxChar else {
                scanLog.error("No suitable Rx characteristic found in service \(service.uuid, privacy: .public)")
                // Don't reset isConnecting — other services may still have it.
                return
            }

            Task { @MainActor [weak self] in
                guard let self, self.transport == nil else { return }
                self.isConnecting = false
                let bleTransport = BLEPeripheralTransport(
                    peripheral: peripheral,
                    characteristic: characteristic
                )
                self.transport = bleTransport
                self.connectedKnownComputer = knownComputer
            }
        }
    }
}
