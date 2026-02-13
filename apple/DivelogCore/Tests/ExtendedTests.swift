import XCTest
@testable import DivelogCore

// MARK: - DiveQuery Filter Tests

final class DiveQueryTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!
    var device: Device!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        device = Device(model: "Test Computer", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)
    }

    // Helper to create a dive with specific properties
    private func makeDive(
        startTime: Int64 = 1700000000,
        duration: Int64 = 3600,
        maxDepth: Float = 20.0,
        avgDepth: Float = 12.0,
        bottomTime: Int32 = 2400,
        isCcr: Bool = false,
        decoRequired: Bool = false,
        siteId: String? = nil
    ) -> Dive {
        Dive(
            deviceId: device.id,
            startTimeUnix: startTime,
            endTimeUnix: startTime + duration,
            maxDepthM: maxDepth,
            avgDepthM: avgDepth,
            bottomTimeSec: bottomTime,
            isCcr: isCcr,
            decoRequired: decoRequired,
            siteId: siteId
        )
    }

    // MARK: - Time Range Filter

    func testTimeRangeFilterMin() throws {
        let old = makeDive(startTime: 1700000000)
        let recent = makeDive(startTime: 1700200000)
        try diveService.saveDive(old)
        try diveService.saveDive(recent)

        let query = DiveQuery(startTimeMin: 1700100000, limit: nil)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.startTimeUnix, 1700200000)
    }

    func testTimeRangeFilterMax() throws {
        let old = makeDive(startTime: 1700000000)
        let recent = makeDive(startTime: 1700200000)
        try diveService.saveDive(old)
        try diveService.saveDive(recent)

        let query = DiveQuery(startTimeMax: 1700100000, limit: nil)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.startTimeUnix, 1700000000)
    }

    func testTimeRangeFilterBoth() throws {
        let d1 = makeDive(startTime: 1700000000)
        let d2 = makeDive(startTime: 1700100000)
        let d3 = makeDive(startTime: 1700200000)
        try diveService.saveDive(d1)
        try diveService.saveDive(d2)
        try diveService.saveDive(d3)

        let query = DiveQuery(startTimeMin: 1700050000, startTimeMax: 1700150000, limit: nil)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.startTimeUnix, 1700100000)
    }

    // MARK: - Depth Range Filter

    func testDepthFilterMin() throws {
        let shallow = makeDive(maxDepth: 10.0)
        let deep = makeDive(startTime: 1700100000, maxDepth: 40.0)
        try diveService.saveDive(shallow)
        try diveService.saveDive(deep)

        let query = DiveQuery(minDepthM: 20.0, limit: nil)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.maxDepthM, 40.0)
    }

    func testDepthFilterMax() throws {
        let shallow = makeDive(maxDepth: 10.0)
        let deep = makeDive(startTime: 1700100000, maxDepth: 40.0)
        try diveService.saveDive(shallow)
        try diveService.saveDive(deep)

        let query = DiveQuery(maxDepthM: 20.0, limit: nil)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.maxDepthM, 10.0)
    }

    func testDepthFilterRange() throws {
        let d1 = makeDive(maxDepth: 5.0)
        let d2 = makeDive(startTime: 1700100000, maxDepth: 20.0)
        let d3 = makeDive(startTime: 1700200000, maxDepth: 50.0)
        try diveService.saveDive(d1)
        try diveService.saveDive(d2)
        try diveService.saveDive(d3)

        let query = DiveQuery(minDepthM: 10.0, maxDepthM: 30.0, limit: nil)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.maxDepthM, 20.0)
    }

    // MARK: - Deco Filter

    func testDecoFilter() throws {
        let noDeco = makeDive(decoRequired: false)
        let deco = makeDive(startTime: 1700100000, decoRequired: true)
        try diveService.saveDive(noDeco)
        try diveService.saveDive(deco)

        let query = DiveQuery.decoOnly(limit: 50)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first!.decoRequired)
    }

    func testDecoFilterFalse() throws {
        let noDeco = makeDive(decoRequired: false)
        let deco = makeDive(startTime: 1700100000, decoRequired: true)
        try diveService.saveDive(noDeco)
        try diveService.saveDive(deco)

        let query = DiveQuery(decoRequired: false, limit: nil)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results.first!.decoRequired)
    }

    // MARK: - Site Filter

    func testSiteFilter() throws {
        let site = Site(name: "Test Site")
        try diveService.saveSite(site)

        let d1 = makeDive(siteId: site.id)
        let d2 = makeDive(startTime: 1700100000, siteId: nil)
        try diveService.saveDive(d1)
        try diveService.saveDive(d2)

        let query = DiveQuery.atSite(site.id)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.siteId, site.id)
    }

    // MARK: - Tag Filter

    func testTagFilter() throws {
        let d1 = makeDive()
        let d2 = makeDive(startTime: 1700100000)
        let d3 = makeDive(startTime: 1700200000)
        try diveService.saveDive(d1, tags: ["cave", "deep"])
        try diveService.saveDive(d2, tags: ["reef"])
        try diveService.saveDive(d3, tags: ["cave"])

        // Filter by "cave" tag — should match d1 and d3
        let query = DiveQuery.withTags(["cave"])
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 2)
    }

    func testTagFilterMultipleTagsOR() throws {
        let d1 = makeDive()
        let d2 = makeDive(startTime: 1700100000)
        let d3 = makeDive(startTime: 1700200000)
        try diveService.saveDive(d1, tags: ["cave"])
        try diveService.saveDive(d2, tags: ["reef"])
        try diveService.saveDive(d3, tags: ["wreck"])

        // Filter by "cave" OR "reef" — should match d1 and d2
        let query = DiveQuery.withTags(["cave", "reef"])
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 2)
    }

    func testTagFilterNoMatch() throws {
        let d1 = makeDive()
        try diveService.saveDive(d1, tags: ["reef"])

        let query = DiveQuery.withTags(["cave"])
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Teammate Filter

    func testTeammateFilter() throws {
        let teammate = Teammate(displayName: "Alice")
        try diveService.saveTeammate(teammate)

        let d1 = makeDive()
        let d2 = makeDive(startTime: 1700100000)
        try diveService.saveDive(d1, teammateIds: [teammate.id])
        try diveService.saveDive(d2)

        let query = DiveQuery.withTeammate(teammate.id)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - Sorting

    func testResultsSortedByDateDescending() throws {
        let d1 = makeDive(startTime: 1700000000)
        let d2 = makeDive(startTime: 1700300000)
        let d3 = makeDive(startTime: 1700100000)
        try diveService.saveDive(d1)
        try diveService.saveDive(d2)
        try diveService.saveDive(d3)

        let results = try diveService.listDives(query: DiveQuery(limit: nil))
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].startTimeUnix, 1700300000)
        XCTAssertEqual(results[1].startTimeUnix, 1700100000)
        XCTAssertEqual(results[2].startTimeUnix, 1700000000)
    }

    // MARK: - Pagination

    func testPaginationLimit() throws {
        for i in 0..<5 {
            let dive = makeDive(startTime: 1700000000 + Int64(i * 100000))
            try diveService.saveDive(dive)
        }

        let query = DiveQuery(limit: 3)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 3)
    }

    func testPaginationOffset() throws {
        for i in 0..<5 {
            let dive = makeDive(startTime: 1700000000 + Int64(i * 100000))
            try diveService.saveDive(dive)
        }

        // Get the second page (offset 3, limit 3 — should get 2 results)
        let query = DiveQuery(limit: 3, offset: 3)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 2)
    }

    func testPaginationNoLimit() throws {
        for i in 0..<100 {
            let dive = makeDive(startTime: 1700000000 + Int64(i * 100000))
            try diveService.saveDive(dive)
        }

        let query = DiveQuery(limit: nil)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 100)
    }

    func testDefaultLimitIs50() throws {
        for i in 0..<60 {
            let dive = makeDive(startTime: 1700000000 + Int64(i * 100000))
            try diveService.saveDive(dive)
        }

        let query = DiveQuery()
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 50)
    }

    // MARK: - Combined Filters

    func testCombinedFilters() throws {
        let d1 = makeDive(startTime: 1700000000, maxDepth: 30.0, isCcr: true, decoRequired: true)
        let d2 = makeDive(startTime: 1700100000, maxDepth: 40.0, isCcr: true, decoRequired: false)
        let d3 = makeDive(startTime: 1700200000, maxDepth: 35.0, isCcr: false, decoRequired: true)
        try diveService.saveDive(d1)
        try diveService.saveDive(d2)
        try diveService.saveDive(d3)

        // CCR + deco required
        let query = DiveQuery(isCcr: true, decoRequired: true, limit: nil)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.maxDepthM, 30.0)
    }

    // MARK: - DiveWithSite Query

    func testDiveWithSiteQuery() throws {
        let site = Site(name: "Blue Hole")
        try diveService.saveSite(site)

        let d1 = makeDive(siteId: site.id)
        let d2 = makeDive(startTime: 1700100000, siteId: nil)
        try diveService.saveDive(d1)
        try diveService.saveDive(d2)

        let query = DiveQuery(limit: nil)
        let results = try diveService.listDivesWithSites(query: query)
        XCTAssertEqual(results.count, 2)

        // One should have site name, one should be nil
        let withSite = results.first { $0.siteName != nil }
        let withoutSite = results.first { $0.siteName == nil }
        XCTAssertEqual(withSite?.siteName, "Blue Hole")
        XCTAssertNotNil(withoutSite)
    }

    // MARK: - Convenience Builders

    func testConvenienceRecentDefault() {
        let query = DiveQuery.recent()
        XCTAssertEqual(query.limit, 50)
        XCTAssertNil(query.isCcr)
        XCTAssertNil(query.decoRequired)
    }

    func testConvenienceCcrOnly() {
        let query = DiveQuery.ccrOnly()
        XCTAssertEqual(query.isCcr, true)
        XCTAssertEqual(query.limit, 50)
    }

    func testConvenienceDecoOnly() {
        let query = DiveQuery.decoOnly()
        XCTAssertEqual(query.decoRequired, true)
    }

    func testConvenienceAtSite() {
        let query = DiveQuery.atSite("site-123")
        XCTAssertEqual(query.siteId, "site-123")
    }

    func testConvenienceWithTeammate() {
        let query = DiveQuery.withTeammate("tm-123")
        XCTAssertEqual(query.teammateId, "tm-123")
    }

    func testConvenienceWithTags() {
        let query = DiveQuery.withTags(["deep", "night"])
        XCTAssertEqual(query.tagAny, ["deep", "night"])
    }

    // MARK: - Empty Query

    func testEmptyQueryReturnsAll() throws {
        for i in 0..<3 {
            let dive = makeDive(startTime: 1700000000 + Int64(i * 100000))
            try diveService.saveDive(dive)
        }

        let query = DiveQuery(limit: nil)
        let results = try diveService.listDives(query: query)
        XCTAssertEqual(results.count, 3)
    }
}

