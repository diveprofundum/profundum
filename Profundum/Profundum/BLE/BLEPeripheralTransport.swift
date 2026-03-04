import CoreBluetooth
import DivelogCore
import Foundation
import os

private let bleLog = Logger(subsystem: "com.divelog.profundum", category: "BLETransport")

/// Concrete `BLETransport` wrapping a `CBPeripheral` for real BLE communication.
///
/// All I/O is synchronous (blocking) via `DispatchSemaphore`, suitable for
/// libdivecomputer's blocking read/write expectations. All blocking happens on
/// dedicated dispatch queues, never the cooperative thread pool.
///
/// ## Thread Safety
///
/// Marked `@unchecked Sendable` because mutable state is protected manually:
///
/// - **`lock`** (`NSLock`) guards all mutable state: `readBuffer`, `lastError`,
///   `isClosed`, and `indicationReady`. Every read or write of these properties
///   acquires the lock.
/// - **Semaphores** (`readSemaphore`, `writeSemaphore`, `writeReadySemaphore`,
///   `indicationSemaphore`) are signalled *after* releasing the lock to unblock
///   waiting threads safely.
/// - **Callers** must not call `read`/`write` from the main actor or the Swift
///   cooperative thread pool — use a dedicated `DispatchQueue`.
final class BLEPeripheralTransport: NSObject, BLETransport, @unchecked Sendable {
    /// Set to `true` to enable detailed BLE-level logging via os_log.
    static var enableLogging = false
    private let peripheral: CBPeripheral
    /// The Rx characteristic used for reading data (notifications/indications).
    private let characteristic: CBCharacteristic
    /// The characteristic used for writing data. Falls back to `characteristic`
    /// when the device uses a single bidirectional characteristic.
    private let writeCharacteristic: CBCharacteristic

    /// The CBCharacteristicWriteType determined from the write characteristic's properties.
    /// `.writeWithoutResponse` is required by most BLE dive computers (Shearwater, etc.).
    private let writeType: CBCharacteristicWriteType

    /// Whether the Tx characteristic was validated to have write capability at init time.
    /// When `false`, `write()` fails immediately with a clear error instead of a confusing
    /// protocol-level failure.
    private let writeCapabilityValidated: Bool

    /// Guards all mutable state: `readBuffer`, `lastError`, `isClosed`, `indicationReady`.
    private let lock = NSLock()

    /// Whether the Rx characteristic's notification/indication subscription is active.
    /// Protected by `lock`.
    private var indicationReady = false

    /// Signalled when `didUpdateNotificationStateFor` fires (success or error).
    private let indicationSemaphore = DispatchSemaphore(value: 0)

    /// Internal buffer for data received via BLE notifications. Protected by `lock`.
    private var readBuffer = Data()

    /// Semaphore signalled when new data arrives from `didUpdateValueFor`.
    private let readSemaphore = DispatchSemaphore(value: 0)

    /// Semaphore signalled when a write completes via `didWriteValueFor`.
    private let writeSemaphore = DispatchSemaphore(value: 0)

    /// Semaphore signalled when the peripheral is ready for another `.withoutResponse` write.
    private let writeReadySemaphore = DispatchSemaphore(value: 0)

    /// Last error reported by the peripheral delegate. Protected by `lock`.
    private var lastError: Error?

    /// Whether the transport has been closed. Protected by `lock`.
    private var isClosed = false

    var deviceName: String? {
        peripheral.name
    }

    /// Indication-based transports (writeType == .withResponse) need a larger
    /// timeout floor due to GATT confirmation round-trips on every packet.
    var minimumTimeoutSeconds: TimeInterval {
        writeType == .withResponse ? 10.0 : 5.0
    }

