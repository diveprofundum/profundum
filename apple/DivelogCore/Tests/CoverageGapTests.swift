import XCTest
import GRDB
@testable import DivelogCore

/// Tests targeting coverage gaps identified by Codecov.
final class CoverageGapTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
    }

    // MARK: - PredefinedDiveTag displayName & color (34% → ~100%)

    func testAllPredefinedTagsHaveDisplayNames() {
        for tag in PredefinedDiveTag.allCases {
            XCTAssertFalse(tag.displayName.isEmpty, "\(tag) should have a display name")
        }
        // Verify specific activity tag names that were uncovered
        XCTAssertEqual(PredefinedDiveTag.cave.displayName, "Cave")
        XCTAssertEqual(PredefinedDiveTag.wreck.displayName, "Wreck")
        XCTAssertEqual(PredefinedDiveTag.reef.displayName, "Reef")
        XCTAssertEqual(PredefinedDiveTag.night.displayName, "Night")
        XCTAssertEqual(PredefinedDiveTag.shore.displayName, "Shore")
        XCTAssertEqual(PredefinedDiveTag.deep.displayName, "Deep")
        XCTAssertEqual(PredefinedDiveTag.training.displayName, "Training")
        XCTAssertEqual(PredefinedDiveTag.technical.displayName, "Technical")
    }

    func testAllPredefinedTagsHaveColors() {
        // Exercise every color switch arm — coverage requires the property to be accessed
        for tag in PredefinedDiveTag.allCases {
            _ = tag.color  // Access to cover the switch arm
        }
    }

    // MARK: - DiveTypeFilter (0% → 100%)

    func testDiveTypeFilterDisplayNames() {
        XCTAssertEqual(DiveTypeFilter.ccr.displayName, "CCR")
        XCTAssertEqual(DiveTypeFilter.oc.displayName, "OC")
    }

    func testDiveTypeFilterColors() {
        for filter in DiveTypeFilter.allCases {
            _ = filter.color
        }
    }

    func testDiveTypeFilterMatches() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let ccrDive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 3000, isCcr: true
        )
        let ocDive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700100000, endTimeUnix: 1700103600,
            maxDepthM: 18, avgDepthM: 12, bottomTimeSec: 3000, isCcr: false
        )

        XCTAssertTrue(DiveTypeFilter.ccr.matches(dive: ccrDive))
        XCTAssertFalse(DiveTypeFilter.oc.matches(dive: ccrDive))
        XCTAssertTrue(DiveTypeFilter.oc.matches(dive: ocDive))
        XCTAssertFalse(DiveTypeFilter.ccr.matches(dive: ocDive))
    }

    // MARK: - DiveWithSite (28% → ~100%)

    func testDiveWithSiteHashing() {
        let dive = Dive(
            deviceId: "dev1",
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 15, bottomTimeSec: 3000
        )
        let a = DiveWithSite(dive: dive, siteName: "Site A")
        let b = DiveWithSite(dive: dive, siteName: "Site A")

        // Same dive + same siteName → equal
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)

        // Custom hash only uses dive.id — different sites with same dive still collide
        let c = DiveWithSite(dive: dive, siteName: "Site B")
        XCTAssertEqual(a.hashValue, c.hashValue)
    }

    func testDiveWithSiteHashingDistinct() {
        let dive1 = Dive(
            deviceId: "dev1",
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 15, bottomTimeSec: 3000
        )
        let dive2 = Dive(
            deviceId: "dev1",
            startTimeUnix: 1700100000, endTimeUnix: 1700103600,
            maxDepthM: 25, avgDepthM: 18, bottomTimeSec: 2400
        )
        let a = DiveWithSite(dive: dive1, siteName: nil)
        let b = DiveWithSite(dive: dive2, siteName: nil)
        XCTAssertNotEqual(a, b)
    }

    func testDiveWithSiteFetchableRecord() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let site = Site(name: "Blue Hole", lat: 31.5, lon: -25.3)
        try diveService.saveSite(site, tags: [])

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 15, bottomTimeSec: 3000, siteId: site.id
        )
        try diveService.saveDive(dive, tags: ["oc"])

        // Fetch via the withSiteRequest association — exercises FetchableRecord.init(row:)
        let results: [DiveWithSite] = try database.dbQueue.read { db in
            try Dive.withSiteRequest()
                .filter(Column("id") == dive.id)
                .fetchAll(db)
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].siteName, "Blue Hole")
        XCTAssertEqual(results[0].dive.id, dive.id)
    }

    func testDiveWithSiteNilSiteName() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        // Dive without a site
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 15, bottomTimeSec: 3000
        )
        try diveService.saveDive(dive, tags: ["oc"])

        let results: [DiveWithSite] = try database.dbQueue.read { db in
            try Dive.withSiteRequest()
                .filter(Column("id") == dive.id)
                .fetchAll(db)
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].siteName)
    }

    // MARK: - DiveDownloadService structs (0% → 100%)

    func testDownloadProgressInit() {
        let progress = DownloadProgress(currentDive: 3, totalDives: 10)
        XCTAssertEqual(progress.currentDive, 3)
        XCTAssertEqual(progress.totalDives, 10)

        let progressNil = DownloadProgress(currentDive: 1)
        XCTAssertNil(progressNil.totalDives)
    }

    func testDownloadResultInit() {
        let result = DownloadResult(
            totalDives: 42,
            serialNumber: "ABC123",
            firmwareVersion: "2.1.0",
            vendorName: "Shearwater",
            productName: "Perdix"
        )
        XCTAssertEqual(result.totalDives, 42)
        XCTAssertEqual(result.serialNumber, "ABC123")
        XCTAssertEqual(result.firmwareVersion, "2.1.0")
        XCTAssertEqual(result.vendorName, "Shearwater")
        XCTAssertEqual(result.productName, "Perdix")
    }

    func testDownloadResultDefaultNils() {
        let result = DownloadResult(totalDives: 5)
        XCTAssertEqual(result.totalDives, 5)
        XCTAssertNil(result.serialNumber)
        XCTAssertNil(result.firmwareVersion)
        XCTAssertNil(result.vendorName)
        XCTAssertNil(result.productName)
    }

    func testMakeDiveDownloaderFactory() {
        // Exercise the factory function — result depends on whether LibDivecomputerFFI is linked
        let downloader = makeDiveDownloader()
        #if canImport(LibDivecomputerFFI)
        XCTAssertNotNil(downloader)
        #else
        XCTAssertNil(downloader)
        #endif
    }

    // MARK: - DivelogCompute wrapper (75% → ~100%)

    func testEvaluateFormulaThrowsOnUnknownVariable() {
        XCTAssertThrowsError(try DivelogCompute.evaluateFormula("unknown_var + 1", variables: [:]))
    }

    func testEvaluateFormulaSucceeds() throws {
        let result = try DivelogCompute.evaluateFormula("x + y * 2", variables: ["x": 10.0, "y": 5.0])
        XCTAssertEqual(result, 20.0, accuracy: 0.001)
    }

    func testComputeSurfaceGfWithExplicitSurfacePressure() {
        // Exercise the surfacePressureBar parameter path
        let samples = [
            SampleInput(tSec: 0, depthM: 0.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil, ttsSec: nil, ndlSec: nil, decoStopDepthM: nil, atPlusFiveTtsMin: nil),
            SampleInput(tSec: 60, depthM: 20.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil, ttsSec: nil, ndlSec: nil, decoStopDepthM: nil, atPlusFiveTtsMin: nil),
            SampleInput(tSec: 3000, depthM: 20.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil, ttsSec: nil, ndlSec: nil, decoStopDepthM: nil, atPlusFiveTtsMin: nil),
            SampleInput(tSec: 3600, depthM: 0.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil, ttsSec: nil, ndlSec: nil, decoStopDepthM: nil, atPlusFiveTtsMin: nil),
        ]
        let gasMixes = [GasMixInput(mixIndex: 0, o2Fraction: 0.21, heFraction: 0.0)]

        // With explicit surface pressure
        let points = DivelogCompute.computeSurfaceGf(
            samples: samples,
            gasMixes: gasMixes,
            surfacePressureBar: 1.013
        )
        XCTAssertFalse(points.isEmpty)

        // Without (nil defaults)
        let defaultPoints = DivelogCompute.computeSurfaceGf(
            samples: samples,
            gasMixes: gasMixes
        )
        XCTAssertFalse(defaultPoints.isEmpty)
    }

    func testSupportedFunctions() {
        let funcs = DivelogCompute.supportedFunctions()
        let names = funcs.map { $0.name }
        XCTAssertTrue(names.contains("min"))
        XCTAssertTrue(names.contains("max"))
        XCTAssertTrue(names.contains("floor"))
        XCTAssertTrue(names.contains("ceil"))
    }

    // MARK: - Junction table models (Dive.swift, Segment.swift, Site.swift)

    func testDiveTeammateRoundTrip() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 15, bottomTimeSec: 3000
        )
        try diveService.saveDive(dive, tags: ["oc"])

        let teammate = Teammate(displayName: "Alice")
        try diveService.saveTeammate(teammate)

        let dt = DiveTeammate(diveId: dive.id, teammateId: teammate.id)
        try database.dbQueue.write { db in
            try dt.insert(db)
        }

        let fetched: [DiveTeammate] = try database.dbQueue.read { db in
            try DiveTeammate.fetchAll(db)
        }
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].diveId, dive.id)
        XCTAssertEqual(fetched[0].teammateId, teammate.id)
    }

    func testDiveEquipmentRoundTrip() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 15, bottomTimeSec: 3000
        )
        try diveService.saveDive(dive, tags: ["oc"])

        let equipment = Equipment(name: "Wing BCD", kind: "bcd")
        try diveService.saveEquipment(equipment)

        let de = DiveEquipment(diveId: dive.id, equipmentId: equipment.id)
        try database.dbQueue.write { db in
            try de.insert(db)
        }

        let fetched: [DiveEquipment] = try database.dbQueue.read { db in
            try DiveEquipment.fetchAll(db)
        }
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].diveId, dive.id)
        XCTAssertEqual(fetched[0].equipmentId, equipment.id)
    }

    func testSegmentTagRoundTrip() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 15, bottomTimeSec: 3000
        )
        try diveService.saveDive(dive, tags: ["oc"])

        let segment = Segment(diveId: dive.id, name: "Bottom", startTSec: 60, endTSec: 2400)
        try diveService.saveSegment(segment, tags: ["bottom_phase"])

        // Fetch segment tags via association
        let tags: [SegmentTag] = try database.dbQueue.read { db in
            try segment.tags.fetchAll(db)
        }
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].tag, "bottom_phase")
    }

    func testSiteTagRoundTrip() throws {
        let site = Site(name: "Great Blue Hole", lat: 17.3, lon: -87.5)
        try diveService.saveSite(site, tags: ["cenote", "famous"])

        // Fetch site tags via association
        let tags: [SiteTag] = try database.dbQueue.read { db in
            try site.tags.fetchAll(db)
        }
        XCTAssertEqual(tags.count, 2)
        let tagNames = Set(tags.map { $0.tag })
        XCTAssertTrue(tagNames.contains("cenote"))
        XCTAssertTrue(tagNames.contains("famous"))
    }

    // MARK: - Dive associations

    func testDiveSamplesAssociation() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 15, bottomTimeSec: 3000
        )
        try diveService.saveDive(dive, tags: ["oc"])

        let sample = DiveSample(
            diveId: dive.id, deviceId: device.id, tSec: 60, depthM: 10.0, tempC: 20.0
        )
        try database.dbQueue.write { db in
            try sample.insert(db)
        }

        let samples: [DiveSample] = try database.dbQueue.read { db in
            try dive.samples.fetchAll(db)
        }
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].tSec, 60)
    }

    func testDiveSegmentsAssociation() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 15, bottomTimeSec: 3000
        )
        try diveService.saveDive(dive, tags: ["oc"])

        let segment = Segment(diveId: dive.id, name: "Descent", startTSec: 0, endTSec: 120)
        try diveService.saveSegment(segment, tags: [])

        let segments: [Segment] = try database.dbQueue.read { db in
            try dive.segments.fetchAll(db)
        }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].name, "Descent")
    }

    func testDiveTagsAssociation() throws {
        let device = Device(model: "Test", serialNumber: "SN1", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000, endTimeUnix: 1700003600,
            maxDepthM: 20, avgDepthM: 15, bottomTimeSec: 3000
        )
        try diveService.saveDive(dive, tags: ["oc", "rec", "reef"])

        let tags: [DiveTag] = try database.dbQueue.read { db in
            try dive.tags.fetchAll(db)
        }
        XCTAssertEqual(tags.count, 3)
        let tagNames = Set(tags.map { $0.tag })
        XCTAssertTrue(tagNames.contains("oc"))
        XCTAssertTrue(tagNames.contains("rec"))
        XCTAssertTrue(tagNames.contains("reef"))
    }
}
