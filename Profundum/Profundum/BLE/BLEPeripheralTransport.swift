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
        super.init()
        peripheral.delegate = self
        peripheral.setNotifyValue(true, for: characteristic)

        if Self.enableLogging {
            let mtu = peripheral.maximumWriteValueLength(for: self.writeType)
            let writeTypeName = self.writeType == .withoutResponse
                ? "withoutResponse" : "withResponse"
            let props = String(describing: characteristic.properties.rawValue)
            bleLog.info(
                "BLETransport init: writeType=\(writeTypeName), MTU=\(mtu), properties=\(props)"
            )
        }
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

        let deadline: DispatchTime = timeout == .infinity
            ? .distantFuture
            : .now() + timeout
        let result = indicationSemaphore.wait(timeout: deadline)

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
                let tot = data.count
                bleLog.info(
                    "WRITE chunk \(n)/\(totalChunks): \(chunkSize)B (total \(tot), offset \(offset))"
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
        // Only handle our Rx characteristic — ignore state changes on other characteristics.
        guard characteristic.uuid == self.characteristic.uuid else { return }

        if let error {
            if Self.enableLogging {
                bleLog.error("SUBSCRIBE error: \(error.localizedDescription)")
            }
            lock.lock()
            lastError = error
            lock.unlock()
            indicationSemaphore.signal()
            return
        }

        if Self.enableLogging {
            bleLog.info("SUBSCRIBE success: isNotifying=\(characteristic.isNotifying)")
        }

        if characteristic.isNotifying {
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
            bleLog.info("NOTIFY received: \(value.count) bytes")
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
