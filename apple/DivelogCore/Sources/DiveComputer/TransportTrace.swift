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
    public var minimumTimeoutSeconds: TimeInterval { inner.minimumTimeoutSeconds }

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
    /// Prints a human-readable hex dump of all recorded I/O to os_log.
    ///
    /// All entries are logged at `.error` level so they persist in Console.app —
    /// this method is only called on import failure/cancellation, so the elevated
    /// level is appropriate and necessary for post-hoc diagnostics.
    public func dumpTrace() {
        let snapshot = entries
        traceLog.error("=== BLE Transport Trace (\(snapshot.count) entries) ===")
        for entry in snapshot {
            let ts = String(format: "%+.3f", entry.elapsed)
            switch entry.operation {
            case .read(let requested, let returned):
                let hex = returned.hexDump
                traceLog.error(
                    "[\(ts, privacy: .public)] READ req=\(requested) got=\(returned.count) | \(hex, privacy: .public)"
                )
            case .readError(let requested, let error):
                traceLog.error(
                    "[\(ts, privacy: .public)] READ req=\(requested) ERROR: \(error, privacy: .public)"
                )
            case .write(let data):
                let hex = data.hexDump
                traceLog.error(
                    "[\(ts, privacy: .public)] WRITE \(data.count)B | \(hex, privacy: .public)"
                )
            case .writeError(let data, let error):
                let hex = data.hexDump
                traceLog.error(
                    "[\(ts, privacy: .public)] WRITE \(data.count)B ERR \(error, privacy: .public)"
                )
                traceLog.error(
                    "[\(ts, privacy: .public)] WRITE data: \(hex, privacy: .public)"
                )
            case .setTimeout(let ms):
                traceLog.error("[\(ts, privacy: .public)] SET_TIMEOUT \(ms) ms")
            case .purge:
                traceLog.error("[\(ts, privacy: .public)] PURGE")
            case .close:
                traceLog.error("[\(ts, privacy: .public)] CLOSE")
            }
        }
        traceLog.error("=== End Trace ===")
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
