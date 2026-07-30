import GRDB
import XCTest
@testable import DivelogCore

final class GasMixMergeHelperTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
    }

    func testFilterUsedGasMixesKeepsOnlyReferencedIndices() {
        let mixes = [
            ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0),
            ParsedGasMix(index: 1, o2Fraction: 0.50, heFraction: 0.0),
            ParsedGasMix(index: 2, o2Fraction: 0.21, heFraction: 0.35),
        ]
        let samples = [
            ParsedSample(tSec: 0, depthM: 0, tempC: 22, gasmixIndex: 0),
            ParsedSample(tSec: 60, depthM: 15, tempC: 20, gasmixIndex: 2),
        ]

        let filtered = GasMixMergeHelper.filterUsedGasMixes(mixes, samples: samples)
        XCTAssertEqual(filtered.map(\.index), [0, 2])
    }

    func testFilterUsedGasMixesReturnsAllWhenNoSampleIndices() {
        let mixes = [
            ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0),
            ParsedGasMix(index: 1, o2Fraction: 0.32, heFraction: 0.0),
        ]
        let samples = [
            ParsedSample(tSec: 0, depthM: 0, tempC: 22),
            ParsedSample(tSec: 60, depthM: 15, tempC: 20),
        ]

        let filtered = GasMixMergeHelper.filterUsedGasMixes(mixes, samples: samples)
        XCTAssertEqual(filtered.count, 2)
    }

    func testMergeGasMixesRemapsIndicesAcrossDevices() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        let dive = Dive(
            deviceId: deviceA.id,
            startTimeUnix: 1_700_000_000,
            endTimeUnix: 1_700_003_600,
            maxDepthM: 30,
            avgDepthM: 18,
            bottomTimeSec: 3_000
        )
        try diveService.saveDive(dive)

        try database.dbQueue.write { db in
            let mixesA = [
                ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0),
                ParsedGasMix(index: 1, o2Fraction: 0.32, heFraction: 0.0),
            ]
            let samplesA = [
                ParsedSample(tSec: 0, depthM: 0, tempC: 22, gasmixIndex: 0),
                ParsedSample(tSec: 60, depthM: 15, tempC: 20, gasmixIndex: 1),
            ]
            let usedA = GasMixMergeHelper.filterUsedGasMixes(mixesA, samples: samplesA)
            let remapA = try GasMixMergeHelper.mergeGasMixes(
                existingMixes: [],
                incomingMixes: usedA,
                diveId: dive.id,
                deviceId: deviceA.id,
                db: db
            )
            try GasMixMergeHelper.insertSamples(
                samples: samplesA,
                diveId: dive.id,
                deviceId: deviceA.id,
                indexRemap: remapA,
                db: db
            )

            let existingMixes = try GasMix.filter(Column("dive_id") == dive.id).fetchAll(db)
            let mixesB = [
                ParsedGasMix(index: 0, o2Fraction: 0.32, heFraction: 0.0),
                ParsedGasMix(index: 1, o2Fraction: 0.21, heFraction: 0.0),
            ]
            let samplesB = [
                ParsedSample(tSec: 0, depthM: 0, tempC: 22.5, gasmixIndex: 0),
                ParsedSample(tSec: 60, depthM: 15, tempC: 20.5, gasmixIndex: 1),
            ]
            let usedB = GasMixMergeHelper.filterUsedGasMixes(mixesB, samples: samplesB)
            let remapB = try GasMixMergeHelper.mergeGasMixes(
                existingMixes: existingMixes,
                incomingMixes: usedB,
                diveId: dive.id,
                deviceId: deviceB.id,
                db: db
            )
            try GasMixMergeHelper.insertSamples(
                samples: samplesB,
                diveId: dive.id,
                deviceId: deviceB.id,
                indexRemap: remapB,
                db: db
            )
        }

        let mixes = try diveService.getGasMixes(diveId: dive.id)
        XCTAssertEqual(mixes.count, 2, "Air and nx32 should dedupe to two mixes")

        let samples = try diveService.getSamples(diveId: dive.id)
        let samplesB = samples.filter { $0.deviceId == deviceB.id }
        XCTAssertEqual(samplesB[0].gasmixIndex, 1, "B's index 0 (nx32) should remap to persisted index 1")
        XCTAssertEqual(samplesB[1].gasmixIndex, 0, "B's index 1 (air) should remap to persisted index 0")

        let deviceIds = Set(mixes.compactMap(\.deviceId))
        XCTAssertFalse(deviceIds.isEmpty)
    }

    func testMergeGasMixesSkipsUnusedProgrammedSlots() throws {
        let device = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1_700_000_000,
            endTimeUnix: 1_700_003_600,
            maxDepthM: 30,
            avgDepthM: 18,
            bottomTimeSec: 3_000
        )
        try diveService.saveDive(dive)

        try database.dbQueue.write { db in
            let mixes = [
                ParsedGasMix(index: 0, o2Fraction: 0.21, heFraction: 0.0, usage: "diluent"),
                ParsedGasMix(index: 1, o2Fraction: 1.0, heFraction: 0.0, usage: "oxygen"),
                ParsedGasMix(index: 2, o2Fraction: 0.50, heFraction: 0.0),
            ]
            let samples = [
                ParsedSample(tSec: 0, depthM: 0, tempC: 22, gasmixIndex: 0),
            ]
            let used = GasMixMergeHelper.filterUsedGasMixes(mixes, samples: samples)
            _ = try GasMixMergeHelper.mergeGasMixes(
                existingMixes: [],
                incomingMixes: used,
                diveId: dive.id,
                deviceId: device.id,
                db: db
            )
        }

        let persisted = try diveService.getGasMixes(diveId: dive.id)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].usage, "diluent")
    }
}
