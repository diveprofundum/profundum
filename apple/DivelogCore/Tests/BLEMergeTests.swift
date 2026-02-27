import XCTest
@testable import DivelogCore

/// Tests for BLE multi-computer sample merge in DiveComputerImportService.
final class BLEMergeTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!
    var importService: DiveComputerImportService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        importService = DiveComputerImportService(database: database)
    }

    // MARK: - Merge Tests

    func testMergeSamplesFromSecondComputer() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        let parsedA = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [
                ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0),
                ParsedSample(tSec: 60, depthM: 15.0, tempC: 20.0),
            ]
        )

        // First import — new dive
        let outcomeA = try importService.saveImportedDive(parsedA, deviceId: deviceA.id)
        XCTAssertEqual(outcomeA, .saved)

        let parsedB = ParsedDive(
            startTimeUnix: 1700000000,  // Same dive time
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x03, 0x04]),  // Different fingerprint
            samples: [
                ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5, tankPressure1Bar: 200.0),
                ParsedSample(tSec: 60, depthM: 15.0, tempC: 20.5, tankPressure1Bar: 190.0),
            ]
        )

        // Second import from different device — should merge
        let outcomeB = try importService.saveImportedDive(parsedB, deviceId: deviceB.id)
        XCTAssertEqual(outcomeB, .merged)

        // Only 1 dive should exist
        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)

        // Both devices' samples should be present
        let samples = try diveService.getSamples(diveId: dives[0].id)
        XCTAssertEqual(samples.count, 4)
        let deviceACount = samples.filter { $0.deviceId == deviceA.id }.count
        let deviceBCount = samples.filter { $0.deviceId == deviceB.id }.count
        XCTAssertEqual(deviceACount, 2)
        XCTAssertEqual(deviceBCount, 2)
    }

    func testMergeSkipsWhenSamplesAlreadyExist() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        let parsedA = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        try importService.saveImportedDive(parsedA, deviceId: deviceA.id)

        let parsedB = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x03, 0x04]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5)]
        )

        // First merge
        let mergeOutcome = try importService.saveImportedDive(parsedB, deviceId: deviceB.id)
        XCTAssertEqual(mergeOutcome, .merged)

        // Re-import device B — should be skipped (fingerprint dedup)
        let skipOutcome = try importService.saveImportedDive(parsedB, deviceId: deviceB.id)
        XCTAssertEqual(skipOutcome, .skipped)

        // Sample count should not increase
        let dives = try diveService.listDives()
        let samples = try diveService.getSamples(diveId: dives[0].id)
        XCTAssertEqual(samples.count, 2, "Samples should not be duplicated on re-import")
    }

    func testMergeDeduplicatesGasMixes() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        // Device A has Air + EAN50
        let parsedA = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)],
            gasMixes: [
                ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0),
                ParsedGasMix(index: 1, o2Fraction: 0.50, heFraction: 0.0),
            ]
        )
        try importService.saveImportedDive(parsedA, deviceId: deviceA.id)

        // Device B has Air (duplicate) + Trimix 21/35 (unique)
        let parsedB = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x03, 0x04]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5)],
            gasMixes: [
                ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0),
                ParsedGasMix(index: 1, o2Fraction: 0.21, heFraction: 0.35),
            ]
        )
        try importService.saveImportedDive(parsedB, deviceId: deviceB.id)

        let dives = try diveService.listDives()
        let mixes = try diveService.getGasMixes(diveId: dives[0].id)
        // Air + EAN50 + Trimix 21/35 = 3 unique mixes
        XCTAssertEqual(mixes.count, 3)
    }

    func testMergeGasMixIndexesContinueFromExisting() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        let parsedA = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)],
            gasMixes: [
                ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0),
            ]
        )
        try importService.saveImportedDive(parsedA, deviceId: deviceA.id)

        // Device B has a unique gas mix
        let parsedB = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x03, 0x04]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5)],
            gasMixes: [
                ParsedGasMix(index: 0, o2Fraction: 1.0, heFraction: 0.0, usage: "oxygen"),
            ]
        )
        try importService.saveImportedDive(parsedB, deviceId: deviceB.id)

        let dives = try diveService.listDives()
        let mixes = try diveService.getGasMixes(diveId: dives[0].id)
            .sorted(by: { $0.mixIndex < $1.mixIndex })
        XCTAssertEqual(mixes.count, 2)
        // First device's mix at index 0, second device's new mix at index 1
        XCTAssertEqual(mixes[0].mixIndex, 0)
        XCTAssertEqual(mixes[1].mixIndex, 1)
        XCTAssertEqual(mixes[1].o2Fraction, 1.0, accuracy: 0.001)
    }

    func testMergePreservesExistingDiveMetadata() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        let parsedA = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        try importService.saveImportedDive(parsedA, deviceId: deviceA.id)

        // Device B reports different depth (sensor variance)
        let parsedB = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 31.5,
            avgDepthM: 19.0,
            bottomTimeSec: 3100,
            fingerprint: Data([0x03, 0x04]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5)]
        )
        try importService.saveImportedDive(parsedB, deviceId: deviceB.id)

        // Original dive metadata should be unchanged
        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)
        XCTAssertEqual(dives[0].maxDepthM, 30.0, accuracy: 0.01, "Primary computer's depth should be canonical")
        XCTAssertEqual(dives[0].avgDepthM, 18.0, accuracy: 0.01)
        XCTAssertEqual(dives[0].bottomTimeSec, 3000)
    }

    func testMergeLinksFingerprints() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        let parsedA = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        try importService.saveImportedDive(parsedA, deviceId: deviceA.id)

        let parsedB = ParsedDive(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            fingerprint: Data([0x03, 0x04]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5)]
        )
        try importService.saveImportedDive(parsedB, deviceId: deviceB.id)

        let dives = try diveService.listDives()
        let fps = try diveService.getSourceFingerprints(diveId: dives[0].id)
        XCTAssertEqual(fps.count, 2)

        let fpA = fps.first(where: { $0.deviceId == deviceA.id })
        XCTAssertNotNil(fpA)
        XCTAssertEqual(fpA?.fingerprint, Data([0x01, 0x02]))

        let fpB = fps.first(where: { $0.deviceId == deviceB.id })
        XCTAssertNotNil(fpB)
        XCTAssertEqual(fpB?.fingerprint, Data([0x03, 0x04]))
    }
}
