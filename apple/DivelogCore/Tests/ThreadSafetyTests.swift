import Foundation
import XCTest
@testable import DivelogCore

// MARK: - Concurrent Mock Transport

/// A `BLETransport` that blocks on `read()` until data is provided or `close()` is called.
/// Designed for testing concurrent access patterns (read + close, write + close, etc.).
private final class ConcurrentMockTransport: BLETransport, @unchecked Sendable {
    var deviceName: String? = "ConcurrentMock"

    private let lock = NSLock()
    private var _isClosed = false
    private var _readBuffer = Data()

    /// Signalled when data is appended to the read buffer or the transport is closed.
    private let dataAvailable = DispatchSemaphore(value: 0)

    /// Whether close() has been called.
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isClosed
    }

    /// Provide data that a blocked `read()` will consume.
    func provideReadData(_ data: Data) {
        lock.lock()
        _readBuffer.append(data)
        lock.unlock()
        dataAvailable.signal()
    }

    func read(count: Int, timeout: TimeInterval) throws -> Data {
        // Check for immediate data or closed state
        lock.lock()
        if _isClosed {
            lock.unlock()
            throw DiveComputerError.disconnected
        }
        if !_readBuffer.isEmpty {
            let result = Data(_readBuffer.prefix(count))
            _readBuffer = Data(_readBuffer.dropFirst(result.count))
            lock.unlock()
            return result
        }
        lock.unlock()

        // Block until data arrives or transport is closed
        let deadline: DispatchTime = timeout == .infinity
            ? .distantFuture
            : .now() + timeout
        let waitResult = dataAvailable.wait(timeout: deadline)
        if waitResult == .timedOut {
            throw DiveComputerError.timeout
        }

        lock.lock()
        if _isClosed {
            lock.unlock()
            throw DiveComputerError.disconnected
        }
        let result = Data(_readBuffer.prefix(count))
        _readBuffer = Data(_readBuffer.dropFirst(result.count))
        lock.unlock()
        return result
    }

    func write(_ data: Data, timeout: TimeInterval) throws {
        lock.lock()
        if _isClosed {
            lock.unlock()
            throw DiveComputerError.disconnected
        }
        lock.unlock()
        // Simulate a brief write delay to increase window for races
        Thread.sleep(forTimeInterval: 0.001)
        lock.lock()
        if _isClosed {
            lock.unlock()
            throw DiveComputerError.disconnected
        }
        lock.unlock()
    }

    func purge() throws {
        lock.lock()
        _readBuffer = Data()
        lock.unlock()
    }

    func close() throws {
        lock.lock()
        _isClosed = true
        _readBuffer = Data()
        lock.unlock()
        // Unblock any waiting reads
        dataAvailable.signal()
    }
}

// MARK: - Thread Safety Tests

final class ThreadSafetyTests: XCTestCase {

    // MARK: - TracingBLETransport

    /// Verify that concurrent reads/writes to TracingBLETransport don't crash.
    /// The inner transport provides data while we read entries from another thread.
    func testTracingTransportConcurrentAccess() throws {
        let inner = ConcurrentMockTransport()
        let tracing = TracingBLETransport(wrapping: inner)

        let iterations = 100
        let readExpectation = expectation(description: "concurrent reads complete")
        readExpectation.expectedFulfillmentCount = iterations

        let entryExpectation = expectation(description: "entry reads complete")
        entryExpectation.expectedFulfillmentCount = iterations

        let ioQueue = DispatchQueue(label: "test.io", attributes: .concurrent)
        let entrySnapshotQueue = DispatchQueue(label: "test.entrySnapshot", attributes: .concurrent)

        for i in 0..<iterations {
            // Provide data so reads succeed
            inner.provideReadData(Data([UInt8(i % 256)]))

            ioQueue.async {
                _ = try? tracing.read(count: 1, timeout: 1.0)
                readExpectation.fulfill()
            }

            entrySnapshotQueue.async {
                // Concurrent snapshot of entries — should not crash
                _ = tracing.entries
                entryExpectation.fulfill()
            }
        }

        wait(for: [readExpectation, entryExpectation], timeout: 10.0)

        // Verify entries were recorded (at least some, ordering not guaranteed)
        XCTAssertGreaterThan(tracing.entries.count, 0)
    }

