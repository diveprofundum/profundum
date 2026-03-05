import XCTest
@testable import DivelogCore

/// Tests for cross-source deduplication between BLE and Shearwater Cloud imports.
final class CrossSourceDedupTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!
    var importService: DiveComputerImportService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        importService = DiveComputerImportService(database: database)
    }

    // MARK: - Shearwater-then-BLE Cross-Source Dedup

    func testShearwaterThenBLEDedup() throws {
        // Simulate a dive already imported via Shearwater Cloud:
        // different device_id, same start_time, different fingerprint
        let shearwaterDevice = Device(model: "Perdix", serialNumber: "SW-1234", firmwareVersion: "93")
        try diveService.saveDevice(shearwaterDevice)

        let shearwaterDive = Dive(
            deviceId: shearwaterDevice.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0xAA, 0xBB])  // Shearwater fingerprint
        )
        try diveService.saveDive(shearwaterDive)

        // Also save Shearwater fingerprint in dive_source_fingerprints
        try diveService.saveSourceFingerprints([
            DiveSourceFingerprint(
                diveId: shearwaterDive.id,
                deviceId: shearwaterDevice.id,
                fingerprint: Data([0xAA, 0xBB]),
                sourceType: "shearwater_cloud"
            )
        ])

        // Now import the same dive via BLE — different fingerprint, same time
        let bleDevice = Device(model: "Perdix BLE", serialNumber: "BLE-5678", firmwareVersion: "93")
        try diveService.saveDevice(bleDevice)

        let bleParsed = ParsedDive(
            startTimeUnix: 1700000000,  // Same start time
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0xCC, 0xDD]),  // Different BLE fingerprint
            samples: [
                ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0),
                ParsedSample(tSec: 60, depthM: 15.0, tempC: 20.0),
            ]
        )

        // BLE import should merge samples into the existing dive
        let outcome = try importService.saveImportedDive(bleParsed, deviceId: bleDevice.id)
        XCTAssertEqual(outcome, .merged)

        // Only 1 dive should exist
        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)

        // BLE fingerprint should be linked to the existing dive
        let fps = try diveService.getSourceFingerprints(diveId: shearwaterDive.id)
        XCTAssertEqual(fps.count, 2)
        let bleFp = fps.first(where: { $0.sourceType == "ble" })
        XCTAssertNotNil(bleFp)
        XCTAssertEqual(bleFp?.fingerprint, Data([0xCC, 0xDD]))
        XCTAssertEqual(bleFp?.deviceId, bleDevice.id)
    }

    func testShearwaterThenBLEDedupWithTimestampOffset() throws {
        // Same as above but with a small timestamp difference (overlapping time ranges)
        let shearwaterDevice = Device(model: "Perdix", serialNumber: "SW-1234", firmwareVersion: "93")
        try diveService.saveDevice(shearwaterDevice)

        let shearwaterDive = Dive(
            deviceId: shearwaterDevice.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0xAA, 0xBB])
        )
        try diveService.saveDive(shearwaterDive)

        let bleDevice = Device(model: "Perdix BLE", serialNumber: "BLE-5678", firmwareVersion: "93")
        try diveService.saveDevice(bleDevice)

        // BLE start time is 30 seconds off — should still match
        let bleParsed = ParsedDive(
            startTimeUnix: 1700000030,
            endTimeUnix: 1700003630,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0xCC, 0xDD]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )

        let outcome = try importService.saveImportedDive(bleParsed, deviceId: bleDevice.id)
        XCTAssertEqual(outcome, .merged)
        XCTAssertEqual(try diveService.listDives().count, 1)
    }

    // MARK: - BLE-then-BLE Fingerprint Dedup

    func testBLEThenBLEFingerprintDedup() throws {
        let device = Device(model: "Perdix", serialNumber: "BLE-1234", firmwareVersion: "93")
        try diveService.saveDevice(device)

        let parsed = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 25.0,
            avgDepthM: 15.0,
            bottomTimeSec: 2400,
            fingerprint: Data([0x01, 0x02, 0x03]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )

        // First import saves the dive
        let firstOutcome = try importService.saveImportedDive(parsed, deviceId: device.id)
        XCTAssertEqual(firstOutcome, .saved)

        // Second import with same fingerprint should be caught by fingerprint dedup
        let secondOutcome = try importService.saveImportedDive(parsed, deviceId: device.id)
        XCTAssertEqual(secondOutcome, .skipped)

        XCTAssertEqual(try diveService.listDives().count, 1)
    }

    func testBLEFingerprintDetectedViaSourceFingerprintsTable() throws {
        // Simulate a dive whose legacy fingerprint column differs, but the BLE
        // fingerprint is in dive_source_fingerprints
        let device = Device(model: "Perdix", serialNumber: "BLE-1234", firmwareVersion: "93")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 25.0,
            avgDepthM: 15.0,
            bottomTimeSec: 2400,
            fingerprint: Data([0xAA, 0xBB])  // Legacy fingerprint
        )
        try diveService.saveDive(dive)

        // Write a different fingerprint into dive_source_fingerprints
        try diveService.saveSourceFingerprints([
            DiveSourceFingerprint(
                diveId: dive.id,
                deviceId: device.id,
                fingerprint: Data([0xCC, 0xDD]),
                sourceType: "ble"
            )
        ])

        // findExistingDiveByFingerprint should find via source_fingerprints table
        let found = try importService.findExistingDiveByFingerprint(
            fingerprint: Data([0xCC, 0xDD])
        )
        XCTAssertEqual(found, dive.id)
    }

    // MARK: - Genuinely Different Dives

    func testDifferentDivesAreBothSaved() throws {
        let device1 = Device(model: "Perdix", serialNumber: "SW-1234", firmwareVersion: "93")
        let device2 = Device(model: "Perdix BLE", serialNumber: "BLE-5678", firmwareVersion: "93")
        try diveService.saveDevice(device1)
        try diveService.saveDevice(device2)

        // Dive 1: morning dive
        let shearwaterDive = Dive(
            deviceId: device1.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0xAA, 0xBB])
        )
        try diveService.saveDive(shearwaterDive)

        // Dive 2: afternoon dive — >300s apart
        let bleParsed = ParsedDive(
            startTimeUnix: 1700010000,  // 10000s later (~2.7 hours)
            endTimeUnix: 1700013600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000,
            fingerprint: Data([0xCC, 0xDD]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )

        let outcome = try importService.saveImportedDive(bleParsed, deviceId: device2.id)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(try diveService.listDives().count, 2)
    }

    func testTimeDedupDoesNotMatchSameDevice() throws {
        // Two dives from the SAME device with close timestamps should both be saved
        // (time-based dedup only matches different devices)
        let device = Device(model: "Perdix", serialNumber: "BLE-1234", firmwareVersion: "93")
        try diveService.saveDevice(device)

        let parsed1 = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 25.0,
            avgDepthM: 15.0,
            bottomTimeSec: 2400,
            fingerprint: Data([0x01]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )

        let parsed2 = ParsedDive(
            startTimeUnix: 1700000010,  // 10s later, same device
            endTimeUnix: 1700003610,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000,
            fingerprint: Data([0x02]),  // Different fingerprint
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 21.0)]
        )

        try importService.saveImportedDive(parsed1, deviceId: device.id)
        let outcome = try importService.saveImportedDive(parsed2, deviceId: device.id)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(try diveService.listDives().count, 2)
    }

    // MARK: - BLE Import Writes Source Fingerprint

    func testNewBLEDiveWritesSourceFingerprint() throws {
        let device = Device(model: "Perdix", serialNumber: "BLE-1234", firmwareVersion: "93")
        try diveService.saveDevice(device)

        let parsed = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 25.0,
            avgDepthM: 15.0,
            bottomTimeSec: 2400,
            fingerprint: Data([0xDE, 0xAD]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )

        try importService.saveImportedDive(parsed, deviceId: device.id)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)

        // Verify dive_source_fingerprints was written
        let fps = try diveService.getSourceFingerprints(diveId: dives[0].id)
        XCTAssertEqual(fps.count, 1)
        XCTAssertEqual(fps[0].fingerprint, Data([0xDE, 0xAD]))
        XCTAssertEqual(fps[0].sourceType, "ble")
        XCTAssertEqual(fps[0].deviceId, device.id)
    }

    func testDiveWithoutFingerprintDoesNotWriteSourceFingerprint() throws {
        let device = Device(model: "Perdix", serialNumber: "BLE-1234", firmwareVersion: "93")
        try diveService.saveDevice(device)

        let parsed = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000
            // No fingerprint
        )

        try importService.saveImportedDive(parsed, deviceId: device.id)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)

        // No source fingerprint should be written
        let fps = try diveService.getSourceFingerprints(diveId: dives[0].id)
        XCTAssertEqual(fps.count, 0)
    }

    // MARK: - Time Boundary Tests

    func testTimeDedupAtExactBoundary() throws {
        let shearwaterDevice = Device(model: "Perdix", serialNumber: "SW-1234", firmwareVersion: "93")
        let bleDevice = Device(model: "Perdix BLE", serialNumber: "BLE-5678", firmwareVersion: "93")
        try diveService.saveDevice(shearwaterDevice)
        try diveService.saveDevice(bleDevice)

        let shearwaterDive = Dive(
            deviceId: shearwaterDevice.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(shearwaterDive)

        // 300s offset — overlapping time ranges, should merge
        let bleParsedAtBoundary = ParsedDive(
            startTimeUnix: 1700000300,
            endTimeUnix: 1700003900,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0xEE, 0xFF]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        let boundaryOutcome = try importService.saveImportedDive(bleParsedAtBoundary, deviceId: bleDevice.id)
        XCTAssertEqual(boundaryOutcome, .merged, "Overlapping dive should be merged")

        // Non-overlapping: starts after existing dive ends → should be saved as new
        let bleParsedBeyond = ParsedDive(
            startTimeUnix: 1700003700,  // starts 100s after existing dive ends
            endTimeUnix: 1700007300,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x11, 0x22]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        let beyondOutcome = try importService.saveImportedDive(bleParsedBeyond, deviceId: bleDevice.id)
        XCTAssertEqual(beyondOutcome, .saved, "Non-overlapping dive should be saved as new")
    }

    // MARK: - Duplicate Fingerprint Linking Is Idempotent

    func testLinkingFingerprintTwiceDoesNotDuplicate() throws {
        let shearwaterDevice = Device(model: "Perdix", serialNumber: "SW-1234", firmwareVersion: "93")
        let bleDevice = Device(model: "Perdix BLE", serialNumber: "BLE-5678", firmwareVersion: "93")
        try diveService.saveDevice(shearwaterDevice)
        try diveService.saveDevice(bleDevice)

        let shearwaterDive = Dive(
            deviceId: shearwaterDevice.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(shearwaterDive)

        let bleParsed = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0xCC, 0xDD]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )

        // Import twice — fingerprint should only be linked once
        try importService.saveImportedDive(bleParsed, deviceId: bleDevice.id)
        try importService.saveImportedDive(bleParsed, deviceId: bleDevice.id)

        let fps = try diveService.getSourceFingerprints(diveId: shearwaterDive.id)
        XCTAssertEqual(fps.count, 1, "Fingerprint should only be linked once")
    }
}