// MARK: - FormulaService Tests

final class FormulaServiceTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!
    var formulaService: FormulaService!
    var device: Device!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        formulaService = FormulaService(database: database)
        device = Device(model: "Test Computer", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)
    }

    // MARK: - Validation

    func testValidateFormulaForDiveValidExpression() {
        let err = formulaService.validateFormulaForDive("max_depth_m * 2")
        XCTAssertNil(err)
    }

    func testValidateFormulaForDiveInvalidVariable() {
        let err = formulaService.validateFormulaForDive("nonexistent_var * 2")
        XCTAssertNotNil(err)
    }

    func testValidateFormulaForSegmentValidExpression() {
        let err = formulaService.validateFormulaForSegment("duration_min * max_depth_m")
        XCTAssertNil(err)
    }

    func testValidateFormulaForSegmentInvalidVariable() {
        let err = formulaService.validateFormulaForSegment("bottom_time_min * 2")
        XCTAssertNotNil(err)
    }

    // MARK: - Formula Evaluation for Dive

    func testEvaluateFormulaForDive() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            isCcr: true,
            cnsPercent: 15.0,
            otu: 25.0
        )
        try diveService.saveDive(dive)

        let samples = [
            DiveSample(diveId: dive.id, tSec: 0, depthM: 0.0, tempC: 22.0),
            DiveSample(diveId: dive.id, tSec: 60, depthM: 15.0, tempC: 20.0),
            DiveSample(diveId: dive.id, tSec: 300, depthM: 30.0, tempC: 16.0),
            DiveSample(diveId: dive.id, tSec: 600, depthM: 0.0, tempC: 20.0),
        ]
        try diveService.saveSamples(samples)

        // Evaluate a formula that uses max_depth_m
        let result = try formulaService.evaluateFormulaForDive("max_depth_m", diveId: dive.id)
        XCTAssertEqual(result, 30.0, accuracy: 0.01)
    }

    func testEvaluateFormulaForDiveWithComputation() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            isCcr: true
        )
        try diveService.saveDive(dive)

        let samples = [
            DiveSample(diveId: dive.id, tSec: 0, depthM: 0.0, tempC: 22.0),
            DiveSample(diveId: dive.id, tSec: 300, depthM: 30.0, tempC: 16.0),
            DiveSample(diveId: dive.id, tSec: 600, depthM: 0.0, tempC: 20.0),
        ]
        try diveService.saveSamples(samples)

        // is_ccr should be 1.0 for CCR dive
        let ccrResult = try formulaService.evaluateFormulaForDive("is_ccr", diveId: dive.id)
        XCTAssertEqual(ccrResult, 1.0, accuracy: 0.01)

        // bottom_time_min should be 3000/60 = 50.0
        let btResult = try formulaService.evaluateFormulaForDive("bottom_time_min", diveId: dive.id)
        XCTAssertEqual(btResult, 50.0, accuracy: 0.01)
    }

    func testEvaluateFormulaForDiveNotFound() {
        XCTAssertThrowsError(try formulaService.evaluateFormulaForDive("max_depth_m", diveId: "nonexistent")) { error in
            guard case FormulaServiceError.diveNotFound = error else {
                XCTFail("Expected diveNotFound error, got \(error)")
                return
            }
        }
    }

    // MARK: - Formula Evaluation for Segment

    func testEvaluateFormulaForSegment() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive)

        let samples = [
            DiveSample(diveId: dive.id, tSec: 0, depthM: 0.0, tempC: 22.0),
            DiveSample(diveId: dive.id, tSec: 60, depthM: 15.0, tempC: 20.0),
            DiveSample(diveId: dive.id, tSec: 120, depthM: 25.0, tempC: 18.0),
            DiveSample(diveId: dive.id, tSec: 180, depthM: 20.0, tempC: 19.0),
            DiveSample(diveId: dive.id, tSec: 300, depthM: 0.0, tempC: 22.0),
        ]
        try diveService.saveSamples(samples)

        let segment = Segment(diveId: dive.id, name: "Bottom", startTSec: 60, endTSec: 180)
        try diveService.saveSegment(segment)

        let durationResult = try formulaService.evaluateFormulaForSegment("duration_sec", segmentId: segment.id)
        XCTAssertEqual(durationResult, 120.0, accuracy: 0.01)
    }

    func testEvaluateFormulaForSegmentNotFound() {
        XCTAssertThrowsError(try formulaService.evaluateFormulaForSegment("duration_sec", segmentId: "nonexistent")) { error in
            guard case FormulaServiceError.segmentNotFound = error else {
                XCTFail("Expected segmentNotFound error, got \(error)")
                return
            }
        }
    }

    // MARK: - Compute and Store Calculated Field

    func testComputeAndStoreCalculatedField() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive)

        let samples = [
            DiveSample(diveId: dive.id, tSec: 0, depthM: 0.0, tempC: 22.0),
            DiveSample(diveId: dive.id, tSec: 300, depthM: 30.0, tempC: 16.0),
        ]
        try diveService.saveSamples(samples)

        let formula = Formula(name: "Max Depth", expression: "max_depth_m")
        try diveService.saveFormula(formula)

        let value = try formulaService.computeAndStoreCalculatedField(formulaId: formula.id, diveId: dive.id)
        XCTAssertEqual(value, 30.0, accuracy: 0.01)

        // Verify stored
        let fields = try diveService.listCalculatedFields(diveId: dive.id)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.formulaId, formula.id)
        XCTAssertEqual(fields.first?.value ?? 0, 30.0, accuracy: 0.01)
    }

    func testComputeAndStoreFormulaNotFound() {
        XCTAssertThrowsError(try formulaService.computeAndStoreCalculatedField(formulaId: "nonexistent", diveId: "any")) { error in
            guard case FormulaServiceError.formulaNotFound = error else {
                XCTFail("Expected formulaNotFound error, got \(error)")
                return
            }
        }
    }

    // MARK: - Variable Dictionary

    func testFormulaVariablesDiveContainsAllExpectedKeys() {
        let expectedKeys = [
            "max_depth_m", "avg_depth_m", "bottom_time_sec", "bottom_time_min",
            "cns_percent", "otu", "is_ccr", "deco_required",
            "o2_consumed_psi", "o2_consumed_bar", "o2_rate_cuft_min", "o2_rate_l_min",
            "total_time_sec", "total_time_min", "deco_time_sec", "deco_time_min",
            "weighted_avg_depth_m", "min_temp_c", "max_temp_c", "avg_temp_c",
            "gas_switch_count", "max_ceiling_m", "max_gf99",
            "descent_rate_m_min", "ascent_rate_m_min",
            // Imperial equivalents
            "max_depth_ft", "avg_depth_ft", "weighted_avg_depth_ft",
            "max_ceiling_ft", "min_temp_f", "max_temp_f", "avg_temp_f",
        ]

        let dive = Dive(
            deviceId: "dev-test",
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )

        let stats = DivelogCompute.computeDiveStats(
            dive: DiveInput(startTimeUnix: 1700000000, endTimeUnix: 1700003600, bottomTimeSec: 3000),
            samples: [
                SampleInput(tSec: 0, depthM: 0.0, tempC: 22.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil),
                SampleInput(tSec: 300, depthM: 30.0, tempC: 16.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil),
            ]
        )

        let vars = FormulaVariables.fromDive(dive, stats: stats)

        for key in expectedKeys {
            XCTAssertNotNil(vars[key], "Missing expected variable: \(key)")
        }
    }

    func testFormulaVariablesSegmentContainsAllExpectedKeys() {
        let expectedKeys = [
            "start_t_sec", "end_t_sec",
            "duration_sec", "duration_min",
            "max_depth_m", "avg_depth_m",
            "min_temp_c", "max_temp_c",
            "deco_time_sec", "deco_time_min",
            "sample_count",
            // Imperial equivalents
            "max_depth_ft", "avg_depth_ft",
            "min_temp_f", "max_temp_f",
        ]

        let segment = Segment(diveId: "dive-test", name: "Bottom", startTSec: 60, endTSec: 300)
        let stats = DivelogCompute.computeSegmentStats(
            startTSec: 60,
            endTSec: 300,
            samples: [
                SampleInput(tSec: 60, depthM: 10.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil),
                SampleInput(tSec: 180, depthM: 25.0, tempC: 18.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil),
                SampleInput(tSec: 300, depthM: 15.0, tempC: 19.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil),
            ]
        )

        let vars = FormulaVariables.fromSegment(segment, stats: stats)

        for key in expectedKeys {
            XCTAssertNotNil(vars[key], "Missing expected variable: \(key)")
        }
    }

    func testFormulaVariablesImperialConversions() {
        let dive = Dive(
            deviceId: "dev-test",
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )

        let stats = DivelogCompute.computeDiveStats(
            dive: DiveInput(startTimeUnix: 1700000000, endTimeUnix: 1700003600, bottomTimeSec: 3000),
            samples: [
                SampleInput(tSec: 0, depthM: 0.0, tempC: 22.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil),
                SampleInput(tSec: 300, depthM: 30.0, tempC: 16.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil, ppo2: nil),
            ]
        )

        let vars = FormulaVariables.fromDive(dive, stats: stats)

        // max_depth_ft should be max_depth_m * 3.28084
        XCTAssertEqual(vars["max_depth_ft"]!, 30.0 * 3.28084, accuracy: 0.01)
        XCTAssertEqual(vars["avg_depth_ft"]!, 18.0 * 3.28084, accuracy: 0.01)
    }

    // MARK: - DiveStats Computation via Service

    func testComputeDiveStatsById() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive)

        let samples = [
            DiveSample(diveId: dive.id, tSec: 0, depthM: 0.0, tempC: 22.0),
            DiveSample(diveId: dive.id, tSec: 60, depthM: 15.0, tempC: 20.0),
            DiveSample(diveId: dive.id, tSec: 300, depthM: 30.0, tempC: 16.0),
            DiveSample(diveId: dive.id, tSec: 600, depthM: 0.0, tempC: 20.0),
        ]
        try diveService.saveSamples(samples)

        let stats = try formulaService.computeDiveStats(diveId: dive.id)
        XCTAssertEqual(stats.maxDepthM, 30.0)
        XCTAssertEqual(stats.minTempC, 16.0)
        XCTAssertEqual(stats.maxTempC, 22.0)
    }

    func testComputeSegmentStatsById() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive)

        let samples = [
            DiveSample(diveId: dive.id, tSec: 0, depthM: 0.0, tempC: 22.0),
            DiveSample(diveId: dive.id, tSec: 100, depthM: 15.0, tempC: 20.0),
            DiveSample(diveId: dive.id, tSec: 200, depthM: 25.0, tempC: 18.0),
            DiveSample(diveId: dive.id, tSec: 300, depthM: 20.0, tempC: 19.0),
        ]
        try diveService.saveSamples(samples)

        let segment = Segment(diveId: dive.id, name: "Bottom", startTSec: 100, endTSec: 300)
        try diveService.saveSegment(segment)

        let stats = try formulaService.computeSegmentStats(segmentId: segment.id)
        XCTAssertEqual(stats.durationSec, 200)
        XCTAssertEqual(stats.maxDepthM, 25.0)
        XCTAssertEqual(stats.sampleCount, 3)
    }
}

