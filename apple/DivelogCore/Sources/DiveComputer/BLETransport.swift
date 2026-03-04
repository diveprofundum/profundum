import Foundation

/// Protocol abstracting BLE communication with a dive computer.
///
/// The real implementation uses CoreBluetooth + DispatchSemaphore;
/// tests use `MockBLETransport` with canned data.
public protocol BLETransport: AnyObject, Sendable {
    /// Read `count` bytes from the BLE characteristic, blocking up to `timeout`.
    func read(count: Int, timeout: TimeInterval) throws -> Data

    /// Write data to the BLE characteristic, blocking up to `timeout`.
    func write(_ data: Data, timeout: TimeInterval) throws

    /// Discard any buffered data.
    func purge() throws

    /// Close the connection and release resources.
    func close() throws

    /// The advertised device name, if available.
    var deviceName: String? { get }

    /// Minimum timeout in seconds that libdivecomputer should use for this transport.
    ///
    /// BLE has higher latency than serial/USB. Devices using indications (which require
    /// a GATT confirmation round-trip per packet) need a larger floor than those using
    /// notifications. Returns 0 to use the timeout as-is (no floor).
    var minimumTimeoutSeconds: TimeInterval { get }
}

extension BLETransport {
    /// Default: no timeout floor.
    public var minimumTimeoutSeconds: TimeInterval { 0 }
}
