import XCTest
@testable import DivelogCore

// MARK: - Mock BLE Transport

final class MockBLETransport: BLETransport, @unchecked Sendable {
    var readData: [Data] = []
    var writtenData: [Data] = []
    var purgeCount = 0
    var isClosed = false
    var deviceName: String? = "MockDevice"

    /// If set, `write()` throws if `data.count > maxWriteSize` (simulates MTU enforcement).
    var maxWriteSize: Int? = nil

    /// If set, `read()` returns at most this many bytes per call (simulates BLE chunking).
    var readChunkSize: Int? = nil

    /// Records every operation as a human-readable string for sequence assertions.
    var operationLog: [String] = []

    /// Internal buffer for chunked read delivery.
    private var readBuffer = Data()
    private var readIndex = 0

    func read(count: Int, timeout: TimeInterval) throws -> Data {
        // If we have leftover data in the chunked buffer, serve from there first
        if !readBuffer.isEmpty {
            let chunkSize = min(readChunkSize ?? readBuffer.count, readBuffer.count)
            let deliverable = min(chunkSize, count)
            let result = readBuffer.prefix(deliverable)
            readBuffer = Data(readBuffer.dropFirst(deliverable))
            operationLog.append("read(\(count)) → \(result.count) bytes")
            return Data(result)
        }

        guard readIndex < readData.count else {
            operationLog.append("read(\(count)) → timeout")
            throw DiveComputerError.timeout
        }

        let data = readData[readIndex]
        readIndex += 1

        if let chunkSize = readChunkSize, data.count > chunkSize {
            // Deliver first chunk, buffer the rest
            let deliverable = min(chunkSize, count)
            let result = data.prefix(deliverable)
            readBuffer = Data(data.dropFirst(deliverable))
            operationLog.append("read(\(count)) → \(result.count) bytes")
            return Data(result)
        }

        let result = data.prefix(count)
        operationLog.append("read(\(count)) → \(result.count) bytes")
        return Data(result)
    }

    func write(_ data: Data, timeout: TimeInterval) throws {
        guard !isClosed else {
            operationLog.append("write(\(data.count) bytes) → error:disconnected")
            throw DiveComputerError.disconnected
        }
        if let maxSize = maxWriteSize, data.count > maxSize {
            operationLog.append("write(\(data.count) bytes) → error:oversized (max \(maxSize))")
            throw DiveComputerError.libdivecomputer(
                status: -1,
                message: "Write size \(data.count) exceeds MTU limit \(maxSize)"
            )
        }
        writtenData.append(data)
        operationLog.append("write(\(data.count) bytes)")
    }

    func purge() throws {
        purgeCount += 1
        readBuffer = Data()
        operationLog.append("purge")
    }

    func close() throws {
        isClosed = true
        operationLog.append("close")
    }
}

// MARK: - Dive Computer Tests

