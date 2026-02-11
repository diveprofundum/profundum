import XCTest
@testable import DivelogCore

final class DiveTypeTagTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
    }

    // MARK: - PredefinedDiveTag Model Tests

    func testDiveTypeTagHelper() {
        XCTAssertEqual(PredefinedDiveTag.diveTypeTag(isCcr: true), .ccr)
        XCTAssertEqual(PredefinedDiveTag.diveTypeTag(isCcr: false), .oc)
    }

    func testAutoActivityTags() {
        XCTAssertEqual(PredefinedDiveTag.autoActivityTags(decoRequired: true), [.deco])
        XCTAssertEqual(PredefinedDiveTag.autoActivityTags(decoRequired: false), [.rec])
    }

    func testCategoryPartition() {
        let diveTypeCases = PredefinedDiveTag.diveTypeCases
        let activityCases = PredefinedDiveTag.activityCases

        // Dive type tags: OC and CCR
        XCTAssertEqual(diveTypeCases.count, 2)
        XCTAssertTrue(diveTypeCases.contains(.oc))
        XCTAssertTrue(diveTypeCases.contains(.ccr))

        // Activity tags include rec, deco, cave, etc.
        XCTAssertEqual(activityCases.count, 10)
        XCTAssertTrue(activityCases.contains(.rec))
        XCTAssertTrue(activityCases.contains(.deco))
        XCTAssertTrue(activityCases.contains(.cave))
        XCTAssertTrue(activityCases.contains(.wreck))

        // No overlap
        let diveTypeSet = Set(diveTypeCases)
        let activitySet = Set(activityCases)
        XCTAssertTrue(diveTypeSet.isDisjoint(with: activitySet))

        // Complete: all cases covered
        XCTAssertEqual(diveTypeCases.count + activityCases.count, PredefinedDiveTag.allCases.count)
    }

    func testDiveTypeTagCategory() {
        XCTAssertEqual(PredefinedDiveTag.oc.category, .diveType)
        XCTAssertEqual(PredefinedDiveTag.ccr.category, .diveType)
        XCTAssertEqual(PredefinedDiveTag.rec.category, .activity)
        XCTAssertEqual(PredefinedDiveTag.deco.category, .activity)
        XCTAssertEqual(PredefinedDiveTag.cave.category, .activity)
        XCTAssertEqual(PredefinedDiveTag.training.category, .activity)
    }

    func testDiveTypeTagRawValues() {
        XCTAssertEqual(PredefinedDiveTag.oc.rawValue, "oc")
        XCTAssertEqual(PredefinedDiveTag.ccr.rawValue, "ccr")
        XCTAssertEqual(PredefinedDiveTag.rec.rawValue, "rec")
        XCTAssertEqual(PredefinedDiveTag.deco.rawValue, "deco")
    }

    func testFromTagInitializer() {
        XCTAssertEqual(PredefinedDiveTag(fromTag: "oc"), .oc)
        XCTAssertEqual(PredefinedDiveTag(fromTag: "ccr"), .ccr)
        XCTAssertEqual(PredefinedDiveTag(fromTag: "rec"), .rec)
        XCTAssertEqual(PredefinedDiveTag(fromTag: "deco"), .deco)
        XCTAssertEqual(PredefinedDiveTag(fromTag: "cave"), .cave)
        XCTAssertNil(PredefinedDiveTag(fromTag: "cenote"))
        // Legacy tags should NOT match
        XCTAssertNil(PredefinedDiveTag(fromTag: "oc_rec"))
        XCTAssertNil(PredefinedDiveTag(fromTag: "oc_deco"))
    }

    // MARK: - Type Tag Storage Tests

    func testSaveDiveWithOcTags() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 18.0,
            avgDepthM: 12.0,
            bottomTimeSec: 3000,
            isCcr: false,
            decoRequired: false
        )
        try diveService.saveDive(dive, tags: ["oc", "rec"])

        let tags = try diveService.getTags(diveId: dive.id)
        XCTAssertTrue(tags.contains("oc"))
        XCTAssertTrue(tags.contains("rec"))
    }

    func testSaveDiveWithCcrTag() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 20.0,
            bottomTimeSec: 3000,
            isCcr: true,
            decoRequired: false
        )
        try diveService.saveDive(dive, tags: ["ccr", "rec"])

        let tags = try diveService.getTags(diveId: dive.id)
        XCTAssertTrue(tags.contains("ccr"))
        XCTAssertTrue(tags.contains("rec"))
    }

    func testSaveDiveWithDecoTag() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 40.0,
            avgDepthM: 25.0,
            bottomTimeSec: 3000,
            isCcr: false,
            decoRequired: true
        )
        try diveService.saveDive(dive, tags: ["oc", "deco", "deep"])

        let tags = try diveService.getTags(diveId: dive.id)
        XCTAssertTrue(tags.contains("oc"))
        XCTAssertTrue(tags.contains("deco"))
        XCTAssertTrue(tags.contains("deep"))
    }

    func testActivityTagIsRemovable() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 18.0,
            avgDepthM: 12.0,
            bottomTimeSec: 3000,
            isCcr: false,
            decoRequired: false
        )
        // Save with rec tag
        try diveService.saveDive(dive, tags: ["oc", "rec", "cave"])

        // Now save again without rec (user removed it)
        try diveService.saveDive(dive, tags: ["oc", "cave"])

        let tags = try diveService.getTags(diveId: dive.id)
        XCTAssertFalse(tags.contains("rec"), "Activity tag should be removable")
        XCTAssertTrue(tags.contains("oc"), "Dive type tag should persist")
        XCTAssertTrue(tags.contains("cave"), "Other tags should persist")
    }

    func testMigration009BackfillsExistingDives() throws {
        // Migration 009 backfills type tags for dives that exist before it runs.
        // In-memory DB runs all migrations on init (empty data), so we test the
        // SQL backfill by inserting dives via raw SQL and re-running the backfill.
        try database.dbQueue.write { db in
            // Insert a device first
            try db.execute(sql: """
                INSERT OR IGNORE INTO devices (id, model, serial_number, firmware_version, is_active)
                VALUES ('dev1', 'Test', 'SN1', '1.0', 1)
            """)

            // Insert dives directly without type tags
            try db.execute(sql: """
                INSERT INTO dives (id, device_id, start_time_unix, end_time_unix, max_depth_m,
                    avg_depth_m, bottom_time_sec, is_ccr, deco_required, cns_percent, otu)
                VALUES ('d1', 'dev1', 1700000000, 1700003600, 18, 12, 3000, 0, 0, 0, 0)
            """)
            try db.execute(sql: """
                INSERT INTO dives (id, device_id, start_time_unix, end_time_unix, max_depth_m,
                    avg_depth_m, bottom_time_sec, is_ccr, deco_required, cns_percent, otu)
                VALUES ('d2', 'dev1', 1700100000, 1700103600, 30, 20, 3000, 1, 0, 0, 0)
            """)
            try db.execute(sql: """
                INSERT INTO dives (id, device_id, start_time_unix, end_time_unix, max_depth_m,
                    avg_depth_m, bottom_time_sec, is_ccr, deco_required, cns_percent, otu)
                VALUES ('d3', 'dev1', 1700200000, 1700203600, 40, 25, 3000, 0, 1, 0, 0)
            """)

            // Re-run the backfill SQL (same as migration 009)
            try db.execute(sql: """
                INSERT OR IGNORE INTO dive_tags (dive_id, tag)
                SELECT id, 'ccr' FROM dives WHERE is_ccr = 1;

                INSERT OR IGNORE INTO dive_tags (dive_id, tag)
                SELECT id, 'oc' FROM dives WHERE is_ccr = 0;

                INSERT OR IGNORE INTO dive_tags (dive_id, tag)
                SELECT id, 'deco' FROM dives WHERE deco_required = 1;

                INSERT OR IGNORE INTO dive_tags (dive_id, tag)
                SELECT id, 'rec' FROM dives WHERE deco_required = 0;
            """)
        }

        // Verify backfilled tags
        let d1Tags = try diveService.getTags(diveId: "d1")
        XCTAssertTrue(d1Tags.contains("oc"), "OC dive should get oc tag")
        XCTAssertTrue(d1Tags.contains("rec"), "Non-deco dive should get rec tag")

        let d2Tags = try diveService.getTags(diveId: "d2")
        XCTAssertTrue(d2Tags.contains("ccr"), "CCR dive should get ccr tag")
        XCTAssertTrue(d2Tags.contains("rec"), "Non-deco CCR dive should get rec tag")

        let d3Tags = try diveService.getTags(diveId: "d3")
        XCTAssertTrue(d3Tags.contains("oc"), "OC dive should get oc tag")
        XCTAssertTrue(d3Tags.contains("deco"), "Deco dive should get deco tag")
    }

    // MARK: - allCustomTags Tests

    func testAllCustomTagsExcludesPredefined() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 18.0,
            avgDepthM: 12.0,
            bottomTimeSec: 3000,
            isCcr: false,
            decoRequired: false
        )
        try diveService.saveDive(dive, tags: ["oc", "rec", "cave", "cenote", "blue_hole"])

        let customTags = try diveService.allCustomTags()
        XCTAssertFalse(customTags.contains("oc"), "Should exclude predefined dive type tags")
        XCTAssertFalse(customTags.contains("rec"), "Should exclude predefined activity tags")
        XCTAssertFalse(customTags.contains("cave"), "Should exclude predefined activity tags")
        XCTAssertTrue(customTags.contains("cenote"), "Should include custom tag")
        XCTAssertTrue(customTags.contains("blue_hole"), "Should include custom tag")
    }

    func testAllCustomTagsReturnsDistinct() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive1 = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 18.0,
            avgDepthM: 12.0,
            bottomTimeSec: 3000,
            isCcr: false
        )
        let dive2 = Dive(
            deviceId: device.id,
            startTimeUnix: 1700100000,
            endTimeUnix: 1700103600,
            maxDepthM: 20.0,
            avgDepthM: 15.0,
            bottomTimeSec: 2400,
            isCcr: false
        )
        try diveService.saveDive(dive1, tags: ["cenote", "oc"])
        try diveService.saveDive(dive2, tags: ["cenote", "oc"])

        let customTags = try diveService.allCustomTags()
        let cenoteCount = customTags.filter { $0 == "cenote" }.count
        XCTAssertEqual(cenoteCount, 1, "Custom tags should be distinct")
    }

    func testAllCustomTagsEmptyWhenNoneExist() throws {
        let customTags = try diveService.allCustomTags()
        XCTAssertTrue(customTags.isEmpty)
    }

    func testAllCustomTagsSorted() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 18.0,
            avgDepthM: 12.0,
            bottomTimeSec: 3000,
            isCcr: false
        )
        try diveService.saveDive(dive, tags: ["oc", "zebra", "alpha", "manta"])

        let customTags = try diveService.allCustomTags()
        XCTAssertEqual(customTags, ["alpha", "manta", "zebra"])
    }
}