    // MARK: - Concurrent Read + Close

    /// Start a blocking read on one queue and close the transport on another.
    /// The read should unblock with a `disconnected` error (not crash).
    func testConcurrentReadAndClose() throws {
        let transport = ConcurrentMockTransport()
        let tracing = TracingBLETransport(wrapping: transport)

        let readFinished = expectation(description: "read finishes after close")
        var readError: Error?

        // Start a blocking read on a background queue
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try tracing.read(count: 10, timeout: 5.0)
            } catch {
                readError = error
            }
            readFinished.fulfill()
        }

        // Give the read a moment to block, then close
        Thread.sleep(forTimeInterval: 0.05)
        try tracing.close()

        wait(for: [readFinished], timeout: 5.0)

        // The read should have failed with disconnected
        XCTAssertNotNil(readError)
        if let dcError = readError as? DiveComputerError {
            XCTAssertEqual(dcError, .disconnected)
        }
    }

    // MARK: - Concurrent Write + Close

    /// Start writes on one queue and close on another. No crash should occur.
    func testConcurrentWriteAndClose() throws {
        let transport = ConcurrentMockTransport()
        let tracing = TracingBLETransport(wrapping: transport)

        let writeCount = 50
        let writesFinished = expectation(description: "writes finish")
        writesFinished.expectedFulfillmentCount = writeCount

        let writeQueue = DispatchQueue(label: "test.writes", attributes: .concurrent)

        for _ in 0..<writeCount {
            writeQueue.async {
                // Some writes will succeed, some will fail with disconnected — both are fine
                try? tracing.write(Data([0x01, 0x02]), timeout: 1.0)
                writesFinished.fulfill()
            }
        }

        // Close mid-flight
        Thread.sleep(forTimeInterval: 0.01)
        try tracing.close()

        wait(for: [writesFinished], timeout: 5.0)

        // Should not crash — that's the real assertion
        XCTAssertTrue(transport.isClosed)
    }

    // MARK: - Multiple Close Calls

    /// Calling close() multiple times should be idempotent and not crash.
    func testMultipleCloseIsIdempotent() throws {
        let transport = ConcurrentMockTransport()
        let tracing = TracingBLETransport(wrapping: transport)

        let closeCount = 20
        let closesFinished = expectation(description: "closes finish")
        closesFinished.expectedFulfillmentCount = closeCount

        let closeQueue = DispatchQueue(label: "test.closes", attributes: .concurrent)

        for _ in 0..<closeCount {
            closeQueue.async {
                try? tracing.close()
                closesFinished.fulfill()
            }
        }

        wait(for: [closesFinished], timeout: 5.0)

        // All closes completed without crash
        XCTAssertTrue(transport.isClosed)
    }

    // MARK: - Read After Close

    /// Reading after close should immediately return disconnected.
    func testReadAfterCloseReturnsDisconnected() throws {
        let transport = ConcurrentMockTransport()
        try transport.close()

        XCTAssertThrowsError(try transport.read(count: 1, timeout: 1.0)) { error in
            XCTAssertEqual(error as? DiveComputerError, .disconnected)
        }
    }

    // MARK: - Write After Close

    /// Writing after close should immediately return disconnected.
    func testWriteAfterCloseReturnsDisconnected() throws {
        let transport = ConcurrentMockTransport()
        try transport.close()

        XCTAssertThrowsError(try transport.write(Data([0x01]), timeout: 1.0)) { error in
            XCTAssertEqual(error as? DiveComputerError, .disconnected)
        }
    }
}
