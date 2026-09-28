import XCTest
@testable import DivelogCore

/// PRO-71: dives are persisted off the libdivecomputer thread so the BLE
/// link stays busy between dives. These tests cover ordering, draining,
/// tracker accounting, and error isolation.
final class DivePersistenceQueueTests: XCTestCase {
    private var database: DivelogDatabase!
    private var diveService: DiveService!
    private var importService: DiveComputerImportService!
    private var device: Device!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        importService = DiveComputerImportService(database: database)
        device = Device(model: "Symbios", serialNumber: "HUD1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)
    }

    private func parsedDive(start: Int64, fp: UInt8) -> ParsedDive {
        ParsedDive(
            startTimeUnix: start, endTimeUnix: start + 1800,
            maxDepthM: 30, avgDepthM: 18, bottomTimeSec: 1800,
            fingerprint: Data([fp, 0, 0, 1]),
            samples: [
                ParsedSample(tSec: 0, depthM: 0, tempC: 20),
                ParsedSample(tSec: 900, depthM: 30, tempC: 18),
                ParsedSample(tSec: 1800, depthM: 0, tempC: 20),
            ]
        )
    }

    func testEnqueueReturnsImmediatelyAndDrainWaitsForSaves() throws {
        let tracker = ImportProgressTracker()
        let queue = DivePersistenceQueue(importService: importService, tracker: tracker)

        for i in 0..<5 {
            queue.enqueue(parsedDive(start: 1_700_000_000 + Int64(i) * 7200, fp: UInt8(i + 1)), deviceId: device.id)
        }
        // Not asserting pendingCount > 0 here: the queue may already have
        // drained on a fast machine. drain() must block until everything landed.
        queue.drain()

        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(tracker.saved, 5)
        XCTAssertEqual(try diveService.listDives().count, 5)
    }

    func testDrainAsyncWaitsForSaves() async throws {
        let tracker = ImportProgressTracker()
        let queue = DivePersistenceQueue(importService: importService, tracker: tracker)

        queue.enqueue(parsedDive(start: 1_700_000_000, fp: 1), deviceId: device.id)
        queue.enqueue(parsedDive(start: 1_700_010_000, fp: 2), deviceId: device.id)
        await queue.drainAsync()

        XCTAssertEqual(tracker.saved, 2)
        XCTAssertEqual(try diveService.listDives().count, 2)
    }

    func testSavesArePerformedInEnqueueOrder() throws {
        let tracker = ImportProgressTracker()
        let order = OrderRecorder()
        let queue = DivePersistenceQueue(importService: importService, tracker: tracker) { parsed, _, _ in
            order.append(parsed.startTimeUnix)
        }

        // Newest-first, mirroring libdivecomputer enumeration.
        let starts: [Int64] = [1_700_030_000, 1_700_020_000, 1_700_010_000, 1_700_000_000]
        for (i, start) in starts.enumerated() {
            queue.enqueue(parsedDive(start: start, fp: UInt8(i + 1)), deviceId: device.id)
        }
        queue.drain()

        XCTAssertEqual(order.values, starts)
    }

    func testDuplicateIsRecordedAsSkippedNotFailure() throws {
        let tracker = ImportProgressTracker()
        let queue = DivePersistenceQueue(importService: importService, tracker: tracker)

        let dive = parsedDive(start: 1_700_000_000, fp: 9)
        queue.enqueue(dive, deviceId: device.id)
        queue.enqueue(dive, deviceId: device.id)
        queue.drain()

        XCTAssertEqual(tracker.saved, 1)
        XCTAssertEqual(tracker.skipped, 1)
        XCTAssertEqual(tracker.failed, 0)
        XCTAssertEqual(tracker.consecutiveSkips, 1)
    }

    func testSaveErrorIsRecordedAsFailureAndDoesNotStopQueue() throws {
        let tracker = ImportProgressTracker(consecutiveSkipThreshold: 3)
        var errors: [Error] = []
        let errLock = NSLock()
        let queue = DivePersistenceQueue(importService: importService, tracker: tracker) { _, _, error in
            if let error { errLock.withLock { errors.append(error) } }
        }

        // A dive referencing a device that does not exist violates the FK and throws.
        queue.enqueue(parsedDive(start: 1_700_000_000, fp: 1), deviceId: "no-such-device")
        queue.enqueue(parsedDive(start: 1_700_010_000, fp: 2), deviceId: device.id)
        queue.drain()

        XCTAssertEqual(tracker.failed, 1)
        XCTAssertEqual(tracker.saved, 1)
        XCTAssertEqual(tracker.consecutiveSkips, 0)
        XCTAssertFalse(tracker.shouldAutoStop)
        XCTAssertEqual(errors.count, 1)
    }

    func testTrackerIsSafeUnderConcurrentReadsWhileQueueWrites() throws {
        let tracker = ImportProgressTracker()
        let queue = DivePersistenceQueue(importService: importService, tracker: tracker)

        for i in 0..<20 {
            queue.enqueue(parsedDive(start: 1_700_000_000 + Int64(i) * 7200, fp: UInt8(i + 1)), deviceId: device.id)
        }
        // Hammer the counters from another thread while saves are in flight.
        let reader = Thread {
            for _ in 0..<2000 {
                _ = tracker.saved + tracker.merged + tracker.skipped + tracker.failed
                _ = tracker.shouldAutoStop
            }
        }
        reader.start()
        queue.drain()
        while !reader.isFinished { usleep(1000) }

        XCTAssertEqual(tracker.saved, 20)
    }

    // MARK: - CancellationFlag

    func testCancellationFlagSetResetIsSet() {
        let flag = CancellationFlag()
        XCTAssertFalse(flag.isSet)
        flag.set()
        XCTAssertTrue(flag.isSet)
        flag.set()
        XCTAssertTrue(flag.isSet, "Setting twice stays set")
        flag.reset()
        XCTAssertFalse(flag.isSet)
    }

    func testCancellationFlagSetFromPersistenceCallbackIsObservedByPoller() throws {
        // Mirrors ImportSession: auto-stop sets the flag from the persistence
        // queue's onSaved callback while libdivecomputer polls it elsewhere.
        let tracker = ImportProgressTracker(consecutiveSkipThreshold: 2)
        let flag = CancellationFlag()
        let queue = DivePersistenceQueue(importService: importService, tracker: tracker) { _, _, _ in
            if tracker.shouldAutoStop { flag.set() }
        }
        let dive = parsedDive(start: 1_700_000_000, fp: 1)
        // Save once (new), then re-save the same dive twice (skipped, skipped).
        for _ in 0..<3 { queue.enqueue(dive, deviceId: device.id) }
        queue.drain()
        XCTAssertTrue(flag.isSet)
        XCTAssertTrue(tracker.shouldAutoStop)
    }

    func testCancellationFlagConcurrentAccess() {
        let flag = CancellationFlag()
        let group = DispatchGroup()
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<5000 {
                    if i % 2 == 0 { flag.set() } else { _ = flag.isSet }
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertTrue(flag.isSet)
    }
}

/// Thread-safe append-only list for recording callback order.
private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int64] = []
    var values: [Int64] { lock.withLock { _values } }
    func append(_ v: Int64) { lock.withLock { _values.append(v) } }
}
