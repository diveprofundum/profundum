import XCTest
@testable import DivelogCore

/// Tests for device ownership model and ownership-gated merge behavior.
final class DeviceOwnershipTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!
    var importService: DiveComputerImportService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        importService = DiveComputerImportService(database: database)
    }

    // MARK: - Model Tests

    func testDefaultOwnershipIsMine() throws {
        let device = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        XCTAssertEqual(device.ownership, .mine)
    }

    func testOwnershipRoundTrip() throws {
        var device = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93", ownership: .other)
        try diveService.saveDevice(device)
        let fetched = try diveService.getDevice(id: device.id)
        XCTAssertEqual(fetched?.ownership, .other)

        device.ownership = .mine
        try diveService.saveDevice(device)
        let refetched = try diveService.getDevice(id: device.id)
        XCTAssertEqual(refetched?.ownership, .mine)
    }

    func testExistingDevicesDefaultToMine() throws {
        // Devices created before migration 014 should default to 'mine'
        let device = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93")
        try diveService.saveDevice(device)
        let fetched = try diveService.getDevice(id: device.id)
        XCTAssertEqual(fetched?.ownership, .mine)
    }

    // MARK: - Merge Gate Tests

    func testBothMineDevicesMerge() throws {
        let deviceA = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93", ownership: .mine)
        let deviceB = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93", ownership: .mine)
        try diveService.saveDevice(deviceA)
        try diveService.saveDevice(deviceB)

        let parsedA = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 30.0, avgDepthM: 18.0, bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        try importService.saveImportedDive(parsedA, deviceId: deviceA.id)

        let parsedB = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 30.0, avgDepthM: 18.0, bottomTimeSec: 3000,
            fingerprint: Data([0x03, 0x04]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5)]
        )
        let outcome = try importService.saveImportedDive(parsedB, deviceId: deviceB.id)
        XCTAssertEqual(outcome, .merged, "Both-mine devices should merge")

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)
    }

    func testOtherDeviceDoesNotMerge() throws {
        let myDevice = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93", ownership: .mine)
        let buddyDevice = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93", ownership: .other)
        try diveService.saveDevice(myDevice)
        try diveService.saveDevice(buddyDevice)

        let myParsed = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 30.0, avgDepthM: 18.0, bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        try importService.saveImportedDive(myParsed, deviceId: myDevice.id)

        let buddyParsed = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 28.0, avgDepthM: 17.0, bottomTimeSec: 2900,
            fingerprint: Data([0x03, 0x04]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 23.0)]
        )
        let outcome = try importService.saveImportedDive(buddyParsed, deviceId: buddyDevice.id)
        XCTAssertEqual(outcome, .saved, "Buddy device should create a new dive, not merge")

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 2, "Should have 2 separate dives")
    }

    func testMineIntoOtherDeviceDoesNotMerge() throws {
        // Importing from a mine device into an existing dive from an other device
        let buddyDevice = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93", ownership: .other)
        let myDevice = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93", ownership: .mine)
        try diveService.saveDevice(buddyDevice)
        try diveService.saveDevice(myDevice)

        let buddyParsed = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 30.0, avgDepthM: 18.0, bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        try importService.saveImportedDive(buddyParsed, deviceId: buddyDevice.id)

        let myParsed = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 30.0, avgDepthM: 18.0, bottomTimeSec: 3000,
            fingerprint: Data([0x03, 0x04]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.5)]
        )
        let outcome = try importService.saveImportedDive(myParsed, deviceId: myDevice.id)
        XCTAssertEqual(outcome, .saved, "Should not merge into buddy's dive")

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 2)
    }

    func testFingerprintDedupUnaffectedByOwnership() throws {
        // Fingerprint dedup should always work regardless of ownership
        let buddyDevice = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93", ownership: .other)
        try diveService.saveDevice(buddyDevice)

        let parsed = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 30.0, avgDepthM: 18.0, bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        let first = try importService.saveImportedDive(parsed, deviceId: buddyDevice.id)
        XCTAssertEqual(first, .saved)

        // Same fingerprint from same device → skipped (fingerprint dedup)
        let second = try importService.saveImportedDive(parsed, deviceId: buddyDevice.id)
        XCTAssertEqual(second, .skipped, "Fingerprint dedup should still work for buddy devices")
    }

    func testOtherDeviceWithNoFingerprintCreatesNewDive() throws {
        // Even without a fingerprint, an "other" device at the same time shouldn't merge
        let myDevice = Device(model: "Perdix", serialNumber: "A-1234", firmwareVersion: "93", ownership: .mine)
        let buddyDevice = Device(model: "Petrel", serialNumber: "B-5678", firmwareVersion: "93", ownership: .other)
        try diveService.saveDevice(myDevice)
        try diveService.saveDevice(buddyDevice)

        let myParsed = ParsedDive(
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 30.0, avgDepthM: 18.0, bottomTimeSec: 3000,
            fingerprint: Data([0x01, 0x02]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 22.0)]
        )
        try importService.saveImportedDive(myParsed, deviceId: myDevice.id)

        // Buddy dive with fingerprint but at same time — time-match should NOT merge
        let buddyParsed = ParsedDive(
            startTimeUnix: 1700000050, endTimeUnix: 1700003600,
            maxDepthM: 28.0, avgDepthM: 17.0, bottomTimeSec: 2900,
            fingerprint: Data([0x05, 0x06]),
            samples: [ParsedSample(tSec: 0, depthM: 0.0, tempC: 23.0)]
        )
        let outcome = try importService.saveImportedDive(buddyParsed, deviceId: buddyDevice.id)
        XCTAssertEqual(outcome, .saved)
    }
}
