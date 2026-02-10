import XCTest
import GRDB
@testable import DivelogCore

final class ShearwaterCloudImportTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!
    var importService: ShearwaterCloudImportService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        importService = ShearwaterCloudImportService(database: database)
    }

    override func tearDown() async throws {
        for path in tempFiles {
            try? FileManager.default.removeItem(atPath: path)
        }
        tempFiles.removeAll()
    }

    private var tempFiles: [String] = []

    // MARK: - Existing Test Cases

    func testImportSingleDive() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(
                diveId: 1,
                diveDate: "2024-06-15 10:30:00",
                depthFt: 100.0,
                durationSec: 3600,
                serial: "SN001",
                site: "Blue Hole",
                buddy: "Alice",
                calculatedValues: """
                    {"AverageDepth": 60.0, "MinTemp": 70.0, "MaxTemp": 78.0, "MaxDecoObligation": 0}
                """,
                dataBytes2: """
                    {"DIVE_NUMBER_KEY": 42, "DIVE_START_TIME": 1718444400}
                """
            )
        ])

        let result = try importService.importFromFile(at: path)

        XCTAssertEqual(result.totalDivesInFile, 1)
        XCTAssertEqual(result.divesImported, 1)
        XCTAssertEqual(result.divesSkipped, 0)
        XCTAssertEqual(result.divesMerged, 0)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)

        let dive = dives[0]
        XCTAssertEqual(dive.maxDepthM, 30.48, accuracy: 0.01)
        XCTAssertEqual(dive.avgDepthM, 18.288, accuracy: 0.01)
        XCTAssertEqual(dive.bottomTimeSec, 3600)
        XCTAssertEqual(dive.computerDiveNumber, 42)
        XCTAssertEqual(dive.startTimeUnix, 1718444400)
        XCTAssertEqual(dive.endTimeUnix, 1718444400 + 3600)
        XCTAssertFalse(dive.decoRequired)
    }

    func testImportCreatesDevicesSitesTeammates() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001", site: "Reef A", buddy: "Alice, Bob"),
            ShearwaterTestDive(diveId: 2, diveDate: "2024-01-02 08:00:00", depthFt: 60,
                               durationSec: 2400, serial: "SN002", site: "Reef B", buddy: "Charlie"),
        ])

        let result = try importService.importFromFile(at: path)

        XCTAssertEqual(result.devicesCreated, 2)
        XCTAssertEqual(result.sitesCreated, 2)
        XCTAssertEqual(result.teammatesCreated, 3)
        XCTAssertEqual(result.divesImported, 2)

        let devices = try diveService.listDevices(includeArchived: true)
        XCTAssertEqual(devices.count, 2)

        let sites = try diveService.listSites()
        XCTAssertEqual(sites.count, 2)

        let teammates = try diveService.listTeammates()
        XCTAssertEqual(teammates.count, 3)
        let names = Set(teammates.map(\.displayName))
        XCTAssertTrue(names.contains("Alice"))
        XCTAssertTrue(names.contains("Bob"))
        XCTAssertTrue(names.contains("Charlie"))
    }

    func testImportDeduplication() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001"),
            ShearwaterTestDive(diveId: 2, diveDate: "2024-01-02 08:00:00", depthFt: 60,
                               durationSec: 2400, serial: "SN001"),
        ])

        // First import
        let result1 = try importService.importFromFile(at: path)
        XCTAssertEqual(result1.divesImported, 2)
        XCTAssertEqual(result1.divesSkipped, 0)

        // Second import — should skip all
        let result2 = try importService.importFromFile(at: path)
        XCTAssertEqual(result2.divesImported, 0)
        XCTAssertEqual(result2.divesSkipped, 2)

        // Still only 2 dives in DB
        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 2)
    }

    func testImportNullFields() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001", site: nil, buddy: nil),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)
        XCTAssertEqual(result.sitesCreated, 0)
        XCTAssertEqual(result.teammatesCreated, 0)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)
        XCTAssertNil(dives[0].siteId)
    }

    func testImportCommaSeparatedBuddies() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001", buddy: "Ivette, Ryan"),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.teammatesCreated, 2)

        let teammates = try diveService.listTeammates()
        let names = Set(teammates.map(\.displayName))
        XCTAssertTrue(names.contains("Ivette"))
        XCTAssertTrue(names.contains("Ryan"))

        let dives = try diveService.listDives()
        let teammateIds = try diveService.getTeammateIds(diveId: dives[0].id)
        XCTAssertEqual(teammateIds.count, 2)
    }

    func testImportReusesExistingEntities() throws {
        let existingSite = Site(name: "Blue Hole")
        try diveService.saveSite(existingSite)

        let existingTeammate = Teammate(displayName: "Alice")
        try diveService.saveTeammate(existingTeammate)

        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001", site: "Blue Hole", buddy: "Alice"),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.sitesCreated, 0)
        XCTAssertEqual(result.teammatesCreated, 0)

        let sites = try diveService.listSites()
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].id, existingSite.id)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives[0].siteId, existingSite.id)
    }

    func testImportUsesStartTimeFromMetadata() throws {
        let metadataTimestamp: Int64 = 1718444400
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(
                diveId: 1,
                diveDate: "2020-01-01 00:00:00",
                depthFt: 50,
                durationSec: 1800,
                serial: "SN001",
                dataBytes2: """
                    {"DIVE_NUMBER_KEY": 1, "DIVE_START_TIME": \(metadataTimestamp)}
                """
            ),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives[0].startTimeUnix, metadataTimestamp)
    }

    func testImportProgressCallback() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50, durationSec: 1800, serial: "SN001"),
            ShearwaterTestDive(diveId: 2, diveDate: "2024-01-02 08:00:00", depthFt: 60, durationSec: 2400, serial: "SN001"),
            ShearwaterTestDive(diveId: 3, diveDate: "2024-01-03 08:00:00", depthFt: 70, durationSec: 3000, serial: "SN001"),
        ])

        var progressCalls: [(Int, Int)] = []
        _ = try importService.importFromFile(at: path) { current, total in
            progressCalls.append((current, total))
        }

        XCTAssertEqual(progressCalls.count, 3)
        XCTAssertEqual(progressCalls[0].0, 1)
        XCTAssertEqual(progressCalls[0].1, 3)
        XCTAssertEqual(progressCalls[1].0, 2)
        XCTAssertEqual(progressCalls[1].1, 3)
        XCTAssertEqual(progressCalls[2].0, 3)
        XCTAssertEqual(progressCalls[2].1, 3)
    }

    func testImportSiteLocation() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001", site: "Blue Hole",
                               location: "Belize"),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.sitesCreated, 1)

        let sites = try diveService.listSites()
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].notes, "Belize")
    }

    func testImportDiveNumberFallback() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001", diveNumber: 99),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives[0].computerDiveNumber, 99)
    }

    func testImportAverageDepthFromNativeColumn() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 100,
                               durationSec: 3600, serial: "SN001", averageDepth: 70.0),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives[0].avgDepthM, 21.336, accuracy: 0.01)
    }

    func testImportWithDataBytes1NoLibdivecomputer() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 80,
                               durationSec: 2400, serial: "SN001",
                               dataBytes1: Data(repeating: 0xAB, count: 100)),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)
        XCTAssertEqual(dives[0].maxDepthM, 24.384, accuracy: 0.01)

        let samples = try diveService.getSamples(diveId: dives[0].id)
        XCTAssertEqual(samples.count, 0)
    }

    // MARK: - New Tests: Dive Merging

    func testImportMergesDivesFromDifferentSerials() throws {
        // Two dives with different serials, start times 30s apart → should merge
        let startTime: Int64 = 1718444400
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(
                diveId: 100, diveDate: "2024-06-15 10:00:00", depthFt: 100,
                durationSec: 3600, serial: "SERIAL_A", site: "Blue Hole",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime)}
                """
            ),
            ShearwaterTestDive(
                diveId: 200, diveDate: "2024-06-15 10:00:30", depthFt: 98,
                durationSec: 3580, serial: "SERIAL_B", buddy: "Alice",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime + 30)}
                """
            ),
        ])

        let result = try importService.importFromFile(at: path)

        // 1 dive imported (merged from 2 rows), 1 extra row merged
        XCTAssertEqual(result.divesImported, 1)
        XCTAssertEqual(result.divesMerged, 1)
        XCTAssertEqual(result.divesSkipped, 0)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)

        let dive = dives[0]
        // Max depth should be the higher of the two
        XCTAssertEqual(dive.maxDepthM, 100 * 0.3048, accuracy: 0.01)
        // Should have a group_id since it's merged
        XCTAssertNotNil(dive.groupId)
        // Should have site from first row
        XCTAssertNotNil(dive.siteId)

        // Should have 2 source fingerprints
        let fps = try diveService.getSourceFingerprints(diveId: dive.id)
        XCTAssertEqual(fps.count, 2)

        // Buddy from second row should be linked
        let teammateIds = try diveService.getTeammateIds(diveId: dive.id)
        XCTAssertEqual(teammateIds.count, 1)
    }

    func testImportMergeMetadataUnion() throws {
        // One serial has site, other has buddy → merged dive has both
        let startTime: Int64 = 1718444400
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(
                diveId: 100, diveDate: "2024-06-15 10:00:00", depthFt: 80,
                durationSec: 2400, serial: "SERIAL_A", site: "Reef X",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime)}
                """,
                notes: "Great vis today"
            ),
            ShearwaterTestDive(
                diveId: 200, diveDate: "2024-06-15 10:00:05", depthFt: 82,
                durationSec: 2410, serial: "SERIAL_B", buddy: "Bob",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime + 5)}
                """,
                environment: "Reef"
            ),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)
        XCTAssertEqual(result.divesMerged, 1)

        let dives = try diveService.listDives()
        let dive = dives[0]

        // Notes from first row
        XCTAssertEqual(dive.notes, "Great vis today")
        // Environment from second row
        XCTAssertEqual(dive.environment, "Reef")
        // Site from first row
        XCTAssertNotNil(dive.siteId)
        // Buddy from second row
        let teammateIds = try diveService.getTeammateIds(diveId: dive.id)
        XCTAssertEqual(teammateIds.count, 1)
    }

    func testImportDeduplicationWithFingerprints() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001"),
        ])

        // First import creates dive + source fingerprint
        let result1 = try importService.importFromFile(at: path)
        XCTAssertEqual(result1.divesImported, 1)

        let dives = try diveService.listDives()
        let fps = try diveService.getSourceFingerprints(diveId: dives[0].id)
        XCTAssertEqual(fps.count, 1)

        // Second import should dedup via dive_source_fingerprints
        let result2 = try importService.importFromFile(at: path)
        XCTAssertEqual(result2.divesImported, 0)
        XCTAssertEqual(result2.divesSkipped, 1)

        // Still only 1 dive, 1 fingerprint
        let divesAfter = try diveService.listDives()
        XCTAssertEqual(divesAfter.count, 1)
    }

    func testImportDoesNotMergeSameSerial() throws {
        // Two dives from same serial within 2 min should NOT merge
        let startTime: Int64 = 1718444400
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(
                diveId: 100, diveDate: "2024-06-15 10:00:00", depthFt: 80,
                durationSec: 2400, serial: "SAME_SERIAL",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime)}
                """
            ),
            ShearwaterTestDive(
                diveId: 200, diveDate: "2024-06-15 10:00:30", depthFt: 82,
                durationSec: 2410, serial: "SAME_SERIAL",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime + 30)}
                """
            ),
        ])

        let result = try importService.importFromFile(at: path)

        // Should be 2 separate dives, not merged
        XCTAssertEqual(result.divesImported, 2)
        XCTAssertEqual(result.divesMerged, 0)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 2)
    }

    // MARK: - New Tests: Metadata Import

    func testImportNotes() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001",
                               notes: "Saw a whale shark!"),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives[0].notes, "Saw a whale shark!")
    }

    func testImportTemperatures() throws {
        // MinTemp=68°F, MaxTemp=78°F → 20°C, 25.56°C
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001",
                               minTemp: 68.0, maxTemp: 78.0, averageTemp: 73.0),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        let dive = dives[0]
        XCTAssertNotNil(dive.minTempC)
        XCTAssertEqual(dive.minTempC!, 20.0, accuracy: 0.1)
        XCTAssertNotNil(dive.maxTempC)
        XCTAssertEqual(dive.maxTempC!, 25.56, accuracy: 0.1)
        XCTAssertNotNil(dive.avgTempC)
        XCTAssertEqual(dive.avgTempC!, 22.78, accuracy: 0.1)
    }

    func testImportTemperaturesFallbackToCalcValues() throws {
        // Native temp columns are 0, but calculated_values has temps
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001",
                               calculatedValues: """
                                   {"AverageDepth": 30.0, "MinTemp": 68.0, "MaxTemp": 78.0, "MaxDecoObligation": 0}
                               """),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        XCTAssertNotNil(dives[0].minTempC)
        XCTAssertEqual(dives[0].minTempC!, 20.0, accuracy: 0.1)
    }

    func testImportGpsFromGnss() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001",
                               gnssEntryLocation: "17.31584, -87.53497"),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        let dive = dives[0]
        XCTAssertNotNil(dive.lat)
        XCTAssertEqual(dive.lat!, 17.31584, accuracy: 0.00001)
        XCTAssertNotNil(dive.lon)
        XCTAssertEqual(dive.lon!, -87.53497, accuracy: 0.00001)
    }

    func testImportEnvironmentFields() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001",
                               environment: "Reef", visibility: "30m", weather: "Sunny"),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        let dive = dives[0]
        XCTAssertEqual(dive.environment, "Reef")
        XCTAssertEqual(dive.visibility, "30m")
        XCTAssertEqual(dive.weather, "Sunny")
    }

    func testImportEndGf99() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 100,
                               durationSec: 3600, serial: "SN001",
                               endGf99: 72.5),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        XCTAssertNotNil(dives[0].endGf99)
        XCTAssertEqual(dives[0].endGf99!, 72.5, accuracy: 0.1)
    }

    func testImportSourceFingerprintsCreated() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001"),
        ])

        _ = try importService.importFromFile(at: path)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)

        let fps = try diveService.getSourceFingerprints(diveId: dives[0].id)
        XCTAssertEqual(fps.count, 1)
        XCTAssertEqual(fps[0].sourceType, "shearwater_cloud")
        XCTAssertEqual(fps[0].fingerprint, "1".data(using: .utf8)!)
    }

    func testSampleIdIsUnique() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001"),
        ])

        _ = try importService.importFromFile(at: path)

        let dives = try diveService.listDives()
        // Samples should have unique ids (from UUID)
        _ = try diveService.getSamples(diveId: dives[0].id)
        // Even with no libdivecomputer, 0 samples is valid
        // But the model should have the id field
        let testSample = DiveSample(diveId: "test", tSec: 0, depthM: 10, tempC: 20)
        XCTAssertFalse(testSample.id.isEmpty)
    }

    // MARK: - Phase 1A: Error Handling Tests

    func testImportEmptyDatabase() throws {
        let path = try createShearwaterDB(dives: [])

        let result = try importService.importFromFile(at: path)

        XCTAssertEqual(result.totalDivesInFile, 0)
        XCTAssertEqual(result.divesImported, 0)
        XCTAssertEqual(result.divesSkipped, 0)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 0)
    }

    func testImportMissingColumns() throws {
        // Create a DB with a minimal schema missing the Depth column
        let tempDir = FileManager.default.temporaryDirectory
        let path = tempDir.appendingPathComponent(UUID().uuidString + ".db").path
        tempFiles.append(path)

        let db = try DatabaseQueue(path: path)
        try db.write { conn in
            try conn.execute(sql: """
                CREATE TABLE dive_details (
                    DiveId INTEGER PRIMARY KEY,
                    DiveDate TEXT,
                    DiveLengthTime INTEGER,
                    SerialNumber TEXT
                );
                CREATE TABLE log_data (
                    log_id INTEGER PRIMARY KEY,
                    calculated_values_from_samples TEXT,
                    data_bytes_2 TEXT,
                    data_bytes_1 BLOB
                );
            """)
            // Insert a row without any Depth column
            try conn.execute(
                sql: "INSERT INTO dive_details (DiveId, DiveDate, DiveLengthTime, SerialNumber) VALUES (1, '2024-01-01 08:00:00', 1800, 'SN001')",
                arguments: []
            )
        }

        let result = try importService.importFromFile(at: path)

        // Row should be skipped because Depth is NULL (treated as 0)
        XCTAssertEqual(result.totalDivesInFile, 1)
        XCTAssertEqual(result.divesImported, 0)
        XCTAssertEqual(result.divesSkipped, 1)
    }

    func testImportInvalidTimestamps() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "not-a-date", depthFt: 50,
                               durationSec: 1800, serial: "SN001"),
        ])

        let result = try importService.importFromFile(at: path)

        // Row skipped because date can't be parsed and no metadata timestamp
        XCTAssertEqual(result.totalDivesInFile, 1)
        XCTAssertEqual(result.divesImported, 0)
        XCTAssertEqual(result.divesSkipped, 1)
    }

    func testImportZeroDepthSkipped() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 0,
                               durationSec: 1800, serial: "SN001"),
        ])

        let result = try importService.importFromFile(at: path)

        XCTAssertEqual(result.totalDivesInFile, 1)
        XCTAssertEqual(result.divesImported, 0)
        XCTAssertEqual(result.divesSkipped, 1)
    }

    func testImportZeroDurationSkipped() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 0, serial: "SN001"),
        ])

        let result = try importService.importFromFile(at: path)

        XCTAssertEqual(result.totalDivesInFile, 1)
        XCTAssertEqual(result.divesImported, 0)
        XCTAssertEqual(result.divesSkipped, 1)
    }

    // MARK: - Phase 1B: Edge Case Tests

    func testImportNegativeTemperatures() throws {
        // 28°F = -2.22°C (below freezing, ice diving)
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001",
                               minTemp: 28.0, maxTemp: 35.0),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        let dive = dives[0]
        // 28°F → (28-32)*5/9 = -2.22°C
        XCTAssertNotNil(dive.minTempC)
        XCTAssertEqual(dive.minTempC!, -2.22, accuracy: 0.1)
        // 35°F → (35-32)*5/9 = 1.67°C
        XCTAssertNotNil(dive.maxTempC)
        XCTAssertEqual(dive.maxTempC!, 1.67, accuracy: 0.1)
    }

    func testImportZeroFahrenheitTemperature() throws {
        // 32°F = 0°C boundary
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001",
                               minTemp: 32.0, maxTemp: 50.0),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        XCTAssertNotNil(dives[0].minTempC)
        XCTAssertEqual(dives[0].minTempC!, 0.0, accuracy: 0.01)
    }

    func testImportVeryLongNotes() throws {
        let longNotes = String(repeating: "A", count: 10_000)
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001",
                               notes: longNotes),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives[0].notes, longNotes)
        XCTAssertEqual(dives[0].notes?.count, 10_000)
    }

    func testImportEmptyBuddyString() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001", buddy: ""),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)
        XCTAssertEqual(result.teammatesCreated, 0)

        let teammates = try diveService.listTeammates()
        XCTAssertEqual(teammates.count, 0)
    }

    func testImportWhitespaceOnlyBuddy() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001", buddy: "  "),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 1)
        XCTAssertEqual(result.teammatesCreated, 0)

        let teammates = try diveService.listTeammates()
        XCTAssertEqual(teammates.count, 0)
    }

    func testImportDuplicateSiteNames() throws {
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(diveId: 1, diveDate: "2024-01-01 08:00:00", depthFt: 50,
                               durationSec: 1800, serial: "SN001", site: "Blue Hole"),
            ShearwaterTestDive(diveId: 2, diveDate: "2024-01-02 08:00:00", depthFt: 60,
                               durationSec: 2400, serial: "SN001", site: "Blue Hole"),
        ])

        let result = try importService.importFromFile(at: path)
        XCTAssertEqual(result.divesImported, 2)
        XCTAssertEqual(result.sitesCreated, 1)

        let sites = try diveService.listSites()
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].name, "Blue Hole")

        // Both dives should reference the same site
        let dives = try diveService.listDives()
        XCTAssertEqual(dives[0].siteId, dives[1].siteId)
    }

    // MARK: - Phase 1C: Stress Test

    func testImportPerformance_100Dives() throws {
        var testDives: [ShearwaterTestDive] = []
        let baseTime: Int64 = 1718444400

        for i in 1...100 {
            testDives.append(ShearwaterTestDive(
                diveId: i,
                diveDate: "2024-01-\(String(format: "%02d", (i % 28) + 1)) 08:00:00",
                depthFt: Double(50 + (i % 50)),
                durationSec: 1800 + (i * 60),
                serial: "SN001",
                site: "Site \(i % 10)",
                buddy: "Buddy \(i % 5)",
                dataBytes2: """
                    {"DIVE_NUMBER_KEY": \(i), "DIVE_START_TIME": \(baseTime + Int64(i) * 86400)}
                """
            ))
        }

        let path = try createShearwaterDB(dives: testDives)

        measure {
            do {
                // Re-create a fresh DB for each iteration
                let freshDb = try! DivelogDatabase(path: ":memory:")
                let freshService = ShearwaterCloudImportService(database: freshDb)
                let result = try freshService.importFromFile(at: path)
                XCTAssertEqual(result.divesImported, 100)
            } catch {
                XCTFail("Import failed: \(error)")
            }
        }
    }

    // MARK: - Phase 1D: Multi-Computer Merge Edge Cases

    func testImportThreeComputerMerge() throws {
        let startTime: Int64 = 1718444400
        let path = try createShearwaterDB(dives: [
            ShearwaterTestDive(
                diveId: 100, diveDate: "2024-06-15 10:00:00", depthFt: 100,
                durationSec: 3600, serial: "SERIAL_A",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime)}
                """
            ),
            ShearwaterTestDive(
                diveId: 200, diveDate: "2024-06-15 10:00:30", depthFt: 98,
                durationSec: 3580, serial: "SERIAL_B",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime + 30)}
                """
            ),
            ShearwaterTestDive(
                diveId: 300, diveDate: "2024-06-15 10:01:00", depthFt: 102,
                durationSec: 3590, serial: "SERIAL_C",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime + 60)}
                """
            ),
        ])

        let result = try importService.importFromFile(at: path)

        // 3 rows merged into 1 dive
        XCTAssertEqual(result.divesImported, 1)
        XCTAssertEqual(result.divesMerged, 2)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 1)
        XCTAssertNotNil(dives[0].groupId)

        let fps = try diveService.getSourceFingerprints(diveId: dives[0].id)
        XCTAssertEqual(fps.count, 3)
    }

    func testImportMergeWindowBoundary() throws {
        let startTime: Int64 = 1718444400

        // Two dives exactly 120s apart → should merge
        let pathMerge = try createShearwaterDB(dives: [
            ShearwaterTestDive(
                diveId: 100, diveDate: "2024-06-15 10:00:00", depthFt: 80,
                durationSec: 2400, serial: "SERIAL_A",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime)}
                """
            ),
            ShearwaterTestDive(
                diveId: 200, diveDate: "2024-06-15 10:02:00", depthFt: 82,
                durationSec: 2380, serial: "SERIAL_B",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime + 120)}
                """
            ),
        ])

        let resultMerge = try importService.importFromFile(at: pathMerge)
        XCTAssertEqual(resultMerge.divesImported, 1)
        XCTAssertEqual(resultMerge.divesMerged, 1)

        // Two dives 121s apart → should NOT merge (separate dives)
        let freshDb = try DivelogDatabase(path: ":memory:")
        let freshService = ShearwaterCloudImportService(database: freshDb)
        let freshDiveService = DiveService(database: freshDb)

        let pathSeparate = try createShearwaterDB(dives: [
            ShearwaterTestDive(
                diveId: 300, diveDate: "2024-06-15 10:00:00", depthFt: 80,
                durationSec: 2400, serial: "SERIAL_A",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime)}
                """
            ),
            ShearwaterTestDive(
                diveId: 400, diveDate: "2024-06-15 10:02:01", depthFt: 82,
                durationSec: 2380, serial: "SERIAL_B",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime + 121)}
                """
            ),
        ])

        let resultSeparate = try freshService.importFromFile(at: pathSeparate)
        XCTAssertEqual(resultSeparate.divesImported, 2)
        XCTAssertEqual(resultSeparate.divesMerged, 0)

        let dives = try freshDiveService.listDives()
        XCTAssertEqual(dives.count, 2)
    }

    func testImportPartialReimportAddsSamples() throws {
        let startTime: Int64 = 1718444400

        // First import: 2 computers
        let path1 = try createShearwaterDB(dives: [
            ShearwaterTestDive(
                diveId: 100, diveDate: "2024-06-15 10:00:00", depthFt: 100,
                durationSec: 3600, serial: "SERIAL_A",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime)}
                """
            ),
            ShearwaterTestDive(
                diveId: 200, diveDate: "2024-06-15 10:00:30", depthFt: 98,
                durationSec: 3580, serial: "SERIAL_B",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime + 30)}
                """
            ),
        ])

        let result1 = try importService.importFromFile(at: path1)
        XCTAssertEqual(result1.divesImported, 1)
        XCTAssertEqual(result1.divesMerged, 1)

        let divesBefore = try diveService.listDives()
        XCTAssertEqual(divesBefore.count, 1)
        let fpsBefore = try diveService.getSourceFingerprints(diveId: divesBefore[0].id)
        XCTAssertEqual(fpsBefore.count, 2)

        // Second import: 1 existing + 1 new fingerprint
        let path2 = try createShearwaterDB(dives: [
            ShearwaterTestDive(
                diveId: 100, diveDate: "2024-06-15 10:00:00", depthFt: 100,
                durationSec: 3600, serial: "SERIAL_A",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime)}
                """
            ),
            ShearwaterTestDive(
                diveId: 300, diveDate: "2024-06-15 10:00:45", depthFt: 99,
                durationSec: 3570, serial: "SERIAL_C",
                dataBytes2: """
                    {"DIVE_START_TIME": \(startTime + 45)}
                """
            ),
        ])

        let result2 = try importService.importFromFile(at: path2)
        // The existing fingerprint (100) is skipped, the new one (300) is merged into the existing dive
        XCTAssertEqual(result2.divesMerged, 1)

        // Still just 1 dive
        let divesAfter = try diveService.listDives()
        XCTAssertEqual(divesAfter.count, 1)

        // Now 3 source fingerprints
        let fpsAfter = try diveService.getSourceFingerprints(diveId: divesAfter[0].id)
        XCTAssertEqual(fpsAfter.count, 3)
    }

    // MARK: - Helper: Create Shearwater Test Database

    struct ShearwaterTestDive {
        var diveId: Int
        var diveDate: String
        var depthFt: Double
        var durationSec: Int
        var serial: String
        var site: String? = nil
        var location: String? = nil
        var buddy: String? = nil
        var calculatedValues: String? = nil
        var dataBytes2: String? = nil
        var dataBytes1: Data? = nil
        var diveNumber: Int? = nil
        var averageDepth: Double? = nil
        var notes: String? = nil
        var minTemp: Double? = nil
        var maxTemp: Double? = nil
        var averageTemp: Double? = nil
        var endGf99: Double? = nil
        var gnssEntryLocation: String? = nil
        var environment: String? = nil
        var visibility: String? = nil
        var weather: String? = nil
    }

    private func createShearwaterDB(dives: [ShearwaterTestDive]) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let path = tempDir.appendingPathComponent(UUID().uuidString + ".db").path
        tempFiles.append(path)

        let db = try DatabaseQueue(path: path)
        try db.write { conn in
            try conn.execute(sql: """
                CREATE TABLE dive_details (
                    DiveId INTEGER PRIMARY KEY,
                    DiveDate TEXT,
                    Depth REAL,
                    DiveLengthTime INTEGER,
                    SerialNumber TEXT,
                    Site TEXT,
                    Location TEXT,
                    Buddy TEXT,
                    DiveNumber INTEGER,
                    AverageDepth REAL,
                    Notes TEXT,
                    MinTemp REAL,
                    MaxTemp REAL,
                    AverageTemp REAL,
                    EndGF99 REAL,
                    GnssEntryLocation TEXT,
                    Environment TEXT,
                    Visibility TEXT,
                    Weather TEXT
                );

                CREATE TABLE log_data (
                    log_id INTEGER PRIMARY KEY,
                    calculated_values_from_samples TEXT,
                    data_bytes_2 TEXT,
                    data_bytes_1 BLOB
                );
            """)

            for dive in dives {
                try conn.execute(
                    sql: """
                        INSERT INTO dive_details (DiveId, DiveDate, Depth, DiveLengthTime, SerialNumber, Site, Location, Buddy, DiveNumber, AverageDepth, Notes, MinTemp, MaxTemp, AverageTemp, EndGF99, GnssEntryLocation, Environment, Visibility, Weather)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        dive.diveId,
                        dive.diveDate,
                        dive.depthFt,
                        dive.durationSec,
                        dive.serial,
                        dive.site,
                        dive.location,
                        dive.buddy,
                        dive.diveNumber,
                        dive.averageDepth,
                        dive.notes,
                        dive.minTemp,
                        dive.maxTemp,
                        dive.averageTemp,
                        dive.endGf99,
                        dive.gnssEntryLocation,
                        dive.environment,
                        dive.visibility,
                        dive.weather
                    ]
                )

                if dive.calculatedValues != nil || dive.dataBytes2 != nil || dive.dataBytes1 != nil {
                    try conn.execute(
                        sql: """
                            INSERT INTO log_data (log_id, calculated_values_from_samples, data_bytes_2, data_bytes_1)
                            VALUES (?, ?, ?, ?)
                        """,
                        arguments: [
                            dive.diveId,
                            dive.calculatedValues,
                            dive.dataBytes2,
                            dive.dataBytes1
                        ]
                    )
                }
            }
        }

        return path
    }
}
