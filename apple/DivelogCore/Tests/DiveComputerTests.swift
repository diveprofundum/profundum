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

    /// PRO-70: a secondary computer whose dives were all merged into another
    /// device's dives has fingerprints only in `dive_source_fingerprints`.
    /// `lastFingerprint` must find them, or incremental sync silently degrades
    /// to a full re-download on every import.
    func testLastFingerprintFindsSecondaryDeviceViaSourceFingerprints() throws {
        let primary = Device(model: "Petrel", serialNumber: "P1", firmwareVersion: "1.0")
        let secondary = Device(model: "Perdix", serialNumber: "S1", firmwareVersion: "1.0")
        try diveService.saveDevice(primary)
        try diveService.saveDevice(secondary)

        // Dive owned by the primary; the secondary only contributed samples.
        let primaryFP = Data([0xA1])
        let secondaryFP = Data([0xB1])
        let dive = Dive(
            deviceId: primary.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: primaryFP
        )
        try diveService.saveDive(dive)
        try database.dbQueue.write { db in
            try DiveSourceFingerprint(
                diveId: dive.id, deviceId: secondary.id,
                fingerprint: secondaryFP, sourceType: "ble"
            ).insert(db)
        }

        XCTAssertEqual(try importService.lastFingerprint(deviceId: secondary.id), secondaryFP)
        // Primary is unaffected and does not pick up the secondary's fingerprint.
        XCTAssertEqual(try importService.lastFingerprint(deviceId: primary.id), primaryFP)
    }

    /// PRO-70: when a device is primary on some dives and secondary on others,
    /// the newest dive wins regardless of which table holds the fingerprint.
    func testLastFingerprintPicksNewestAcrossLegacyAndSourceFingerprints() throws {
        let deviceA = Device(model: "Petrel", serialNumber: "A", firmwareVersion: "1.0")
        let deviceB = Device(model: "Perdix", serialNumber: "B", firmwareVersion: "1.0")
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        // Older dive: B is primary (legacy column).
        let olderFP = Data([0x01])
        let older = Dive(
            deviceId: deviceB.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000,
            fingerprint: olderFP
        )
        try diveService.saveDive(older)

        // Newer dive: A is primary, B merged in (source fingerprint only).
        let newerFPForB = Data([0x02])
        let newer = Dive(
            deviceId: deviceA.id,
            startTimeUnix: 1700100000,
            endTimeUnix: 1700103600,
            maxDepthM: 25.0,
            avgDepthM: 15.0,
            bottomTimeSec: 2500,
            fingerprint: Data([0xAA])
        )
        try diveService.saveDive(newer)
        try database.dbQueue.write { db in
            try DiveSourceFingerprint(
                diveId: newer.id, deviceId: deviceB.id,
                fingerprint: newerFPForB, sourceType: "ble"
            ).insert(db)
        }

        XCTAssertEqual(try importService.lastFingerprint(deviceId: deviceB.id), newerFPForB)

        // And the reverse: newest dive is one where B is primary. The BLE save
        // path writes both dives.fingerprint and a 'ble' source row.
        let newestFP = Data([0x03])
        let newest = Dive(
            deviceId: deviceB.id,
            startTimeUnix: 1700200000,
            endTimeUnix: 1700203600,
            maxDepthM: 22.0,
            avgDepthM: 14.0,
            bottomTimeSec: 2200,
            fingerprint: newestFP
        )
        try diveService.saveDive(newest)
        try database.dbQueue.write { db in
            try DiveSourceFingerprint(
                diveId: newest.id, deviceId: deviceB.id,
                fingerprint: newestFP, sourceType: "ble"
            ).insert(db)
        }
        XCTAssertEqual(try importService.lastFingerprint(deviceId: deviceB.id), newestFP)
    }

    /// PRO-70 end-to-end: after a real merge via `saveImportedDive`, the
    /// secondary device's BLE fingerprint is what `lastFingerprint` returns.
    func testLastFingerprintAfterMergeReturnsSecondaryBLEFingerprint() throws {
        let primary = Device(model: "Petrel", serialNumber: "P2", firmwareVersion: "1.0", ownership: .mine)
        let secondary = Device(model: "Perdix", serialNumber: "S2", firmwareVersion: "1.0", ownership: .mine)
        try diveService.saveDevice(primary)
        try diveService.saveDevice(secondary)

        let samples = [
            ParsedSample(tSec: 0, depthM: 0, tempC: 20),
            ParsedSample(tSec: 60, depthM: 20, tempC: 19),
            ParsedSample(tSec: 120, depthM: 0, tempC: 20),
        ]
        let fromPrimary = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700000120,
            maxDepthM: 20, avgDepthM: 10, bottomTimeSec: 120,
            fingerprint: Data([0xA2, 0x01]), samples: samples
        )
        let fromSecondary = ParsedDive(
            startTimeUnix: 1700000005, endTimeUnix: 1700000125,
            maxDepthM: 20, avgDepthM: 10, bottomTimeSec: 120,
            fingerprint: Data([0xB2, 0x02]), samples: samples
        )

        XCTAssertEqual(try importService.saveImportedDive(fromPrimary, deviceId: primary.id), .saved)
        XCTAssertEqual(try importService.saveImportedDive(fromSecondary, deviceId: secondary.id), .merged)

        XCTAssertEqual(try importService.lastFingerprint(deviceId: secondary.id), Data([0xB2, 0x02]))
        XCTAssertEqual(try importService.lastFingerprint(deviceId: primary.id), Data([0xA2, 0x01]))

        // Both were written by the BLE path, so they are trusted as .ble.
        XCTAssertEqual(try importService.lastSyncFingerprint(deviceId: secondary.id)?.source, .ble)
        XCTAssertEqual(try importService.lastSyncFingerprint(deviceId: primary.id)?.source, .ble)
    }

    /// PRO-70: a BLE-sourced fingerprint is preferred over a newer non-BLE one
    /// (e.g. Shearwater Cloud, whose fingerprints libdivecomputer cannot match),
    /// and the source is reported so callers can size the auto-stop window.
    func testLastSyncFingerprintPrefersBLESourceOverNewerCloudSource() throws {
        let device = Device(model: "Perdix", serialNumber: "C1", firmwareVersion: "1.0")
        let otherDevice = Device(model: "Petrel", serialNumber: "C2", firmwareVersion: "1.0")
        try diveService.saveDevice(device)
        try diveService.saveDevice(otherDevice)

        // Older dive, BLE-imported: source row with 'ble'.
        let bleFP = Data([0x10, 0x20, 0x30, 0x40])
        let olderBLE = Dive(
            deviceId: otherDevice.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 12, bottomTimeSec: 2000,
            fingerprint: Data([0xFF])
        )
        try diveService.saveDive(olderBLE)

        // Newer dive, Cloud-imported: UTF-8 dive ID as fingerprint.
        let cloudFP = "123456789".data(using: .utf8)!
        let newerCloud = Dive(
            deviceId: device.id,
            startTimeUnix: 1700100000, endTimeUnix: 1700103600,
            maxDepthM: 25, avgDepthM: 15, bottomTimeSec: 2500,
            fingerprint: cloudFP
        )
        try diveService.saveDive(newerCloud)

        try database.dbQueue.write { db in
            try DiveSourceFingerprint(
                diveId: olderBLE.id, deviceId: device.id, fingerprint: bleFP, sourceType: "ble"
            ).insert(db)
            try DiveSourceFingerprint(
                diveId: newerCloud.id, deviceId: device.id, fingerprint: cloudFP,
                sourceType: "shearwater_cloud"
            ).insert(db)
        }

        let result = try XCTUnwrap(try importService.lastSyncFingerprint(deviceId: device.id))
        XCTAssertEqual(result.fingerprint, bleFP)
        XCTAssertEqual(result.source, .ble)
    }

    /// PRO-70: with no BLE-sourced row at all, fall back to the legacy union
    /// (which may be a Cloud fingerprint) and report it as such.
    func testLastSyncFingerprintFallsBackToLegacyWhenNoBLESource() throws {
        let device = Device(model: "Perdix", serialNumber: "L1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let legacyFP = Data([0xAB, 0xCD])
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 12, bottomTimeSec: 2000,
            fingerprint: legacyFP
        )
        try diveService.saveDive(dive)

        let result = try XCTUnwrap(try importService.lastSyncFingerprint(deviceId: device.id))
        XCTAssertEqual(result.fingerprint, legacyFP)
        XCTAssertEqual(result.source, .legacy)

        XCTAssertNil(try importService.lastSyncFingerprint(deviceId: "nonexistent"))
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
                ParsedSample(tSec: 120, depthM: 35.0, tempC: 18.0, ceilingM: 3.0, gf99: 85.0, atPlusFiveTtsMin: 12),
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
        XCTAssertNil(samples[0].atPlusFiveTtsMin)
        XCTAssertEqual(samples[1].setpointPpo2, 1.3)
        XCTAssertEqual(samples[2].ceilingM, 3.0)
        XCTAssertEqual(samples[2].gf99, 85.0)
        XCTAssertEqual(samples[2].atPlusFiveTtsMin, 12)

        // All samples should share the dive ID
        for sample in samples {
            XCTAssertEqual(sample.diveId, dive.id)
        }
    }

    // MARK: - PNF Sample Field Extraction Tests

    func testExtractPnfSampleFieldsTooSmall() {
        // Data smaller than one 32-byte record → empty arrays
        let pnf = DiveDataMapper.extractPnfSampleFields(Data(repeating: 0, count: 16))
        XCTAssertTrue(pnf.gf99.isEmpty)
        XCTAssertTrue(pnf.atPlusFiveTtsMin.isEmpty)
    }

    func testExtractPnfSampleFieldsPnfFormat() {
        // Build a PNF record: byte 0 = record type (0x01 = dive sample),
        // bytes 1-31 = data. GF99 at raw byte 25, @+5 at raw byte 27.
        var record = Data(repeating: 0, count: 32)
        record[0] = 0x01  // dive sample record type
        record[25] = 72   // GF99 = 72%
        record[27] = 15   // @+5 = 15 minutes

        let pnf = DiveDataMapper.extractPnfSampleFields(record)
        XCTAssertEqual(pnf.gf99.count, 1)
        XCTAssertEqual(pnf.gf99[0], 72.0)
        XCTAssertEqual(pnf.atPlusFiveTtsMin.count, 1)
        XCTAssertEqual(pnf.atPlusFiveTtsMin[0], 15)
    }

    func testExtractPnfSampleFieldsSentinelValues() {
        // GF99=0 (no tissue load) → nil, @+5=0 (no deco) → nil
        var record1 = Data(repeating: 0, count: 32)
        record1[0] = 0x01
        record1[25] = 0   // GF99 sentinel
        record1[27] = 0   // @+5 sentinel

        // GF99=0xFF (not computed) → nil, @+5=8 → valid
        var record2 = Data(repeating: 0, count: 32)
        record2[0] = 0x01
        record2[25] = 0xFF
        record2[27] = 8

        var data = Data()
        data.append(record1)
        data.append(record2)

        let pnf = DiveDataMapper.extractPnfSampleFields(data)
        XCTAssertEqual(pnf.gf99.count, 2)
        XCTAssertNil(pnf.gf99[0])
        XCTAssertNil(pnf.gf99[1])
        XCTAssertEqual(pnf.atPlusFiveTtsMin.count, 2)
        XCTAssertNil(pnf.atPlusFiveTtsMin[0])
        XCTAssertEqual(pnf.atPlusFiveTtsMin[1], 8)
    }

    func testExtractPnfSampleFieldsSkipsNonDiveRecords() {
        // Record type 0x02 (not a dive sample) should be skipped
        var nonDive = Data(repeating: 0, count: 32)
        nonDive[0] = 0x02
        nonDive[25] = 50
        nonDive[27] = 10

        var diveSample = Data(repeating: 0, count: 32)
        diveSample[0] = 0x01
        diveSample[25] = 80
        diveSample[27] = 20

        var data = Data()
        data.append(nonDive)
        data.append(diveSample)

        let pnf = DiveDataMapper.extractPnfSampleFields(data)
        XCTAssertEqual(pnf.gf99.count, 1)
        XCTAssertEqual(pnf.gf99[0], 80.0)
        XCTAssertEqual(pnf.atPlusFiveTtsMin[0], 20)
    }

    func testExtractPnfSampleFieldsStopsAtFinalRecord() {
        // 0xFF record type = LOG_RECORD_FINAL, should stop parsing
        var diveSample = Data(repeating: 0, count: 32)
        diveSample[0] = 0x01
        diveSample[25] = 60
        diveSample[27] = 5

        var finalRecord = Data(repeating: 0, count: 32)
        finalRecord[0] = 0xFF

        var trailingDive = Data(repeating: 0, count: 32)
        trailingDive[0] = 0x01
        trailingDive[25] = 90
        trailingDive[27] = 25

        var data = Data()
        data.append(diveSample)
        data.append(finalRecord)
        data.append(trailingDive)

        let pnf = DiveDataMapper.extractPnfSampleFields(data)
        XCTAssertEqual(pnf.gf99.count, 1, "Should stop at final record")
        XCTAssertEqual(pnf.gf99[0], 60.0)
        XCTAssertEqual(pnf.atPlusFiveTtsMin[0], 5)
    }

    func testExtractPnfSampleFieldsNonPnfFormat() {
        // Non-PNF: starts with 0xFFFF, has 128-byte header + 128-byte footer.
        // GF99 at raw byte 24, @+5 at raw byte 26.
        let headerSize = 128
        let footerSize = 128

        var header = Data(repeating: 0, count: headerSize)
        header[0] = 0xFF
        header[1] = 0xFF

        var record = Data(repeating: 0, count: 32)
        record[24] = 55   // GF99
        record[26] = 7    // @+5

        let footer = Data(repeating: 0, count: footerSize)

        var data = Data()
        data.append(header)
        data.append(record)
        data.append(footer)

        let pnf = DiveDataMapper.extractPnfSampleFields(data)
        XCTAssertEqual(pnf.gf99.count, 1)
        XCTAssertEqual(pnf.gf99[0], 55.0)
        XCTAssertEqual(pnf.atPlusFiveTtsMin.count, 1)
        XCTAssertEqual(pnf.atPlusFiveTtsMin[0], 7)
    }

    func testExtractPnfSampleFieldsNonPnfTooSmallForContent() {
        // Non-PNF with only header+footer, no sample records
        var data = Data(repeating: 0xFF, count: 256)
        data[0] = 0xFF
        data[1] = 0xFF

        let pnf = DiveDataMapper.extractPnfSampleFields(data)
        XCTAssertTrue(pnf.gf99.isEmpty)
        XCTAssertTrue(pnf.atPlusFiveTtsMin.isEmpty)
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
        XCTAssertEqual(firstSave, .saved)

        // Second save with same fingerprint should be skipped
        let secondSave = try importService.saveImportedDive(parsed, deviceId: device.id)
        XCTAssertEqual(secondSave, .skipped)

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
        XCTAssertEqual(saved, .saved)

        // Can save again (no fingerprint = no dedup)
        let savedAgain = try importService.saveImportedDive(parsed, deviceId: device.id)
        XCTAssertEqual(savedAgain, .saved)

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

    // MARK: - Halcyon Symbios Tests

    func testHalcyonSymbiosUUIDs() {
        let halcyon = KnownDiveComputer.halcyonSymbios
        XCTAssertEqual(halcyon.serviceUUID, "18424398-7CBC-11E9-8F9E-2A86E4087070")
        XCTAssertEqual(halcyon.characteristicUUID, "00000201-8C3B-4F2C-A59E-8C08224F3253")
        XCTAssertEqual(halcyon.dataServiceUUID, "00000001-8C3B-4F2C-A59E-8C08224F3253")
        XCTAssertEqual(halcyon.writeCharacteristicUUID, "00000101-8C3B-4F2C-A59E-8C08224F3253")
        XCTAssertEqual(halcyon.vendorName, "Halcyon")
    }

    func testHalcyonLookupByServiceUUID() {
        let found = KnownDiveComputer.from(serviceUUID: "18424398-7CBC-11E9-8F9E-2A86E4087070")
        XCTAssertEqual(found, .halcyonSymbios)

        // Case-insensitive
        let foundLower = KnownDiveComputer.from(serviceUUID: "18424398-7cbc-11e9-8f9e-2a86e4087070")
        XCTAssertEqual(foundLower, .halcyonSymbios)
    }

    func testAllServiceUUIDsIncludesHalcyon() {
        XCTAssertTrue(
            KnownDiveComputer.allServiceUUIDs.contains("18424398-7CBC-11E9-8F9E-2A86E4087070")
        )
    }

    // MARK: - parseDeviceName Tests

    func testHalcyonParseDeviceName() {
        let result = KnownDiveComputer.halcyonSymbios.parseDeviceName("2408070161")
        XCTAssertEqual(result?.model, "Symbios Handset")
        XCTAssertEqual(result?.serial, "2408070161")
    }

    func testHalcyonParseDeviceNameUnknownModel() {
        let result = KnownDiveComputer.halcyonSymbios.parseDeviceName("2408990161")
        XCTAssertEqual(result?.model, "Symbios")
        XCTAssertEqual(result?.serial, "2408990161")
    }

    func testHalcyonParseDeviceNameEmpty() {
        let result = KnownDiveComputer.halcyonSymbios.parseDeviceName("")
        XCTAssertNil(result)
    }

    func testHalcyonParseDeviceNameTooShort() {
        let result = KnownDiveComputer.halcyonSymbios.parseDeviceName("12345")
        XCTAssertNil(result)
    }

    func testHalcyonParseDeviceNameNonNumeric() {
        let result = KnownDiveComputer.halcyonSymbios.parseDeviceName("Perdix 2")
        XCTAssertNil(result)
    }

    func testExistingDevicesParseDeviceNameNil() {
        let existingDevices: [KnownDiveComputer] = [
            .shearwater, .hwOstc, .suuntoEon, .garminDescent, .maresGenius,
        ]
        for device in existingDevices {
            XCTAssertNil(
                device.parseDeviceName("2408070161"),
                "\(device) should return nil from parseDeviceName"
            )
        }
    }

    func testExistingDevicesReturnNilForNewProperties() {
        // All pre-existing devices should return nil for the new optional properties
        let existingDevices: [KnownDiveComputer] = [
            .shearwater, .hwOstc, .suuntoEon, .garminDescent, .maresGenius,
        ]
        for device in existingDevices {
            XCTAssertNil(device.dataServiceUUID, "\(device) should have nil dataServiceUUID")
            XCTAssertNil(
                device.writeCharacteristicUUID,
                "\(device) should have nil writeCharacteristicUUID"
            )
        }
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

    func testRetryableErrors() {
        // Communication failures are retryable
        XCTAssertTrue(DiveComputerError.timeout.isRetryable)
        XCTAssertTrue(DiveComputerError.disconnected.isRetryable)
        XCTAssertTrue(
            DiveComputerError.libdivecomputer(status: -8, message: "protocol").isRetryable
        )

        // Deterministic failures are not retryable
        XCTAssertFalse(DiveComputerError.cancelled.isRetryable)
        XCTAssertFalse(DiveComputerError.unsupportedDevice.isRetryable)
        XCTAssertFalse(DiveComputerError.duplicateDive.isRetryable)
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

    /// PRO-71: traces are rendered as text lines covering every operation kind,
    /// so a failing import can be diagnosed from a file pulled off the device.
    func testTraceLinesCoverAllOperations() throws {
        let inner = MockBLETransport()
        inner.readData = [Data([0x85, 0x15, 0x04, 0x9C])]  // Halcyon NAK, ERR_TIMEOUT
        inner.maxWriteSize = 1
        let tracing = TracingBLETransport(wrapping: inner)

        try tracing.write(Data([0x06]), timeout: 1)
        _ = try tracing.read(count: 259, timeout: 1)
        XCTAssertThrowsError(try tracing.read(count: 4, timeout: 0.1))
        XCTAssertThrowsError(try tracing.write(Data([0x01, 0x02]), timeout: 1))
        tracing.recordSetTimeout(ms: 3000)
        try tracing.purge()
        try tracing.close()

        let lines = tracing.traceLines()
        XCTAssertEqual(lines.first, "=== BLE Transport Trace (7 entries) ===")
        XCTAssertEqual(lines.last, "=== End Trace ===")
        // writeError emits two lines, so 7 entries → 8 body lines + 2 brackets.
        XCTAssertEqual(lines.count, 10)
        XCTAssertTrue(lines.contains { $0.contains("WRITE 1B | 06") })
        XCTAssertTrue(lines.contains { $0.contains("READ req=259 got=4 | 85 15 04 9C") })
        XCTAssertTrue(lines.contains { $0.contains("READ req=4 ERROR:") })
        XCTAssertTrue(lines.contains { $0.contains("WRITE 2B ERR") })
        XCTAssertTrue(lines.contains { $0.contains("WRITE data: 01 02") })
        XCTAssertTrue(lines.contains { $0.contains("SET_TIMEOUT 3000 ms") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("PURGE") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("CLOSE") })
    }

    func testWriteTraceCreatesFileWithHeader() throws {
        let inner = MockBLETransport()
        let tracing = TracingBLETransport(wrapping: inner)
        try tracing.write(Data([0x01]), timeout: 1)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-test-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("nested").appendingPathComponent("trace.txt")
        defer { try? FileManager.default.removeItem(at: dir) }

        let written = try tracing.writeTrace(to: url, header: ["device: Symbios", "reason: timeout", ""])
        XCTAssertEqual(written, url)

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "device: Symbios")
        XCTAssertEqual(lines[1], "reason: timeout")
        XCTAssertEqual(lines[2], "")
        XCTAssertEqual(lines[3], "=== BLE Transport Trace (1 entries) ===")
        XCTAssertTrue(text.contains("WRITE 1B | 01"))
        XCTAssertTrue(text.hasSuffix("=== End Trace ===\n"))
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

    // MARK: - DiveSample.deltaFiveTtsMin Tests

    func testDeltaFiveBothPresentPositive() {
        let sample = DiveSample(diveId: "d1", tSec: 0, depthM: 30, tempC: 20,
                                ttsSec: 600, atPlusFiveTtsMin: 15)
        XCTAssertEqual(sample.deltaFiveTtsMin, 5)
    }

    func testDeltaFiveBothPresentNegative() {
        let sample = DiveSample(diveId: "d1", tSec: 0, depthM: 30, tempC: 20,
                                ttsSec: 480, atPlusFiveTtsMin: 3)
        XCTAssertEqual(sample.deltaFiveTtsMin, -5)
    }

    func testDeltaFiveBothPresentZero() {
        let sample = DiveSample(diveId: "d1", tSec: 0, depthM: 30, tempC: 20,
                                ttsSec: 600, atPlusFiveTtsMin: 10)
        XCTAssertEqual(sample.deltaFiveTtsMin, 0)
    }

    func testDeltaFiveAtPlusFiveNil() {
        let sample = DiveSample(diveId: "d1", tSec: 0, depthM: 30, tempC: 20,
                                ttsSec: 600, atPlusFiveTtsMin: nil)
        XCTAssertNil(sample.deltaFiveTtsMin)
    }

    func testDeltaFiveTtsNilAtPlusFivePresent() {
        let sample = DiveSample(diveId: "d1", tSec: 0, depthM: 30, tempC: 20,
                                ttsSec: nil, atPlusFiveTtsMin: 12)
        XCTAssertEqual(sample.deltaFiveTtsMin, 12)
    }

    func testDeltaFiveBothNil() {
        let sample = DiveSample(diveId: "d1", tSec: 0, depthM: 30, tempC: 20,
                                ttsSec: nil, atPlusFiveTtsMin: nil)
        XCTAssertNil(sample.deltaFiveTtsMin)
    }
}
