import XCTest
@testable import DivelogCore

final class DiveQueryDedupTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
    }

    // MARK: - Helpers

    /// Create a device and return it.
    private func makeDevice() throws -> Device {
        let device = Device(model: "Test Computer", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)
        return device
    }

    /// Create a dive with given tags and return it.
    private func makeDive(
        deviceId: String,
        startTime: Int64 = 1_700_000_000,
        tags: [String] = [],
        teammateIds: [String] = []
    ) throws -> Dive {
        let dive = Dive(
            deviceId: deviceId,
            startTimeUnix: startTime,
            endTimeUnix: startTime + 3600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive, tags: tags, teammateIds: teammateIds, equipmentIds: [])
        return dive
    }

    // MARK: - request() path (listDives)

    func testMultipleMatchingTagsReturnsSingleRow() throws {
        let device = try makeDevice()
        let dive = try makeDive(deviceId: device.id, tags: ["cave", "night"])

        // Both tags match the filter -- dive should appear exactly once
        let query = DiveQuery(tagAny: ["cave", "night"], limit: nil)
        let results = try diveService.listDives(query: query)

        XCTAssertEqual(results.count, 1, "Dive with multiple matching tags should appear exactly once")
        XCTAssertEqual(results.first?.id, dive.id)
    }

    func testSingleMatchingTagWorks() throws {
        let device = try makeDevice()
        let dive = try makeDive(deviceId: device.id, tags: ["cave", "night"])

        // Only one tag matches
        let query = DiveQuery(tagAny: ["cave"], limit: nil)
        let results = try diveService.listDives(query: query)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, dive.id)
    }

    func testNoMatchingTagReturnsEmpty() throws {
        let device = try makeDevice()
        _ = try makeDive(deviceId: device.id, tags: ["cave", "night"])

        let query = DiveQuery(tagAny: ["wreck"], limit: nil)
        let results = try diveService.listDives(query: query)

        XCTAssertEqual(results.count, 0, "No matching tags should return empty results")
    }

    func testMultipleDivesEachWithDifferentMatchingTags() throws {
        let device = try makeDevice()
        let dive1 = try makeDive(deviceId: device.id, startTime: 1_700_000_000, tags: ["cave", "deep"])
        let dive2 = try makeDive(deviceId: device.id, startTime: 1_700_010_000, tags: ["night", "reef"])

        // Filter for tags that span both dives
        let query = DiveQuery(tagAny: ["cave", "night"], limit: nil)
        let results = try diveService.listDives(query: query)

        XCTAssertEqual(results.count, 2, "Each dive should appear exactly once")
        let ids = Set(results.map(\.id))
        XCTAssertTrue(ids.contains(dive1.id))
        XCTAssertTrue(ids.contains(dive2.id))
    }

    func testMultipleDivesWithOverlappingTagsNoDuplicates() throws {
        let device = try makeDevice()
        // Both dives have both tags that match the filter
        let dive1 = try makeDive(deviceId: device.id, startTime: 1_700_000_000, tags: ["cave", "night"])
        let dive2 = try makeDive(deviceId: device.id, startTime: 1_700_010_000, tags: ["cave", "night"])

        let query = DiveQuery(tagAny: ["cave", "night"], limit: nil)
        let results = try diveService.listDives(query: query)

        XCTAssertEqual(results.count, 2, "Two dives each matching multiple tags should appear exactly twice total")
        let ids = Set(results.map(\.id))
        XCTAssertTrue(ids.contains(dive1.id))
        XCTAssertTrue(ids.contains(dive2.id))
    }

    // MARK: - requestWithSites() path (listDivesWithSites)

    func testMultipleMatchingTagsReturnsSingleRowWithSites() throws {
        let device = try makeDevice()
        let dive = try makeDive(deviceId: device.id, tags: ["cave", "night"])

        let query = DiveQuery(tagAny: ["cave", "night"], limit: nil)
        let results = try diveService.listDivesWithSites(query: query)

        XCTAssertEqual(results.count, 1, "DiveWithSite: multiple matching tags should return single row")
        XCTAssertEqual(results.first?.dive.id, dive.id)
    }

    func testSingleMatchingTagWorksWithSites() throws {
        let device = try makeDevice()
        let dive = try makeDive(deviceId: device.id, tags: ["cave", "night"])

        let query = DiveQuery(tagAny: ["cave"], limit: nil)
        let results = try diveService.listDivesWithSites(query: query)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.dive.id, dive.id)
    }

    func testNoMatchingTagReturnsEmptyWithSites() throws {
        let device = try makeDevice()
        _ = try makeDive(deviceId: device.id, tags: ["cave", "night"])

        let query = DiveQuery(tagAny: ["wreck"], limit: nil)
        let results = try diveService.listDivesWithSites(query: query)

        XCTAssertEqual(results.count, 0)
    }

    func testMultipleDivesWithOverlappingTagsNoDuplicatesWithSites() throws {
        let device = try makeDevice()
        let dive1 = try makeDive(deviceId: device.id, startTime: 1_700_000_000, tags: ["cave", "night"])
        let dive2 = try makeDive(deviceId: device.id, startTime: 1_700_010_000, tags: ["cave", "night"])

        let query = DiveQuery(tagAny: ["cave", "night"], limit: nil)
        let results = try diveService.listDivesWithSites(query: query)

        XCTAssertEqual(results.count, 2, "DiveWithSite: two dives with overlapping tags should appear exactly twice")
        let ids = Set(results.map(\.dive.id))
        XCTAssertTrue(ids.contains(dive1.id))
        XCTAssertTrue(ids.contains(dive2.id))
    }

    // MARK: - Teammate join dedup

    func testMultipleMatchingTeammatesReturnsSingleRow() throws {
        let device = try makeDevice()
        let buddy1 = Teammate(displayName: "Alice")
        let buddy2 = Teammate(displayName: "Bob")
        try diveService.saveTeammate(buddy1)
        try diveService.saveTeammate(buddy2)

        // A dive with both buddies
        let dive = try makeDive(deviceId: device.id, teammateIds: [buddy1.id, buddy2.id])

        // Teammate filter only allows a single ID, so this validates no duplication
        let query1 = DiveQuery(teammateId: buddy1.id, limit: nil)
        let results1 = try diveService.listDives(query: query1)
        XCTAssertEqual(results1.count, 1)
        XCTAssertEqual(results1.first?.id, dive.id)

        let query2 = DiveQuery(teammateId: buddy2.id, limit: nil)
        let results2 = try diveService.listDives(query: query2)
        XCTAssertEqual(results2.count, 1)
        XCTAssertEqual(results2.first?.id, dive.id)
    }
}
