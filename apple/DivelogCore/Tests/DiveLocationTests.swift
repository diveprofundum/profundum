import GRDB
import XCTest
@testable import DivelogCore

final class DiveLocationTests: XCTestCase {
    func testRecordLocationKeepsFirstEntryAndLastExit() {
        var dive = ParsedDive(
            startTimeUnix: 0, endTimeUnix: 60, maxDepthM: 10, avgDepthM: 5, bottomTimeSec: 60
        )
        DiveDataMapper.recordLocation(lat: 0, lon: 0, on: &dive)
        DiveDataMapper.recordLocation(lat: 17.1, lon: -87.1, on: &dive)
        DiveDataMapper.recordLocation(lat: 17.2, lon: -87.2, on: &dive)
        DiveDataMapper.recordLocation(lat: 91, lon: 0, on: &dive)

        XCTAssertEqual(dive.lat!, 17.1, accuracy: 0.00001)
        XCTAssertEqual(dive.lon!, -87.1, accuracy: 0.00001)
        XCTAssertEqual(dive.exitLat!, 17.2, accuracy: 0.00001)
        XCTAssertEqual(dive.exitLon!, -87.2, accuracy: 0.00001)
    }

    func testFillingMissingCoordinatesDoesNotOverwrite() {
        var stored = Dive(
            deviceId: "device",
            startTimeUnix: 0,
            endTimeUnix: 60,
            maxDepthM: 10,
            avgDepthM: 5,
            bottomTimeSec: 60,
            lat: 1,
            lon: 2
        )
        let incoming = ParsedDive(
            startTimeUnix: 0, endTimeUnix: 60, maxDepthM: 10, avgDepthM: 5, bottomTimeSec: 60,
            lat: 9, lon: 9, exitLat: 8, exitLon: 8
        )
        var filled = DiveDataMapper.fillingMissingCoordinates(stored, from: incoming)
        XCTAssertEqual(filled.lat!, 1, accuracy: 0.00001)
        XCTAssertEqual(filled.exitLat!, 8, accuracy: 0.00001)

        stored.exitLat = 3
        stored.exitLon = 4
        filled = DiveDataMapper.fillingMissingCoordinates(stored, from: incoming)
        XCTAssertEqual(filled.exitLat!, 3, accuracy: 0.00001)
    }

    func testMigrationAddsExitColumns() throws {
        let database = try DivelogDatabase(path: ":memory:")
        let columns = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(dives)").compactMap { $0["name"] as String? }
        }
        XCTAssertTrue(columns.contains("exit_lat"))
        XCTAssertTrue(columns.contains("exit_lon"))
    }

    func testReimportFillsNullGpsAndLeavesAnEditedFix() throws {
        let database = try DivelogDatabase(path: ":memory:")
        let diveService = DiveService(database: database)
        let importService = DiveComputerImportService(database: database)
        let device = Device(model: "Perdix", serialNumber: "P-1", firmwareVersion: "93")
        try diveService.saveDevice(device)

        let fingerprint = Data([0x11, 0x22])
        let samples = [
            ParsedSample(tSec: 0, depthM: 0, tempC: 20),
            ParsedSample(tSec: 60, depthM: 20, tempC: 18),
        ]
        let first = ParsedDive(
            startTimeUnix: 1_700_000_000,
            endTimeUnix: 1_700_003_600,
            maxDepthM: 20,
            avgDepthM: 10,
            bottomTimeSec: 3600,
            fingerprint: fingerprint,
            samples: samples
        )
        XCTAssertEqual(try importService.saveImportedDive(first, deviceId: device.id), .saved)

        let withGps = ParsedDive(
            startTimeUnix: first.startTimeUnix,
            endTimeUnix: first.endTimeUnix,
            maxDepthM: 20,
            avgDepthM: 10,
            bottomTimeSec: 3600,
            fingerprint: fingerprint,
            samples: samples,
            lat: 17.31584,
            lon: -87.53497,
            exitLat: 17.31610,
            exitLon: -87.53520
        )
        XCTAssertEqual(try importService.saveImportedDive(withGps, deviceId: device.id), .skipped)

        var dive = try diveService.listDives()[0]
        XCTAssertEqual(dive.lat!, 17.31584, accuracy: 0.00001)
        XCTAssertEqual(dive.exitLon!, -87.53520, accuracy: 0.00001)

        dive.lat = 1
        dive.lon = 2
        try diveService.saveDive(dive)
        let different = ParsedDive(
            startTimeUnix: first.startTimeUnix,
            endTimeUnix: first.endTimeUnix,
            maxDepthM: 20,
            avgDepthM: 10,
            bottomTimeSec: 3600,
            fingerprint: fingerprint,
            samples: samples,
            lat: 9,
            lon: 9,
            exitLat: 8,
            exitLon: 8
        )
        XCTAssertEqual(try importService.saveImportedDive(different, deviceId: device.id), .skipped)
        let kept = try diveService.listDives()[0]
        XCTAssertEqual(kept.lat!, 1, accuracy: 0.00001)
        XCTAssertEqual(kept.lon!, 2, accuracy: 0.00001)
        XCTAssertEqual(kept.exitLat!, 17.31610, accuracy: 0.00001)
    }

    func testSetSiteCoordinatesFillsOnlyABlankSiteAndKeepsTags() throws {
        let database = try DivelogDatabase(path: ":memory:")
        let diveService = DiveService(database: database)
        let site = Site(name: "Blue Hole")
        try diveService.saveSite(site, tags: ["wall"])

        XCTAssertTrue(try diveService.setSiteCoordinatesIfMissing(
            siteId: site.id, lat: 17.3, lon: -87.5
        ))
        XCTAssertFalse(try diveService.setSiteCoordinatesIfMissing(
            siteId: site.id, lat: 1, lon: 2
        ))

        let stored = try XCTUnwrap(diveService.getSite(id: site.id))
        XCTAssertEqual(stored.lat!, 17.3, accuracy: 0.00001)
        XCTAssertEqual(stored.lon!, -87.5, accuracy: 0.00001)
        let tags = try database.dbQueue.read { db in
            try SiteTag.filter(Column("site_id") == site.id).fetchAll(db).map(\.tag)
        }
        XCTAssertEqual(tags, ["wall"])
        XCTAssertFalse(try diveService.setSiteCoordinatesIfMissing(
            siteId: "missing", lat: 1, lon: 2
        ))
    }
}