    /// - Parameters:
    ///   - peripheral: The connected `CBPeripheral`.
    ///   - characteristic: The Rx characteristic for reading (notifications/indications).
    ///   - writeCharacteristic: An optional separate Tx characteristic for writing.
    ///     When `nil`, `characteristic` is used for both reads and writes.
    @MainActor
    init(peripheral: CBPeripheral, characteristic: CBCharacteristic,
         writeCharacteristic: CBCharacteristic? = nil) {
        self.peripheral = peripheral
        self.characteristic = characteristic
        self.writeCharacteristic = writeCharacteristic ?? characteristic
        // Determine write type from the write characteristic's properties.
        // Prefer writeWithoutResponse — most BLE dive computers require it.
        // Fall back to withResponse only if the characteristic doesn't support it.
        let txChar = writeCharacteristic ?? characteristic
        if txChar.properties.contains(.writeWithoutResponse) {
            self.writeType = .withoutResponse
        } else {
            self.writeType = .withResponse
        }
        self.writeCapabilityValidated =
            txChar.properties.contains(.write) || txChar.properties.contains(.writeWithoutResponse)
        if !self.writeCapabilityValidated {
            let props = String(txChar.properties.rawValue, radix: 16)
            bleLog.error("Tx characteristic \(txChar.uuid) has no write capability — properties=0x\(props)")
        }
        super.init()
        peripheral.delegate = self
        peripheral.setNotifyValue(true, for: characteristic)
        // When Rx and Tx are separate characteristics that both support indications
        // (e.g. Halcyon Symbios: both have .indicate), subscribe to the Tx characteristic
        // too. The device may respond on the same characteristic it received the write on.
        if let txChar = writeCharacteristic,
           txChar.uuid != characteristic.uuid,
           txChar.properties.contains(.indicate) || txChar.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: txChar)
        }

        // Always log characteristic setup — critical for diagnosing BLE protocol issues.
        let mtu = peripheral.maximumWriteValueLength(for: self.writeType)
        let writeTypeName = self.writeType == .withoutResponse
            ? "withoutResponse" : "withResponse"
        let rxUUID = characteristic.uuid.uuidString
        let rxProps = String(characteristic.properties.rawValue, radix: 16)
        let txUUID = (writeCharacteristic ?? characteristic).uuid.uuidString
        let txProps = String((writeCharacteristic ?? characteristic).properties.rawValue, radix: 16)
        bleLog.notice(
            "BLE init: Rx=\(rxUUID) props=0x\(rxProps) Tx=\(txUUID) props=0x\(txProps)"
        )
        bleLog.notice("BLE init: writeType=\(writeTypeName) MTU=\(mtu)")
    }

    func read(count: Int, timeout: TimeInterval) throws -> Data {
        lock.lock()
        if isClosed {
            lock.unlock()
            throw DiveComputerError.disconnected
        }
        lock.unlock()

        let deadline: DispatchTime = timeout == .infinity
            ? .distantFuture
            : .now() + timeout

        // Loop until we have data. This handles stale semaphore signals —
        // when multiple notifications arrive between reads, the buffer is
        // drained all at once but the semaphore retains extra signals.
        while true {
            // Check if we already have buffered data
            lock.lock()
            if !readBuffer.isEmpty {
                let deliverable = readBuffer.prefix(count)
                readBuffer = Data(readBuffer.dropFirst(deliverable.count))
                lock.unlock()
                return Data(deliverable)
            }
            lock.unlock()

            // No data available — wait for a notification
            let result = readSemaphore.wait(timeout: deadline)
            if result == .timedOut {
                throw DiveComputerError.timeout
            }

            lock.lock()
            let closed = isClosed
            let error = lastError
            if error != nil { lastError = nil }
            lock.unlock()

            if closed { throw DiveComputerError.disconnected }

            if let error {
                throw DiveComputerError.libdivecomputer(
                    status: -1,
                    message: error.localizedDescription
                )
            }

            // Loop back to check the buffer — if the semaphore signal was
            // stale (data already consumed by an earlier read), we'll wait again.
        }
    }

    /// Blocks until the Rx characteristic's notification/indication subscription
    /// is confirmed by CoreBluetooth. No-op after the first successful call.
    ///
    /// This is critical for devices that use BLE **indications** (property 0x20)
    /// instead of notifications — the GATT subscription handshake must complete
    /// before the device will emit data in response to writes.
    private func waitForIndicationSubscription(timeout: TimeInterval) throws {
        lock.lock()
        if indicationReady {
            lock.unlock()
            return
        }
        lock.unlock()

        bleLog.notice("waitForIndication: waiting (timeout=\(timeout)s)")
        let deadline: DispatchTime = timeout == .infinity
            ? .distantFuture
            : .now() + timeout
        let result = indicationSemaphore.wait(timeout: deadline)
        bleLog.notice("waitForIndication: done (timedOut=\(result == .timedOut))")

        lock.lock()
        let closed = isClosed
        let error = lastError
        if error != nil { lastError = nil }
        let ready = indicationReady
        lock.unlock()

        if closed { throw DiveComputerError.disconnected }
        if let error {
            throw DiveComputerError.libdivecomputer(
                status: -1,
                message: "Indication subscription failed: \(error.localizedDescription)"
            )
        }
        if result == .timedOut && !ready {
            throw DiveComputerError.timeout
        }
    }

    func write(_ data: Data, timeout: TimeInterval) throws {
        guard writeCapabilityValidated else {
            throw DiveComputerError.libdivecomputer(
                status: -1,
                message: "Write characteristic lacks write capability"
            )
        }

        lock.lock()
        if isClosed {
            lock.unlock()
            throw DiveComputerError.disconnected
        }
        lock.unlock()

        // Ensure indication/notification subscription is active before first write.
        // Blocks only on the first call; subsequent writes see indicationReady == true.
        try waitForIndicationSubscription(timeout: timeout)

        // Chunk writes to the peripheral's MTU to avoid silent truncation.
        let mtu = peripheral.maximumWriteValueLength(for: writeType)
        guard mtu > 0 else {
            throw DiveComputerError.libdivecomputer(
                status: -1,
                message: "BLE MTU is 0 — cannot write"
            )
        }
        let totalChunks = (data.count + mtu - 1) / mtu
        var offset = 0
        var chunkIndex = 0

        while offset < data.count {
            lock.lock()
            if isClosed {
                lock.unlock()
                throw DiveComputerError.disconnected
            }
            lock.unlock()

            let chunkSize = min(mtu, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + chunkSize))

            if Self.enableLogging {
                let n = chunkIndex + 1
                let txUUID = writeCharacteristic.uuid.uuidString
                let wtName = writeType == .withoutResponse ? "noRsp" : "rsp"
                bleLog.info(
                    "WRITE \(n)/\(totalChunks) \(chunkSize)B to \(txUUID) (\(wtName))"
                )
            }

            if writeType == .withoutResponse {
                // Wait until the peripheral can accept another packet.
                while !peripheral.canSendWriteWithoutResponse {
                    if Self.enableLogging {
                        bleLog.info("WRITE waiting: canSendWriteWithoutResponse=false")
                    }
                    let result = writeReadySemaphore.wait(timeout: .now() + timeout)
                    if result == .timedOut {
                        throw DiveComputerError.timeout
                    }
                    lock.lock()
                    let closed = isClosed
                    lock.unlock()
                    if closed { throw DiveComputerError.disconnected }
                }
                peripheral.writeValue(chunk, for: writeCharacteristic, type: .withoutResponse)
            } else {
                peripheral.writeValue(chunk, for: writeCharacteristic, type: .withResponse)

                let deadline: DispatchTime = timeout == .infinity
                    ? .distantFuture
                    : .now() + timeout
                let result = writeSemaphore.wait(timeout: deadline)
                if result == .timedOut {
                    throw DiveComputerError.timeout
                }

                lock.lock()
                let error = lastError
                if error != nil { lastError = nil }
                lock.unlock()

                if let error {
                    throw DiveComputerError.libdivecomputer(
                        status: -1,
                        message: error.localizedDescription
                    )
                }
            }

            offset += chunkSize
            chunkIndex += 1
        }
    }

    func purge() throws {
        lock.lock()
        readBuffer = Data()
        lock.unlock()
    }

    func close() throws {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        readBuffer = Data()
        lock.unlock()

        if characteristic.isNotifying {
            peripheral.setNotifyValue(false, for: characteristic)
        }
        if writeCharacteristic.uuid != characteristic.uuid, writeCharacteristic.isNotifying {
            peripheral.setNotifyValue(false, for: writeCharacteristic)
        }

        // Unblock any waiting reads/writes/indication subscription
        readSemaphore.signal()
        writeSemaphore.signal()
        writeReadySemaphore.signal()
        indicationSemaphore.signal()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEPeripheralTransport: CBPeripheralDelegate {
    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Only handle our Rx or Tx characteristics — ignore unrelated state changes.
        guard characteristic.uuid == self.characteristic.uuid
            || characteristic.uuid == self.writeCharacteristic.uuid else { return }

        let charUUID = characteristic.uuid.uuidString
        if let error {
            bleLog.error(
                "SUBSCRIBE error: \(charUUID) — \(error.localizedDescription)"
            )
            lock.lock()
            lastError = error
            lock.unlock()
            indicationSemaphore.signal()
            return
        }

        bleLog.notice(
            "SUBSCRIBE success: \(charUUID) isNotifying=\(characteristic.isNotifying)"
        )

        // Only gate on the Rx characteristic — the Tx subscription is informational.
        // If we set indicationReady on Tx first, the write gate opens before the
        // device is ready to emit responses on Rx.
        if characteristic.isNotifying, characteristic.uuid == self.characteristic.uuid {
            lock.lock()
            indicationReady = true
            lock.unlock()
            indicationSemaphore.signal()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            if Self.enableLogging {
                bleLog.error("NOTIFY error: \(error.localizedDescription)")
            }
            lock.lock()
            lastError = error
            lock.unlock()
            readSemaphore.signal()
            return
        }

        guard let value = characteristic.value, !value.isEmpty else { return }

        if Self.enableLogging {
            let fromUUID = characteristic.uuid.uuidString
            bleLog.info("NOTIFY received: \(value.count) bytes from \(fromUUID)")
        }

        lock.lock()
        readBuffer.append(value)
        lock.unlock()

        readSemaphore.signal()
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            lock.lock()
            lastError = error
            lock.unlock()
        }
        writeSemaphore.signal()
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if Self.enableLogging {
            bleLog.info("FLOW peripheralIsReady(toSendWriteWithoutResponse)")
        }
        writeReadySemaphore.signal()
    }
}
