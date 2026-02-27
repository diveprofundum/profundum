import XCTest
@testable import DivelogCore

final class ExportSelfContainedTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
    }

    // MARK: - TDD Red: Subset export should include referenced buddies

    func testExportDivesIncludesReferencedBuddies() throws {
        // Arrange: create device, teammate, dive, and link them
        let device = Device(model: "Test Computer", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let buddy = Teammate(displayName: "Jane Doe", contact: "jane@example.com")
        try diveService.saveTeammate(buddy)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1_700_000_000,
            endTimeUnix: 1_700_003_600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive, tags: [], teammateIds: [buddy.id], equipmentIds: [])

        let exportService = ExportService(database: database)

        // Act: export only this dive
        let data = try exportService.exportDives(ids: [dive.id])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ExportData.self, from: data)

        // Assert: top-level buddies should contain the referenced teammate
        XCTAssertEqual(export.dives.count, 1)
        XCTAssertEqual(export.dives.first?.buddyIds, [buddy.id])
        XCTAssertEqual(export.buddies.count, 1, "Subset export must include referenced buddies")
        XCTAssertEqual(export.buddies.first?.id, buddy.id)
        XCTAssertEqual(export.buddies.first?.displayName, "Jane Doe")
    }

    // MARK: - TDD Red: Subset export should include referenced equipment

    func testExportDivesIncludesReferencedEquipment() throws {
        // Arrange
        let device = Device(model: "Test Computer", serialNumber: "SN2", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let gear = Equipment(name: "Primary Light", kind: "light", serialNumber: "L001")
        try diveService.saveEquipment(gear)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1_700_000_000,
            endTimeUnix: 1_700_003_600,
            maxDepthM: 25.0,
            avgDepthM: 15.0,
            bottomTimeSec: 2400
        )
        try diveService.saveDive(dive, tags: [], teammateIds: [], equipmentIds: [gear.id])

        let exportService = ExportService(database: database)

        // Act
        let data = try exportService.exportDives(ids: [dive.id])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ExportData.self, from: data)

        // Assert
        XCTAssertEqual(export.dives.count, 1)
        XCTAssertEqual(export.dives.first?.equipmentIds, [gear.id])
        XCTAssertEqual(export.equipment.count, 1, "Subset export must include referenced equipment")
        XCTAssertEqual(export.equipment.first?.id, gear.id)
        XCTAssertEqual(export.equipment.first?.name, "Primary Light")
    }

    // MARK: - TDD Red: Round-trip import into empty DB succeeds

    func testExportSubsetRoundTripIntoEmptyDB() throws {
        // Arrange: create a dive with both buddy and equipment
        let device = Device(model: "Test Computer", serialNumber: "SN3", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let buddy = Teammate(displayName: "Bob Smith")
        try diveService.saveTeammate(buddy)

        let gear = Equipment(name: "Wing", kind: "bcd")
        try diveService.saveEquipment(gear)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1_700_000_000,
            endTimeUnix: 1_700_003_600,
            maxDepthM: 40.0,
            avgDepthM: 22.0,
            bottomTimeSec: 2700
        )
        try diveService.saveDive(dive, tags: ["deep"], teammateIds: [buddy.id], equipmentIds: [gear.id])

        let exportService = ExportService(database: database)

        // Act: export the dive
        let jsonData = try exportService.exportDives(ids: [dive.id])

        // Import into a FRESH empty database
        let emptyDB = try DivelogDatabase(path: ":memory:")
        let importService = ExportService(database: emptyDB)

        // Assert: import should succeed without FK violations
        let result = try importService.importJSON(jsonData)
        XCTAssertEqual(result.divesImported, 1)
        XCTAssertEqual(result.buddiesImported, 1)
        XCTAssertEqual(result.equipmentImported, 1)
        XCTAssertEqual(result.devicesImported, 1)

        // Verify the imported data is correct
        let importedDiveService = DiveService(database: emptyDB)
        let importedBuddyIds = try importedDiveService.getTeammateIds(diveId: dive.id)
        XCTAssertEqual(importedBuddyIds, [buddy.id])

        let importedEquipmentIds = try importedDiveService.getEquipmentIds(diveId: dive.id)
        XCTAssertEqual(importedEquipmentIds, [gear.id])
    }

    // MARK: - Only referenced entities are included (no extras)

    func testExportDivesOnlyIncludesReferencedEntities() throws {
        // Arrange: create multiple buddies/equipment, but only link some to the dive
        let device = Device(model: "Test Computer", serialNumber: "SN4", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let buddy1 = Teammate(displayName: "Buddy One")
        let buddy2 = Teammate(displayName: "Buddy Two")
        try diveService.saveTeammate(buddy1)
        try diveService.saveTeammate(buddy2)

        let gear1 = Equipment(name: "Reg Set A", kind: "regulator")
        let gear2 = Equipment(name: "Reg Set B", kind: "regulator")
        try diveService.saveEquipment(gear1)
        try diveService.saveEquipment(gear2)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1_700_000_000,
            endTimeUnix: 1_700_003_600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000
        )
        // Only link buddy1 and gear1 to the dive
        try diveService.saveDive(dive, tags: [], teammateIds: [buddy1.id], equipmentIds: [gear1.id])

        let exportService = ExportService(database: database)

        // Act
        let data = try exportService.exportDives(ids: [dive.id])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ExportData.self, from: data)

        // Assert: only the referenced buddy and equipment should be included
        XCTAssertEqual(export.buddies.count, 1)
        XCTAssertEqual(export.buddies.first?.id, buddy1.id)
        XCTAssertEqual(export.equipment.count, 1)
        XCTAssertEqual(export.equipment.first?.id, gear1.id)
    }
}