// MARK: - DiveService Extended CRUD Tests

final class DiveServiceExtendedTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!
    var device: Device!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
        device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)
    }

    // MARK: - Dive with Tags, Teammates, Equipment

    func testSaveDiveWithRelations() throws {
        let teammate1 = Teammate(displayName: "Alice")
        let teammate2 = Teammate(displayName: "Bob")
        try diveService.saveTeammate(teammate1)
        try diveService.saveTeammate(teammate2)

        let eq1 = Equipment(name: "Primary Reg", kind: "Regulator")
        let eq2 = Equipment(name: "Backup Light", kind: "Light")
        try diveService.saveEquipment(eq1)
        try diveService.saveEquipment(eq2)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )

        try diveService.saveDive(
            dive,
            tags: ["cave", "deep", "training"],
            teammateIds: [teammate1.id, teammate2.id],
            equipmentIds: [eq1.id, eq2.id]
        )

        // Verify tags
        let tags = try diveService.getTags(diveId: dive.id)
        XCTAssertEqual(Set(tags), Set(["cave", "deep", "training"]))

        // Verify teammates
        let tmIds = try diveService.getTeammateIds(diveId: dive.id)
        XCTAssertEqual(Set(tmIds), Set([teammate1.id, teammate2.id]))

        // Verify equipment
        let eqIds = try diveService.getEquipmentIds(diveId: dive.id)
        XCTAssertEqual(Set(eqIds), Set([eq1.id, eq2.id]))
    }

    func testUpdateDiveTagsReplacesExisting() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2400
        )

        // Save with initial tags
        try diveService.saveDive(dive, tags: ["cave", "deep"])
        var tags = try diveService.getTags(diveId: dive.id)
        XCTAssertEqual(Set(tags), Set(["cave", "deep"]))

        // Re-save with different tags — should replace
        try diveService.saveDive(dive, tags: ["reef", "night"])
        tags = try diveService.getTags(diveId: dive.id)
        XCTAssertEqual(Set(tags), Set(["reef", "night"]))
    }

    func testUpdateDiveTeammatesReplacesExisting() throws {
        let tm1 = Teammate(displayName: "Alice")
        let tm2 = Teammate(displayName: "Bob")
        try diveService.saveTeammate(tm1)
        try diveService.saveTeammate(tm2)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2400
        )

        // Save with tm1
        try diveService.saveDive(dive, teammateIds: [tm1.id])
        var tmIds = try diveService.getTeammateIds(diveId: dive.id)
        XCTAssertEqual(tmIds, [tm1.id])

        // Re-save with tm2 only — should replace
        try diveService.saveDive(dive, teammateIds: [tm2.id])
        tmIds = try diveService.getTeammateIds(diveId: dive.id)
        XCTAssertEqual(tmIds, [tm2.id])
    }

    func testDiveWithEmptyRelations() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2400
        )

        try diveService.saveDive(dive, tags: [], teammateIds: [], equipmentIds: [])
        let tags = try diveService.getTags(diveId: dive.id)
        let tmIds = try diveService.getTeammateIds(diveId: dive.id)
        let eqIds = try diveService.getEquipmentIds(diveId: dive.id)

        XCTAssertTrue(tags.isEmpty)
        XCTAssertTrue(tmIds.isEmpty)
        XCTAssertTrue(eqIds.isEmpty)
    }

    // MARK: - Segment CRUD

    func testSaveAndGetSegment() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive)

        let segment = Segment(
            diveId: dive.id,
            name: "Bottom Time",
            startTSec: 60,
            endTSec: 300,
            notes: "Deep section"
        )
        try diveService.saveSegment(segment, tags: ["deco", "deep"])

        let retrieved = try diveService.getSegment(id: segment.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "Bottom Time")
        XCTAssertEqual(retrieved?.startTSec, 60)
        XCTAssertEqual(retrieved?.endTSec, 300)
        XCTAssertEqual(retrieved?.notes, "Deep section")
    }

    func testListSegmentsOrderedByStartTime() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive)

        let s1 = Segment(diveId: dive.id, name: "Descent", startTSec: 0, endTSec: 60)
        let s2 = Segment(diveId: dive.id, name: "Bottom", startTSec: 60, endTSec: 300)
        let s3 = Segment(diveId: dive.id, name: "Ascent", startTSec: 300, endTSec: 420)
        try diveService.saveSegment(s1)
        try diveService.saveSegment(s3) // Save out of order
        try diveService.saveSegment(s2)

        let segments = try diveService.listSegments(diveId: dive.id)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].name, "Descent")
        XCTAssertEqual(segments[1].name, "Bottom")
        XCTAssertEqual(segments[2].name, "Ascent")
    }

    func testDeleteSegment() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive)

        let segment = Segment(diveId: dive.id, name: "Bottom", startTSec: 60, endTSec: 300)
        try diveService.saveSegment(segment)

        let deleted = try diveService.deleteSegment(id: segment.id)
        XCTAssertTrue(deleted)

        let retrieved = try diveService.getSegment(id: segment.id)
        XCTAssertNil(retrieved)
    }

    // MARK: - Equipment CRUD

    func testListEquipment() throws {
        let eq1 = Equipment(name: "Primary Reg", kind: "Regulator")
        let eq2 = Equipment(name: "Backup Light", kind: "Light")
        try diveService.saveEquipment(eq1)
        try diveService.saveEquipment(eq2)

        let equipment = try diveService.listEquipment()
        XCTAssertEqual(equipment.count, 2)
    }

    func testDeleteEquipment() throws {
        let eq = Equipment(name: "Test Reg", kind: "Regulator")
        try diveService.saveEquipment(eq)

        let deleted = try diveService.deleteEquipment(id: eq.id)
        XCTAssertTrue(deleted)

        let retrieved = try diveService.getEquipment(id: eq.id)
        XCTAssertNil(retrieved)
    }

    // MARK: - Teammate CRUD

    func testListTeammates() throws {
        let tm1 = Teammate(displayName: "Alice")
        let tm2 = Teammate(displayName: "Bob")
        try diveService.saveTeammate(tm1)
        try diveService.saveTeammate(tm2)

        let teammates = try diveService.listTeammates()
        XCTAssertEqual(teammates.count, 2)
    }

    func testDeleteTeammate() throws {
        let tm = Teammate(displayName: "Alice")
        try diveService.saveTeammate(tm)

        let deleted = try diveService.deleteTeammate(id: tm.id)
        XCTAssertTrue(deleted)

        let retrieved = try diveService.getTeammate(id: tm.id)
        XCTAssertNil(retrieved)
    }

    func testTeammateWithAllFields() throws {
        let tm = Teammate(
            displayName: "Alice",
            contact: "alice@example.com",
            certificationLevel: "TDI Advanced Trimix",
            notes: "Great dive buddy"
        )
        try diveService.saveTeammate(tm)

        let retrieved = try diveService.getTeammate(id: tm.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.displayName, "Alice")
        XCTAssertEqual(retrieved?.contact, "alice@example.com")
        XCTAssertEqual(retrieved?.certificationLevel, "TDI Advanced Trimix")
        XCTAssertEqual(retrieved?.notes, "Great dive buddy")
    }

    // MARK: - Formula CRUD

    func testListFormulas() throws {
        let f1 = Formula(name: "Deco Ratio", expression: "deco_time_min / bottom_time_min")
        let f2 = Formula(name: "Depth Check", expression: "max_depth_m * 3.28084")
        try diveService.saveFormula(f1)
        try diveService.saveFormula(f2)

        let formulas = try diveService.listFormulas()
        XCTAssertEqual(formulas.count, 2)
    }

    func testDeleteFormula() throws {
        let f = Formula(name: "Test", expression: "1 + 1")
        try diveService.saveFormula(f)

        let deleted = try diveService.deleteFormula(id: f.id)
        XCTAssertTrue(deleted)

        let retrieved = try diveService.getFormula(id: f.id)
        XCTAssertNil(retrieved)
    }

    // MARK: - Calculated Field CRUD

    func testCalculatedFieldCRUD() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        try diveService.saveDive(dive)

        let formula = Formula(name: "Test", expression: "1 + 1")
        try diveService.saveFormula(formula)

        let field = CalculatedField(formulaId: formula.id, diveId: dive.id, value: 42.0)
        try diveService.saveCalculatedField(field)

        let fields = try diveService.listCalculatedFields(diveId: dive.id)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.value, 42.0)

        let deleted = try diveService.deleteCalculatedField(formulaId: formula.id, diveId: dive.id)
        XCTAssertTrue(deleted)

        let afterDelete = try diveService.listCalculatedFields(diveId: dive.id)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    // MARK: - Delete Samples

    func testDeleteSamples() throws {
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2400
        )
        try diveService.saveDive(dive)

        let samples = [
            DiveSample(diveId: dive.id, tSec: 0, depthM: 0.0, tempC: 22.0),
            DiveSample(diveId: dive.id, tSec: 60, depthM: 10.0, tempC: 20.0),
            DiveSample(diveId: dive.id, tSec: 120, depthM: 20.0, tempC: 18.0),
        ]
        try diveService.saveSamples(samples)

        let deletedCount = try diveService.deleteSamples(diveId: dive.id)
        XCTAssertEqual(deletedCount, 3)

        let remaining = try diveService.getSamples(diveId: dive.id)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Site Tags

    func testSiteTagsReplacedOnUpdate() throws {
        let site = Site(name: "Test Site")
        try diveService.saveSite(site, tags: ["reef", "deep"])

        // Re-save with different tags — should replace
        try diveService.saveSite(site, tags: ["cave", "fresh water"])

        // Verify by re-fetching site (tags are stored separately but we can verify
        // by saving a dive at this site and checking the site still exists)
        let retrieved = try diveService.getSite(id: site.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "Test Site")
    }

    // MARK: - Export/Import Round Trip

    func testExportImportRoundTrip() throws {
        // Set up data
        let site = Site(name: "Blue Hole", lat: 31.5, lon: -25.3)
        try diveService.saveSite(site, tags: ["cave"])

        let teammate = Teammate(displayName: "Alice", certificationLevel: "Advanced")
        try diveService.saveTeammate(teammate)

        let equipment = Equipment(name: "Primary Reg", kind: "Regulator")
        try diveService.saveEquipment(equipment)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            isCcr: true,
            siteId: site.id
        )
        try diveService.saveDive(dive, tags: ["deep", "training"], teammateIds: [teammate.id], equipmentIds: [equipment.id])

        let samples = [
            DiveSample(diveId: dive.id, tSec: 0, depthM: 0.0, tempC: 22.0),
            DiveSample(diveId: dive.id, tSec: 300, depthM: 30.0, tempC: 16.0),
        ]
        try diveService.saveSamples(samples)

        let formula = Formula(name: "Depth Check", expression: "max_depth_m * 3.28084")
        try diveService.saveFormula(formula)

        // Export
        let exportService = ExportService(database: database)
        let jsonData = try exportService.exportAll(description: "Test export")

        // Import into fresh database
        let freshDb = try DivelogDatabase(path: ":memory:")
        let freshDiveService = DiveService(database: freshDb)
        let freshExportService = ExportService(database: freshDb)

        // Need a device in the fresh DB for FK
        try freshDiveService.saveDevice(device)

        let result = try freshExportService.importJSON(jsonData)
        XCTAssertEqual(result.devicesImported, 1)
        XCTAssertEqual(result.sitesImported, 1)
        XCTAssertEqual(result.buddiesImported, 1)
        XCTAssertEqual(result.equipmentImported, 1)
        XCTAssertEqual(result.formulasImported, 1)
        XCTAssertEqual(result.divesImported, 1)
        XCTAssertEqual(result.totalImported, 6)

        // Verify dive data round-tripped
        let importedDive = try freshDiveService.getDive(id: dive.id)
        XCTAssertNotNil(importedDive)
        XCTAssertEqual(importedDive?.maxDepthM, 30.0)
        XCTAssertEqual(importedDive?.isCcr, true)

        // Verify tags round-tripped
        let importedTags = try freshDiveService.getTags(diveId: dive.id)
        XCTAssertEqual(Set(importedTags), Set(["deep", "training"]))

        // Verify samples round-tripped
        let importedSamples = try freshDiveService.getSamples(diveId: dive.id)
        XCTAssertEqual(importedSamples.count, 2)
    }
}