final class DiveComputerTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!
    var importService: DiveComputerImportService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        importService = DiveComputerImportService(database: database)
    }

    // MARK: - MockBLETransport Tests

    func testMockTransportRead() throws {
        let transport = MockBLETransport()
        transport.readData = [Data([0x01, 0x02, 0x03, 0x04])]

        let result = try transport.read(count: 4, timeout: 5.0)
        XCTAssertEqual(result, Data([0x01, 0x02, 0x03, 0x04]))
    }

    func testMockTransportReadTimeout() throws {
        let transport = MockBLETransport()
        // No data queued

        XCTAssertThrowsError(try transport.read(count: 4, timeout: 1.0)) { error in
            XCTAssertEqual(error as? DiveComputerError, .timeout)
        }
    }

    func testMockTransportWrite() throws {
        let transport = MockBLETransport()
        let payload = Data([0xAA, 0xBB])

        try transport.write(payload, timeout: 5.0)
        XCTAssertEqual(transport.writtenData.count, 1)
        XCTAssertEqual(transport.writtenData.first, payload)
    }

    func testMockTransportWriteAfterClose() throws {
        let transport = MockBLETransport()
        try transport.close()

        XCTAssertThrowsError(try transport.write(Data([0x01]), timeout: 5.0)) { error in
            XCTAssertEqual(error as? DiveComputerError, .disconnected)
        }
    }

    func testMockTransportPurge() throws {
        let transport = MockBLETransport()
        try transport.purge()
        XCTAssertEqual(transport.purgeCount, 1)
    }

    // MARK: - Fingerprint Duplicate Detection

    func testFindExistingDiveByFingerprint() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let fingerprint = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: fingerprint
        )
        try diveService.saveDive(dive)

        // Same fingerprint should return the existing dive ID
        let found = try importService.findExistingDiveByFingerprint(fingerprint: fingerprint)
        XCTAssertEqual(found, dive.id)

        // Different fingerprint should return nil
        let notFound = try importService.findExistingDiveByFingerprint(fingerprint: Data([0xCA, 0xFE]))
        XCTAssertNil(notFound)
    }

    // MARK: - Last Fingerprint Ordering

    func testLastFingerprintReturnsNewest() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let fp1 = Data([0x01])
        let fp2 = Data([0x02])
        let fp3 = Data([0x03])

        // Save dives with different timestamps and fingerprints
        for (time, fp) in [(Int64(1700000000), fp1), (Int64(1700100000), fp2), (Int64(1700050000), fp3)] {
            let dive = Dive(
                deviceId: device.id,
                startTimeUnix: time,
                endTimeUnix: time + 3600,
                maxDepthM: 20.0,
                avgDepthM: 12.0,
                bottomTimeSec: 2000,
                fingerprint: fp
            )
            try diveService.saveDive(dive)
        }

        // Should return fp2 (newest by start_time_unix = 1700100000)
        let last = try importService.lastFingerprint(deviceId: device.id)
        XCTAssertEqual(last, fp2)
    }

    func testLastFingerprintNilForUnknownDevice() throws {
        let last = try importService.lastFingerprint(deviceId: "nonexistent")
        XCTAssertNil(last)
    }

    func testLastFingerprintSkipsDivesWithoutFingerprint() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        // Save a dive without fingerprint (manual entry)
        let manual = Dive(
            deviceId: device.id,
            startTimeUnix: 1700200000,
            endTimeUnix: 1700203600,
            maxDepthM: 15.0,
            avgDepthM: 10.0,
            bottomTimeSec: 1500
        )
        try diveService.saveDive(manual)

        // Save a dive with fingerprint (older)
        let fp = Data([0xAA, 0xBB])
        let imported = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000,
            fingerprint: fp
        )
        try diveService.saveDive(imported)

        // Should return fp, not nil (skips the manual dive without fingerprint)
        let last = try importService.lastFingerprint(deviceId: device.id)
        XCTAssertEqual(last, fp)
    }

    // MARK: - Data Mapper Tests

    func testDataMapperRoundTrip() {
        let parsed = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 35.0,
            avgDepthM: 22.0,
            bottomTimeSec: 2500,
            isCcr: true,
            decoRequired: true,
            cnsPercent: 20.0,
            otu: 30.0,
            computerDiveNumber: 100,
            fingerprint: Data([0xFF, 0xEE]),
            samples: [
                ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0),
                ParsedSample(tSec: 60, depthM: 15.0, tempC: 20.0, setpointPpo2: 1.3),
                ParsedSample(tSec: 120, depthM: 35.0, tempC: 18.0, ceilingM: 3.0, gf99: 85.0),
            ]
        )

        let (dive, samples, _) = DiveDataMapper.toDive(parsed, deviceId: "dev-123")

        XCTAssertEqual(dive.deviceId, "dev-123")
        XCTAssertEqual(dive.startTimeUnix, 1700000000)
        XCTAssertEqual(dive.maxDepthM, 35.0)
        XCTAssertEqual(dive.isCcr, true)
        XCTAssertEqual(dive.computerDiveNumber, 100)
        XCTAssertEqual(dive.fingerprint, Data([0xFF, 0xEE]))

        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0].tSec, 0)
        XCTAssertEqual(samples[1].setpointPpo2, 1.3)
        XCTAssertEqual(samples[2].ceilingM, 3.0)
        XCTAssertEqual(samples[2].gf99, 85.0)

        // All samples should share the dive ID
        for sample in samples {
            XCTAssertEqual(sample.diveId, dive.id)
        }
    }

    // MARK: - Import Service Idempotency Tests

    func testSaveImportedDiveIdempotent() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let parsed = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 25.0,
            avgDepthM: 15.0,
            bottomTimeSec: 2400,
            fingerprint: Data([0x01, 0x02, 0x03]),
            samples: [
                ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0),
                ParsedSample(tSec: 60, depthM: 10.0, tempC: 20.0),
            ]
        )

        // First save should succeed
        let firstSave = try importService.saveImportedDive(parsed, deviceId: device.id)
        XCTAssertTrue(firstSave)

        // Second save with same fingerprint should be skipped
        let secondSave = try importService.saveImportedDive(parsed, deviceId: device.id)
        XCTAssertFalse(secondSave)

        // Only one dive should exist
        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)
    }

    func testSaveImportedDiveWithoutFingerprint() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let parsed = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000
            // No fingerprint
        )

        // Should save successfully (no dedup without fingerprint)
        let saved = try importService.saveImportedDive(parsed, deviceId: device.id)
        XCTAssertTrue(saved)

        // Can save again (no fingerprint = no dedup)
        let savedAgain = try importService.saveImportedDive(parsed, deviceId: device.id)
        XCTAssertTrue(savedAgain)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 2)
    }

    func testSaveImportedDivesSavesAndSkipsDuplicates() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let parsed1 = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000,
            fingerprint: Data([0x01])
        )
        let parsed2 = ParsedDive(
            startTimeUnix: 1700100000,
            endTimeUnix: 1700103600,
            maxDepthM: 25.0,
            avgDepthM: 15.0,
            bottomTimeSec: 2500,
            fingerprint: Data([0x02])
        )

        // Pre-save one dive
        try importService.saveImportedDive(parsed1, deviceId: device.id)

        // Import both -- first should be skipped as duplicate
        let savedCount = try importService.saveImportedDives([parsed1, parsed2], deviceId: device.id)
        XCTAssertEqual(savedCount, 1)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 2)
    }

    func testSaveImportedDiveCreatessamples() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let parsed = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0xAB, 0xCD]),
            samples: [
                ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0),
                ParsedSample(tSec: 60, depthM: 15.0, tempC: 20.0),
                ParsedSample(tSec: 120, depthM: 30.0, tempC: 18.0),
            ]
        )

        try importService.saveImportedDive(parsed, deviceId: device.id)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)

        let samples = try diveService.getSamples(diveId: dives.first!.id)
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0].tSec, 0)
        XCTAssertEqual(samples[2].depthM, 30.0)
    }

    // MARK: - Known Devices Tests

    func testKnownDeviceServiceUUIDs() {
        XCTAssertEqual(
            KnownDiveComputer.shearwater.serviceUUID,
            "FE25C237-0ECE-443C-B0AA-E02033E7029D"
        )
        XCTAssertEqual(KnownDiveComputer.allServiceUUIDs.count, KnownDiveComputer.allCases.count)
    }

    func testKnownDeviceLookupByServiceUUID() {
        let found = KnownDiveComputer.from(serviceUUID: "FE25C237-0ECE-443C-B0AA-E02033E7029D")
        XCTAssertEqual(found, .shearwater)

        // Case-insensitive
        let foundLower = KnownDiveComputer.from(serviceUUID: "fe25c237-0ece-443c-b0aa-e02033e7029d")
        XCTAssertEqual(foundLower, .shearwater)

        // Unknown UUID
        let notFound = KnownDiveComputer.from(serviceUUID: "00000000-0000-0000-0000-000000000000")
        XCTAssertNil(notFound)
    }

    // MARK: - DiveComputerError Tests

    func testErrorEquality() {
        XCTAssertEqual(DiveComputerError.timeout, DiveComputerError.timeout)
        XCTAssertNotEqual(DiveComputerError.timeout, DiveComputerError.disconnected)
        XCTAssertEqual(
            DiveComputerError.libdivecomputer(status: 1, message: "err"),
            DiveComputerError.libdivecomputer(status: 1, message: "err")
        )
    }

    func testErrorDescriptions() {
        XCTAssertNotNil(DiveComputerError.timeout.errorDescription)
        XCTAssertNotNil(DiveComputerError.disconnected.errorDescription)
        XCTAssertNotNil(DiveComputerError.unsupportedDevice.errorDescription)
        XCTAssertNotNil(DiveComputerError.duplicateDive.errorDescription)
        XCTAssertNotNil(DiveComputerError.cancelled.errorDescription)
        XCTAssertTrue(
            DiveComputerError.libdivecomputer(status: 5, message: "IO").errorDescription!.contains("5")
        )
    }

    // MARK: - MTU Enforcement Tests

    func testMockTransportRejectsOversizedWrite() throws {
        let transport = MockBLETransport()
        transport.maxWriteSize = 20

        let oversized = Data(repeating: 0xAA, count: 30)
        XCTAssertThrowsError(try transport.write(oversized, timeout: 5.0)) { error in
            guard let dcError = error as? DiveComputerError,
                  case .libdivecomputer(_, let msg) = dcError else {
                XCTFail("Expected libdivecomputer error, got \(error)"); return
            }
            XCTAssertTrue(msg.contains("MTU"))
        }
        XCTAssertTrue(transport.writtenData.isEmpty)
    }

    func testMockTransportAcceptsWriteAtLimit() throws {
        let transport = MockBLETransport()
        transport.maxWriteSize = 20

        let exact = Data(repeating: 0xBB, count: 20)
        try transport.write(exact, timeout: 5.0)
        XCTAssertEqual(transport.writtenData.count, 1)
        XCTAssertEqual(transport.writtenData.first, exact)
    }

    // MARK: - Chunked Read Tests

    func testMockTransportChunkedRead() throws {
        let transport = MockBLETransport()
        transport.readChunkSize = 20
        transport.readData = [Data(repeating: 0xCC, count: 100)]

        var collected = Data()
        for _ in 0..<5 {
            let chunk = try transport.read(count: 100, timeout: 5.0)
            XCTAssertEqual(chunk.count, 20)
            collected.append(chunk)
        }
        XCTAssertEqual(collected.count, 100)
        XCTAssertEqual(collected, Data(repeating: 0xCC, count: 100))
    }

    func testMockTransportChunkedReadPartialLast() throws {
        let transport = MockBLETransport()
        transport.readChunkSize = 20
        transport.readData = [Data(repeating: 0xDD, count: 50)]

        let chunk1 = try transport.read(count: 50, timeout: 5.0)
        XCTAssertEqual(chunk1.count, 20)

        let chunk2 = try transport.read(count: 50, timeout: 5.0)
        XCTAssertEqual(chunk2.count, 20)

        let chunk3 = try transport.read(count: 50, timeout: 5.0)
        XCTAssertEqual(chunk3.count, 10)
    }

    // MARK: - TracingBLETransport Tests

    func testTracingTransportRecordsReadWrite() throws {
        let inner = MockBLETransport()
        inner.readData = [Data([0x01, 0x02, 0x03])]
        let tracing = TracingBLETransport(wrapping: inner)

        try tracing.write(Data([0xAA, 0xBB]), timeout: 5.0)
        let readResult = try tracing.read(count: 3, timeout: 5.0)
        XCTAssertEqual(readResult, Data([0x01, 0x02, 0x03]))

        let entries = tracing.entries
        XCTAssertEqual(entries.count, 2)

        // First entry: write
        if case .write(let data) = entries[0].operation {
            XCTAssertEqual(data, Data([0xAA, 0xBB]))
        } else {
            XCTFail("Expected write operation")
        }

        // Second entry: read
        if case .read(let requested, let returned) = entries[1].operation {
            XCTAssertEqual(requested, 3)
            XCTAssertEqual(returned, Data([0x01, 0x02, 0x03]))
        } else {
            XCTFail("Expected read operation")
        }

        // Timestamps should be non-negative and increasing
        XCTAssertGreaterThanOrEqual(entries[0].elapsed, 0)
        XCTAssertGreaterThanOrEqual(entries[1].elapsed, entries[0].elapsed)
    }

    func testTracingTransportForwardsCorrectly() throws {
        let inner = MockBLETransport()
        inner.readData = [Data([0x10, 0x20])]
        let tracing = TracingBLETransport(wrapping: inner)

        // Write should forward to inner
        let writeData = Data([0x30, 0x40, 0x50])
        try tracing.write(writeData, timeout: 5.0)
        XCTAssertEqual(inner.writtenData.count, 1)
        XCTAssertEqual(inner.writtenData.first, writeData)

        // Read should forward from inner
        let readResult = try tracing.read(count: 2, timeout: 5.0)
        XCTAssertEqual(readResult, Data([0x10, 0x20]))

        // Purge should forward
        try tracing.purge()
        XCTAssertEqual(inner.purgeCount, 1)

        // Close should forward
        try tracing.close()
        XCTAssertTrue(inner.isClosed)

        // Device name should forward
        XCTAssertEqual(tracing.deviceName, "MockDevice")
    }

    func testTracingTransportRecordsErrors() throws {
        let inner = MockBLETransport()
        // No read data queued → will timeout
        let tracing = TracingBLETransport(wrapping: inner)

        XCTAssertThrowsError(try tracing.read(count: 4, timeout: 1.0))

        let entries = tracing.entries
        XCTAssertEqual(entries.count, 1)
        if case .readError(let requested, let error) = entries[0].operation {
            XCTAssertEqual(requested, 4)
            XCTAssertTrue(error.contains("timeout"))
        } else {
            XCTFail("Expected readError operation")
        }
    }

    func testTracingTransportRecordsSetTimeout() {
        let inner = MockBLETransport()
        let tracing = TracingBLETransport(wrapping: inner)

        tracing.recordSetTimeout(ms: 5000)
        tracing.recordSetTimeout(ms: -1)

        let entries = tracing.entries
        XCTAssertEqual(entries.count, 2)
        if case .setTimeout(let ms) = entries[0].operation {
            XCTAssertEqual(ms, 5000)
        } else {
            XCTFail("Expected setTimeout operation")
        }
        if case .setTimeout(let ms) = entries[1].operation {
            XCTAssertEqual(ms, -1)
        } else {
            XCTFail("Expected setTimeout operation")
        }
    }

    func testTracingTransportRecordsPurgeAndClose() throws {
        let inner = MockBLETransport()
        let tracing = TracingBLETransport(wrapping: inner)

        try tracing.purge()
        try tracing.close()

        let entries = tracing.entries
        XCTAssertEqual(entries.count, 2)
        if case .purge = entries[0].operation {} else { XCTFail("Expected purge") }
        if case .close = entries[1].operation {} else { XCTFail("Expected close") }
    }

    // MARK: - Timeout Behavior Tests

    func testMockTransportReadTimeoutEmpty() throws {
        let transport = MockBLETransport()
        // No data at all

        XCTAssertThrowsError(try transport.read(count: 10, timeout: 1.0)) { error in
            XCTAssertEqual(error as? DiveComputerError, .timeout)
        }
        XCTAssertEqual(transport.operationLog, ["read(10) → timeout"])
    }

    // MARK: - Operation Sequence Tests

    func testOperationLogRecordsSequence() throws {
        let transport = MockBLETransport()
        transport.readData = [Data([0x01, 0x02])]

        try transport.write(Data([0xAA]), timeout: 5.0)
        _ = try transport.read(count: 2, timeout: 5.0)
        try transport.purge()
        try transport.close()

        XCTAssertEqual(transport.operationLog, [
            "write(1 bytes)",
            "read(2) → 2 bytes",
            "purge",
            "close",
        ])
    }

    func testWriteAfterCloseRecordsError() throws {
        let transport = MockBLETransport()
        try transport.close()

        XCTAssertThrowsError(try transport.write(Data([0x01]), timeout: 5.0))

        XCTAssertEqual(transport.operationLog, [
            "close",
            "write(1 bytes) → error:disconnected",
        ])
    }

    // MARK: - Hex Dump Tests

    func testDataHexDump() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(data.hexDump, "DE AD BE EF")

        let empty = Data()
        XCTAssertEqual(empty.hexDump, "")

        let single = Data([0x00])
        XCTAssertEqual(single.hexDump, "00")
    }

    // MARK: - Gas Mix Dedup Tests

    func testSaveImportedDiveDeduplicatesGasMixes() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let parsed = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0xDE, 0xAD]),
            gasMixes: [
                ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0),
                ParsedGasMix(index: 1, o2Fraction: 0.21, heFraction: 0.0),  // duplicate
                ParsedGasMix(index: 2, o2Fraction: 0.50, heFraction: 0.0, usage: "oxygen"),
            ]
        )

        try importService.saveImportedDive(parsed, deviceId: device.id)

        let dives = try diveService.listDives()
        let mixes = try diveService.getGasMixes(diveId: dives.first!.id)
        XCTAssertEqual(mixes.count, 2, "Duplicate gas mixes should be removed")
        XCTAssertEqual(mixes[0].o2Fraction, 0.21)
        XCTAssertEqual(mixes[1].o2Fraction, 0.50)
        // Verify sequential re-indexing
        XCTAssertEqual(mixes[0].mixIndex, 0)
        XCTAssertEqual(mixes[1].mixIndex, 1)
    }

    func testGetGasMixesDeduplicatesAtReadTime() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive)

        // Manually insert duplicate gas mixes (simulating pre-fix data)
        try diveService.saveGasMixes([
            GasMix(diveId: dive.id, mixIndex: 0, o2Fraction: 0.21, heFraction: 0.0),
            GasMix(diveId: dive.id, mixIndex: 1, o2Fraction: 0.21, heFraction: 0.0),
            GasMix(diveId: dive.id, mixIndex: 2, o2Fraction: 0.32, heFraction: 0.0, usage: "none"),
        ])

        let mixes = try diveService.getGasMixes(diveId: dive.id)
        XCTAssertEqual(mixes.count, 2, "Read-time dedup should remove duplicates")
    }
}
