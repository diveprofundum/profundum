import Foundation
import os

private let traceLog = Logger(subsystem: "com.divelog.core", category: "TransportTrace")

// MARK: - Trace Types

public struct TransportTraceEntry: Sendable {
    /// Seconds since the trace started.
    public let elapsed: TimeInterval
    public let operation: TraceOperation
}

public enum TraceOperation: Sendable {
    case read(requested: Int, returned: Data)
    case readError(requested: Int, error: String)
    case write(data: Data)
    case writeError(data: Data, error: String)
    case setTimeout(ms: Int)
    case purge
    case close
}

// MARK: - TracingBLETransport

/// Wraps any `BLETransport` and records every I/O operation with timing.
///
/// Insert between IOStreamBridge and the real transport:
/// ```
/// IOStreamBridge → TracingBLETransport → BLEPeripheralTransport
/// ```
///
/// ## Thread Safety
///
/// Marked `@unchecked Sendable` because mutable state (`_entries`) is protected
/// by an `NSLock`. All I/O methods delegate to `inner` (which has its own
/// synchronization) and then append to `_entries` under the lock. The `entries`
/// accessor also acquires the lock, so snapshots are safe to read from any thread.
public final class TracingBLETransport: BLETransport, @unchecked Sendable {
    private let inner: BLETransport
    private let startTime: Date
    /// Protects `_entries`. Acquired for every append and every snapshot read.
    private let lock = NSLock()
    private var _entries: [TransportTraceEntry] = []

    public var deviceName: String? { inner.deviceName }

    /// All recorded trace entries.
    public var entries: [TransportTraceEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    public init(wrapping transport: BLETransport) {
        self.inner = transport
        self.startTime = Date()
    }

    public func read(count: Int, timeout: TimeInterval) throws -> Data {
        do {
            let data = try inner.read(count: count, timeout: timeout)
            record(.read(requested: count, returned: data))
            return data
        } catch {
            record(.readError(requested: count, error: String(describing: error)))
            throw error
        }
    }

    public func write(_ data: Data, timeout: TimeInterval) throws {
        do {
            try inner.write(data, timeout: timeout)
            record(.write(data: data))
        } catch {
            record(.writeError(data: data, error: String(describing: error)))
            throw error
        }
    }

    public func purge() throws {
        try inner.purge()
        record(.purge)
    }

    public func close() throws {
        try inner.close()
        record(.close)
    }

    /// Record a timeout change from IOStreamBridge.
    public func recordSetTimeout(ms: Int) {
        record(.setTimeout(ms: ms))
    }

    // MARK: - Trace Output

    /// Prints a human-readable hex dump of all recorded I/O to os_log.
    public func dumpTrace() {
        let snapshot = entries
        traceLog.info("=== BLE Transport Trace (\(snapshot.count) entries) ===")
        for entry in snapshot {
            let ts = String(format: "%+.3f", entry.elapsed)
            switch entry.operation {
            case .read(let requested, let returned):
                traceLog.info("[\(ts)] READ  req=\(requested) got=\(returned.count) | \(returned.hexDump)")
            case .readError(let requested, let error):
                traceLog.error("[\(ts)] READ  req=\(requested) ERROR: \(error)")
            case .write(let data):
                traceLog.info("[\(ts)] WRITE \(data.count) bytes | \(data.hexDump)")
            case .writeError(let data, let error):
                traceLog.error("[\(ts)] WRITE \(data.count) bytes ERROR: \(error) | \(data.hexDump)")
            case .setTimeout(let ms):
                traceLog.info("[\(ts)] SET_TIMEOUT \(ms) ms")
            case .purge:
                traceLog.info("[\(ts)] PURGE")
            case .close:
                traceLog.info("[\(ts)] CLOSE")
            }
        }
        traceLog.info("=== End Trace ===")
    }

    // MARK: - Private

    private func record(_ op: TraceOperation) {
        let elapsed = Date().timeIntervalSince(startTime)
        let entry = TransportTraceEntry(elapsed: elapsed, operation: op)
        lock.lock()
        _entries.append(entry)
        lock.unlock()
    }
}

// MARK: - Hex Dump Helper

extension Data {
    /// Hex string representation of the data, space-separated bytes.
    var hexDump: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
