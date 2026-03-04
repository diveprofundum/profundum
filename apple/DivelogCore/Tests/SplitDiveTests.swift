import XCTest
@testable import DivelogCore

/// Tests for the splitDive (un-merge) functionality.
final class SplitDiveTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!
    var importService: DiveComputerImportService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        importService = DiveComputerImportService(database: database)
    }

    // MARK: - Helpers

    /// Creates a merged dive from two devices and returns the dive ID.
    private func createMergedDive(
        deviceA: Device, deviceB: Device,
        gasMixesA: [ParsedGasMix] = [],
        gasMixesB: [ParsedGasMix] = [],
        samplesA: [ParsedSample]? = nil,
        samplesB: [ParsedSample]? = nil
    ) throws -> String {
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        let defaultSamplesA = [
            ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0),
            ParsedSample(tSec: 60, depthM: 15.0, tempC: 20.0),
            ParsedSample(tSec: 120, depthM: 30.0, tempC: 18.0),
        ]
        let defaultSamplesB = [
            ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5),
            ParsedSample(tSec: 60, depthM: 14.5, tempC: 20.5),
            ParsedSample(tSec: 120, depthM: 29.5, tempC: 18.5),
        ]

        let parsedA = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 30.0, avgDepthM: 18.0, bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: samplesA ?? defaultSamplesA,
            gasMixes: gasMixesA
        )
        try importService.saveImportedDive(parsedA, deviceId: deviceA.id)

        let parsedB = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 29.5, avgDepthM: 17.5, bottomTimeSec: 3000,
            fingerprint: Data([0x03, 0x04]),
            samples: samplesB ?? defaultSamplesB,
            gasMixes: gasMixesB
        )
        let outcome = try importService.saveImportedDive(parsedB, deviceId: deviceB.id)
        XCTAssertEqual(outcome, .merged)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)
        return dives[0].id
    }

    // MARK: - Success Cases

    func testSplitMovesCorrectSamples() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        let diveId = try createMergedDive(deviceA: deviceA, deviceB: deviceB)

        // Verify merged state: 6 samples total
        let allSamples = try diveService.getSamples(diveId: diveId)
        XCTAssertEqual(allSamples.count, 6)

        // Split device B out
        let result = try importService.splitDive(diveId: diveId, deviceId: deviceB.id)
        XCTAssertEqual(result.originalDiveId, diveId)

        // Original should have only device A's samples
        let originalSamples = try diveService.getSamples(diveId: diveId)
        XCTAssertEqual(originalSamples.count, 3)
        XCTAssertTrue(originalSamples.allSatisfy { $0.deviceId == deviceA.id })

        // New dive should have device B's samples
        let newSamples = try diveService.getSamples(diveId: result.newDiveId)
        XCTAssertEqual(newSamples.count, 3)
        XCTAssertTrue(newSamples.allSatisfy { $0.deviceId == deviceB.id })
    }

    func testSplitCreatesNewDiveWithCorrectStats() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        let diveId = try createMergedDive(deviceA: deviceA, deviceB: deviceB)

        let result = try importService.splitDive(diveId: diveId, deviceId: deviceB.id)

        // New dive should exist with correct device
        let newDive = try diveService.getDive(id: result.newDiveId)
        XCTAssertNotNil(newDive)
        XCTAssertEqual(newDive?.deviceId, deviceB.id)

        // Stats should be recomputed from B's samples (max depth 29.5)
        XCTAssertEqual(newDive?.maxDepthM ?? 0, 29.5, accuracy: 0.1)
    }

    func testSplitRecomputesOriginalStats() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        let diveId = try createMergedDive(deviceA: deviceA, deviceB: deviceB)

        _ = try importService.splitDive(diveId: diveId, deviceId: deviceB.id)

        // Original dive stats should be recomputed from A's samples only
        let originalDive = try diveService.getDive(id: diveId)
        XCTAssertEqual(originalDive?.maxDepthM ?? 0, 30.0, accuracy: 0.1)
    }

    func testSplitDuplicatesGasMixes() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")

        let gasMixes = [ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0)]
        let samplesA = [
            ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0, gasmixIndex: 0),
            ParsedSample(tSec: 60, depthM: 15.0, tempC: 20.0, gasmixIndex: 0),
        ]
        let samplesB = [
            ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5, gasmixIndex: 0),
            ParsedSample(tSec: 60, depthM: 14.5, tempC: 20.5, gasmixIndex: 0),
        ]

        let diveId = try createMergedDive(
            deviceA: deviceA, deviceB: deviceB,
            gasMixesA: gasMixes, gasMixesB: gasMixes,
            samplesA: samplesA, samplesB: samplesB
        )

        let result = try importService.splitDive(diveId: diveId, deviceId: deviceB.id)

        // Both dives should have gas mixes
        let originalMixes = try diveService.getGasMixes(diveId: diveId)
        let newMixes = try diveService.getGasMixes(diveId: result.newDiveId)
        XCTAssertFalse(originalMixes.isEmpty, "Original should keep gas mixes")
        XCTAssertFalse(newMixes.isEmpty, "New dive should have duplicated gas mixes")
        XCTAssertEqual(newMixes[0].o2Fraction, 0.21, accuracy: 0.001)
    }

    func testSplitRemapsGasMixIndices() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")

        // A has air(0)+nx50(1), B uses only nx50(1)
        let mixesA = [
            ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0),
            ParsedGasMix(index: 1, o2Fraction: 0.50, heFraction: 0.0),
        ]
        let mixesB = [
            ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0),
            ParsedGasMix(index: 1, o2Fraction: 0.50, heFraction: 0.0),
        ]
        let samplesA = [
            ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0, gasmixIndex: 0),
            ParsedSample(tSec: 60, depthM: 15.0, tempC: 20.0, gasmixIndex: 1),
        ]
        let samplesB = [
            ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5, gasmixIndex: 1),
            ParsedSample(tSec: 60, depthM: 14.5, tempC: 20.5, gasmixIndex: 1),
        ]

        let diveId = try createMergedDive(
            deviceA: deviceA, deviceB: deviceB,
            gasMixesA: mixesA, gasMixesB: mixesB,
            samplesA: samplesA, samplesB: samplesB
        )

        let result = try importService.splitDive(diveId: diveId, deviceId: deviceB.id)

        // B only used mix index 1, which should be remapped to 0 in the new dive
        let newSamples = try diveService.getSamples(diveId: result.newDiveId)
        XCTAssertTrue(newSamples.allSatisfy { $0.gasmixIndex == 0 },
                       "All samples should reference remapped index 0")

        let newMixes = try diveService.getGasMixes(diveId: result.newDiveId)
        XCTAssertEqual(newMixes.count, 1, "Only referenced mix should be duplicated")
        XCTAssertEqual(newMixes[0].o2Fraction, 0.50, accuracy: 0.001)
        XCTAssertEqual(newMixes[0].mixIndex, 0)
    }

    func testSplitMovesFingerprints() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        let diveId = try createMergedDive(deviceA: deviceA, deviceB: deviceB)

        let result = try importService.splitDive(diveId: diveId, deviceId: deviceB.id)

        // Fingerprints should be split correctly
        let originalFps = try diveService.getSourceFingerprints(diveId: diveId)
        let newFps = try diveService.getSourceFingerprints(diveId: result.newDiveId)
        XCTAssertEqual(originalFps.count, 1)
        XCTAssertEqual(originalFps[0].deviceId, deviceA.id)
        XCTAssertEqual(newFps.count, 1)
        XCTAssertEqual(newFps[0].deviceId, deviceB.id)
    }

    func testSplitCopiesTags() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        let diveId = try createMergedDive(deviceA: deviceA, deviceB: deviceB)

        let result = try importService.splitDive(diveId: diveId, deviceId: deviceB.id)

        let originalTags = try diveService.getTags(diveId: diveId)
        let newTags = try diveService.getTags(diveId: result.newDiveId)
        XCTAssertEqual(Set(originalTags), Set(newTags), "Tags should be copied to new dive")
    }

    func testSplitPrimaryDeviceReassignsOriginal() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        let diveId = try createMergedDive(deviceA: deviceA, deviceB: deviceB)

        // The merged dive's primary device_id is deviceA. Split deviceA out.
        let originalDive = try diveService.getDive(id: diveId)
        XCTAssertEqual(originalDive?.deviceId, deviceA.id)

        let result = try importService.splitDive(diveId: diveId, deviceId: deviceA.id)

        // Original dive's device_id should be reassigned to deviceB
        let updatedOriginal = try diveService.getDive(id: diveId)
        XCTAssertEqual(updatedOriginal?.deviceId, deviceB.id,
                        "Original dive should be reassigned to remaining device")

        // New dive should have deviceA
        let newDive = try diveService.getDive(id: result.newDiveId)
        XCTAssertEqual(newDive?.deviceId, deviceA.id)
    }

    // MARK: - Error Cases

    func testSplitDiveNotFound() throws {
        XCTAssertThrowsError(
            try importService.splitDive(diveId: "nonexistent", deviceId: "any")
        ) { error in
            XCTAssertEqual(error as? DiveComputerImportService.SplitError, .diveNotFound)
        }
    }

    func testSplitNotMerged() throws {
        let device = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        try diveService.saveDevice(device)

        let parsed = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 30.0, avgDepthM: 18.0, bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        try importService.saveImportedDive(parsed, deviceId: device.id)

        let dives = try diveService.listDives()
        XCTAssertThrowsError(
            try importService.splitDive(diveId: dives[0].id, deviceId: device.id)
        ) { error in
            XCTAssertEqual(error as? DiveComputerImportService.SplitError, .notMerged)
        }
    }

    func testSplitWithNilGasMixIndex() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")

        // No gas mixes, no gasmixIndex on samples (common for non-CCR dives)
        let samplesA = [
            ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0),
            ParsedSample(tSec: 60, depthM: 20.0, tempC: 19.0),
        ]
        let samplesB = [
            ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5),
            ParsedSample(tSec: 60, depthM: 19.0, tempC: 19.5),
        ]

        let diveId = try createMergedDive(
            deviceA: deviceA, deviceB: deviceB,
            samplesA: samplesA, samplesB: samplesB
        )

        let result = try importService.splitDive(diveId: diveId, deviceId: deviceB.id)

        // Should succeed without error; samples have nil gasmixIndex
        let newSamples = try diveService.getSamples(diveId: result.newDiveId)
        XCTAssertEqual(newSamples.count, 2)
        XCTAssertTrue(newSamples.allSatisfy { $0.gasmixIndex == nil })

        let newMixes = try diveService.getGasMixes(diveId: result.newDiveId)
        XCTAssertTrue(newMixes.isEmpty, "No gas mixes should be duplicated")
    }

    func testSplitNoSamplesForDevice() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        let deviceC = Device(model: "Teric", serialNumber: "C-9999", firmwareVersion: "1")
        let diveId = try createMergedDive(deviceA: deviceA, deviceB: deviceB)
        try diveService.saveDevice(deviceC)

        XCTAssertThrowsError(
            try importService.splitDive(diveId: diveId, deviceId: deviceC.id)
        ) { error in
            XCTAssertEqual(error as? DiveComputerImportService.SplitError, .noSamplesForDevice)
        }
    }
}
