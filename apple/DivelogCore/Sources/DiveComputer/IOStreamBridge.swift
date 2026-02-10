import Foundation

#if canImport(LibDivecomputerFFI)
import LibDivecomputerFFI

/// Bridges a `BLETransport` to libdivecomputer's `dc_custom_cbs_t` callback interface.
///
/// All libdivecomputer calls happen on a dedicated `DispatchQueue`, never the
/// Swift cooperative thread pool. The bridge simply forwards read/write calls
/// to the transport synchronously.
public final class IOStreamBridge {
    fileprivate let transport: BLETransport
    fileprivate var currentTimeout: TimeInterval = 10.0
    /// Optional tracing transport for recording set_timeout calls.
    fileprivate weak var tracingTransport: TracingBLETransport?
    private var iostream: OpaquePointer?

    public init(transport: BLETransport) {
        self.transport = transport
        // If the transport is a TracingBLETransport, keep a reference for timeout tracing
        self.tracingTransport = transport as? TracingBLETransport
    }

    deinit {
        if let iostream = iostream {
            dc_iostream_close(iostream)
        }
    }

    /// Opens the iostream by registering custom callbacks with libdivecomputer.
    /// - Parameter context: A `dc_context_t*` for error reporting.
    /// - Returns: The `dc_iostream_t*` to pass to libdivecomputer device open calls.
    public func open(context: OpaquePointer) throws -> OpaquePointer {
        var callbacks = dc_custom_cbs_t()
        callbacks.set_timeout = ioBridgeSetTimeout
        callbacks.read = ioBridgeRead
        callbacks.write = ioBridgeWrite
        callbacks.purge = ioBridgePurge
        callbacks.sleep = ioBridgeSleep
        callbacks.close = ioBridgeClose

        let userdata = Unmanaged.passRetained(self).toOpaque()
        var stream: OpaquePointer?

        let status = dc_custom_open(&stream, context, DC_TRANSPORT_BLE, &callbacks, userdata)
        guard status == DC_STATUS_SUCCESS else {
            Unmanaged<IOStreamBridge>.fromOpaque(userdata).release()
            throw DiveComputerError.libdivecomputer(
                status: status.rawValue,
                message: dcStatusMessage(status)
            )
        }

        self.iostream = stream
        return stream!
    }
}

// MARK: - C Callback Free Functions

private func ioBridgeSetTimeout(_ userdata: UnsafeMutableRawPointer?, _ timeout: Int32) -> dc_status_t {
    let bridge = Unmanaged<IOStreamBridge>.fromOpaque(userdata!).takeUnretainedValue()
    bridge.currentTimeout = timeout < 0 ? .infinity : TimeInterval(timeout) / 1000.0
    bridge.tracingTransport?.recordSetTimeout(ms: Int(timeout))
    return DC_STATUS_SUCCESS
}

private func ioBridgeRead(
    _ userdata: UnsafeMutableRawPointer?,
    _ data: UnsafeMutableRawPointer?,
    _ size: Int,
    _ actual: UnsafeMutablePointer<Int>?
) -> dc_status_t {
    let bridge = Unmanaged<IOStreamBridge>.fromOpaque(userdata!).takeUnretainedValue()
    do {
        let bytes = try bridge.transport.read(count: size, timeout: bridge.currentTimeout)
        bytes.withUnsafeBytes { ptr in
            data?.copyMemory(from: ptr.baseAddress!, byteCount: bytes.count)
        }
        actual?.pointee = bytes.count
        return DC_STATUS_SUCCESS
    } catch DiveComputerError.timeout {
        return DC_STATUS_TIMEOUT
    } catch {
        return DC_STATUS_IO
    }
}

private func ioBridgeWrite(
    _ userdata: UnsafeMutableRawPointer?,
    _ data: UnsafeRawPointer?,
    _ size: Int,
    _ actual: UnsafeMutablePointer<Int>?
) -> dc_status_t {
    let bridge = Unmanaged<IOStreamBridge>.fromOpaque(userdata!).takeUnretainedValue()
    let buffer = Data(bytes: data!, count: size)
    do {
        try bridge.transport.write(buffer, timeout: bridge.currentTimeout)
        actual?.pointee = size
        return DC_STATUS_SUCCESS
    } catch DiveComputerError.timeout {
        return DC_STATUS_TIMEOUT
    } catch {
        return DC_STATUS_IO
    }
}

private func ioBridgePurge(_ userdata: UnsafeMutableRawPointer?, _ direction: dc_direction_t) -> dc_status_t {
    let bridge = Unmanaged<IOStreamBridge>.fromOpaque(userdata!).takeUnretainedValue()
    do {
        try bridge.transport.purge()
        return DC_STATUS_SUCCESS
    } catch {
        return DC_STATUS_IO
    }
}

private func ioBridgeSleep(_ userdata: UnsafeMutableRawPointer?, _ milliseconds: UInt32) -> dc_status_t {
    Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1000.0)
    return DC_STATUS_SUCCESS
}

private func ioBridgeClose(_ userdata: UnsafeMutableRawPointer?) -> dc_status_t {
    let bridge = Unmanaged<IOStreamBridge>.fromOpaque(userdata!).takeRetainedValue()
    do {
        try bridge.transport.close()
        return DC_STATUS_SUCCESS
    } catch {
        return DC_STATUS_IO
    }
}

#endif
