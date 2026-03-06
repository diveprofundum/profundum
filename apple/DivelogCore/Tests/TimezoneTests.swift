import XCTest
@testable import DivelogCore

/// Tests for timezone offset storage and display date computation.
final class TimezoneTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!
    var importService: DiveComputerImportService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        importService = DiveComputerImportService(database: database)
    }

    // MARK: - Display Date Tests

    func testDisplayStartDateWithOffset() {
        // Real UTC: 2024-01-15 18:00:00 UTC, PST offset = -28800 (-8h)
        // displayStartDate should add offset → 10:00:00 UTC representation
        // (so UTC formatters display "10:00 AM" which is correct PST)
        let utcEpoch: Int64 = 1_705_338_000 // 2024-01-15 18:00:00 UTC
        let pstOffset: Int32 = -28800       // -8 hours

        let dive = Dive(
            deviceId: "dev1",
            startTimeUnix: utcEpoch,
            endTimeUnix: utcEpoch + 3600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000,
            timezoneOffsetSec: pstOffset
        )

        let expected = Date(timeIntervalSince1970: TimeInterval(utcEpoch) + TimeInterval(pstOffset))
        XCTAssertEqual(dive.displayStartDate, expected)
    }

    func testDisplayStartDateWithoutOffset() {
        // Legacy local-as-UTC: no offset → displayStartDate returns raw date
        let localAsUtc: Int64 = 1_705_338_000

        let dive = Dive(
            deviceId: "dev1",
            startTimeUnix: localAsUtc,
            endTimeUnix: localAsUtc + 3600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000,
            timezoneOffsetSec: nil
        )

        let expected = Date(timeIntervalSince1970: TimeInterval(localAsUtc))
        XCTAssertEqual(dive.displayStartDate, expected)
    }

    func testDisplayEndDateWithOffset() {
        let utcEpoch: Int64 = 1_705_338_000
        let endUtc: Int64 = utcEpoch + 3600
        let offset: Int32 = -28800

        let dive = Dive(
            deviceId: "dev1",
            startTimeUnix: utcEpoch,
            endTimeUnix: endUtc,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000,
            timezoneOffsetSec: offset
        )

        let expected = Date(timeIntervalSince1970: TimeInterval(endUtc) + TimeInterval(offset))
        XCTAssertEqual(dive.displayEndDate, expected)
    }

    func testDisplayEndDateWithoutOffset() {
        let localAsUtc: Int64 = 1_705_338_000
        let endLocalAsUtc: Int64 = localAsUtc + 3600

        let dive = Dive(
            deviceId: "dev1",
            startTimeUnix: localAsUtc,
            endTimeUnix: endLocalAsUtc,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000
        )

        let expected = Date(timeIntervalSince1970: TimeInterval(endLocalAsUtc))
        XCTAssertEqual(dive.displayEndDate, expected)
    }

    // MARK: - Migration Tests

    func testMigration015AddsTimezoneColumn() throws {
        // In-memory DB runs all migrations including 015.
        // Insert a dive without timezone — it should default to nil.
        let device = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1_000_000,
            endTimeUnix: 1_003_600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000
        )
        try diveService.saveDive(dive, tags: ["oc"])

        let fetched = try diveService.getDive(id: dive.id)
        XCTAssertNotNil(fetched)
        XCTAssertNil(fetched?.timezoneOffsetSec)
    }

    // MARK: - Import Flow Tests

    func testBLEImportStoresTimezoneWhenKnown() throws {
        let device = Device(model: "Symbios", serialNumber: "H-9999", firmwareVersion: "1.9")
        try diveService.saveDevice(device)

        let parsed = ParsedDive(
            startTimeUnix: 1_705_338_000,
            endTimeUnix: 1_705_341_600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000,
            fingerprint: Data([0xAA, 0xBB]),
            timezoneOffsetSec: -28800
        )

        try importService.saveImportedDive(parsed, deviceId: device.id)

        let fetched = try diveService.getDive(id: findDiveId(deviceId: device.id))
        XCTAssertEqual(fetched?.timezoneOffsetSec, -28800)
    }

    func testBLEImportNilTimezoneForUnknown() throws {
        let device = Device(model: "Perdix", serialNumber: "S-1234", firmwareVersion: "93")
        try diveService.saveDevice(device)

        let parsed = ParsedDive(
            startTimeUnix: 1_705_338_000,
            endTimeUnix: 1_705_341_600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000,
            fingerprint: Data([0xCC, 0xDD]),
            timezoneOffsetSec: nil
        )

        try importService.saveImportedDive(parsed, deviceId: device.id)

        let fetched = try diveService.getDive(id: findDiveId(deviceId: device.id))
        XCTAssertNil(fetched?.timezoneOffsetSec)
    }

    func testDiveDataMapperPassesThroughTimezoneOffset() {
        let parsed = ParsedDive(
            startTimeUnix: 1_705_338_000,
            endTimeUnix: 1_705_341_600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000,
            timezoneOffsetSec: 3600
        )

        let (dive, _, _) = DiveDataMapper.toDive(parsed, deviceId: "dev1")
        XCTAssertEqual(dive.timezoneOffsetSec, 3600)
    }

    func testDiveDataMapperNilTimezonePassesThrough() {
        let parsed = ParsedDive(
            startTimeUnix: 1_705_338_000,
            endTimeUnix: 1_705_341_600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000,
            timezoneOffsetSec: nil
        )

        let (dive, _, _) = DiveDataMapper.toDive(parsed, deviceId: "dev1")
        XCTAssertNil(dive.timezoneOffsetSec)
    }

    func testSplitDivePreservesTimezoneOffset() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93")
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        // Import first dive with timezone offset
        let parsed1 = ParsedDive(
            startTimeUnix: 1_705_338_000,
            endTimeUnix: 1_705_341_600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000,
            fingerprint: Data([0x01]),
            samples: [
                ParsedSample(tSec: 0, depthM: 0, tempC: 20),
                ParsedSample(tSec: 60, depthM: 10, tempC: 19),
                ParsedSample(tSec: 120, depthM: 20, tempC: 18),
            ],
            timezoneOffsetSec: -28800
        )
        try importService.saveImportedDive(parsed1, deviceId: deviceA.id)

        let diveId = try findDiveId(deviceId: deviceA.id)

        // Merge second device's samples
        let parsed2 = ParsedDive(
            startTimeUnix: 1_705_338_010,
            endTimeUnix: 1_705_341_610,
            maxDepthM: 31, avgDepthM: 21, bottomTimeSec: 3000,
            fingerprint: Data([0x02]),
            samples: [
                ParsedSample(tSec: 0, depthM: 0, tempC: 20),
                ParsedSample(tSec: 60, depthM: 11, tempC: 19),
                ParsedSample(tSec: 120, depthM: 21, tempC: 18),
            ],
            timezoneOffsetSec: -28800
        )
        try importService.saveImportedDive(parsed2, deviceId: deviceB.id)

        // Split device B out
        let result = try importService.splitDive(diveId: diveId, deviceId: deviceB.id)

        let originalDive = try diveService.getDive(id: result.originalDiveId)
        let newDive = try diveService.getDive(id: result.newDiveId)

        XCTAssertEqual(originalDive?.timezoneOffsetSec, -28800)
        XCTAssertEqual(newDive?.timezoneOffsetSec, -28800)
    }

    // MARK: - Cross-Convention Merge Tests

    func testCrossConventionOverlapMerge() throws {
        // Scenario: Shearwater Cloud import (legacy local-as-UTC) then
        // Halcyon BLE import (real UTC) of the same dive.
        // PST user: local 10:00 AM = UTC 18:00.
        let shearwaterDevice = Device(model: "Perdix", serialNumber: "SW-1234", firmwareVersion: "93")
        let halcyonDevice = Device(model: "Symbios", serialNumber: "HL-5678", firmwareVersion: "1.9")
        try diveService.saveDevice(shearwaterDevice)
        try diveService.saveDevice(halcyonDevice)

        // Shearwater Cloud: local-as-UTC → stores 10:00 AM as epoch for "10:00 UTC"
        let localAsUtcStart: Int64 = 1_705_312_800 // 2024-01-15 10:00:00 UTC
        let shearwaterParsed = ParsedDive(
            startTimeUnix: localAsUtcStart,
            endTimeUnix: localAsUtcStart + 3600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000,
            fingerprint: Data([0xAA]),
            samples: [ParsedSample(tSec: 0, depthM: 0, tempC: 20)],
            timezoneOffsetSec: nil  // legacy
        )
        try importService.saveImportedDive(shearwaterParsed, deviceId: shearwaterDevice.id)

        // Halcyon BLE: real UTC → stores 18:00 UTC with offset -28800
        let realUtcStart: Int64 = 1_705_341_600 // 2024-01-15 18:00:00 UTC
        let halcyonParsed = ParsedDive(
            startTimeUnix: realUtcStart,
            endTimeUnix: realUtcStart + 3600,
            maxDepthM: 31, avgDepthM: 21, bottomTimeSec: 3000,
            fingerprint: Data([0xBB]),
            samples: [ParsedSample(tSec: 0, depthM: 0, tempC: 20)],
            timezoneOffsetSec: -28800  // PST
        )
        let outcome = try importService.saveImportedDive(halcyonParsed, deviceId: halcyonDevice.id)

        // Both represent 10:00 AM PST — should merge
        XCTAssertEqual(outcome, .merged, "Cross-convention dives at the same local time should merge")
        XCTAssertEqual(try diveService.listDives().count, 1)
    }

    func testCrossConventionNonOverlapStaysSeparate() throws {
        // Two dives that don't overlap even after normalization should remain separate.
        let deviceA = Device(model: "Perdix", serialNumber: "SW-1234", firmwareVersion: "93")
        let deviceB = Device(model: "Symbios", serialNumber: "HL-5678", firmwareVersion: "1.9")
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        // Legacy dive at local 10:00
        let legacyParsed = ParsedDive(
            startTimeUnix: 1_705_312_800,
            endTimeUnix: 1_705_312_800 + 3600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000,
            fingerprint: Data([0x01]),
            samples: [ParsedSample(tSec: 0, depthM: 0, tempC: 20)],
            timezoneOffsetSec: nil
        )
        try importService.saveImportedDive(legacyParsed, deviceId: deviceA.id)

        // Real UTC dive at a completely different time (next day)
        let realUtcParsed = ParsedDive(
            startTimeUnix: 1_705_428_000, // next day 18:00 UTC = 10:00 PST+1day
            endTimeUnix: 1_705_428_000 + 3600,
            maxDepthM: 25, avgDepthM: 15, bottomTimeSec: 2400,
            fingerprint: Data([0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0, tempC: 19)],
            timezoneOffsetSec: -28800
        )
        let outcome = try importService.saveImportedDive(realUtcParsed, deviceId: deviceB.id)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(try diveService.listDives().count, 2)
    }

    // MARK: - Helpers

    private func findDiveId(deviceId: String) throws -> String {
        let dives = try diveService.listDives()
        return dives.first(where: { $0.deviceId == deviceId })!.id
    }
}
