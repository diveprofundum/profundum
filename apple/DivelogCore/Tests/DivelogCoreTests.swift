import XCTest
@testable import DivelogCore

final class DivelogCoreTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
    }

    // MARK: - Device Tests

    func testSaveAndGetDevice() throws {
        let device = Device(
            model: "Shearwater Perdix",
            serialNumber: "SN12345",
            firmwareVersion: "1.0.0"
        )

        try diveService.saveDevice(device)
        let retrieved = try diveService.getDevice(id: device.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.model, "Shearwater Perdix")
        XCTAssertEqual(retrieved?.serialNumber, "SN12345")
    }

    func testListDevices() throws {
        let device1 = Device(model: "Device 1", serialNumber: "SN1", firmwareVersion: "1.0")
        let device2 = Device(model: "Device 2", serialNumber: "SN2", firmwareVersion: "1.0")

        try diveService.saveDevice(device1)
        try diveService.saveDevice(device2)

        let devices = try diveService.listDevices()
        XCTAssertEqual(devices.count, 2)
    }

    func testDeleteDevice() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let deleted = try diveService.deleteDevice(id: device.id)
        XCTAssertTrue(deleted)

        let retrieved = try diveService.getDevice(id: device.id)
        XCTAssertNil(retrieved)
    }

    // MARK: - Buddy Tests

    func testSaveAndGetBuddy() throws {
        let buddy = Buddy(displayName: "John Doe", contact: "john@example.com")

        try diveService.saveBuddy(buddy)
        let retrieved = try diveService.getBuddy(id: buddy.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.displayName, "John Doe")
    }

    // MARK: - Site Tests

    func testSaveAndGetSite() throws {
        let site = Site(name: "Blue Hole", lat: 31.5, lon: -25.3, notes: "Great visibility")

        try diveService.saveSite(site, tags: ["cave", "deep"])
        let retrieved = try diveService.getSite(id: site.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "Blue Hole")
        XCTAssertEqual(retrieved?.lat, 31.5)
    }

    // MARK: - Dive Tests

    func testSaveAndGetDive() throws {
        // First create a device
        let device = Device(model: "Test Computer", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        // Create dive
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            isCcr: true,
            decoRequired: true,
            cnsPercent: 15.0,
            otu: 25.0
        )

        try diveService.saveDive(dive, tags: ["training", "deep"], buddyIds: [], equipmentIds: [])
        let retrieved = try diveService.getDive(id: dive.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.maxDepthM, 30.0)
        XCTAssertEqual(retrieved?.isCcr, true)
    }

    func testDiveQuery() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        // Create multiple dives
        let dive1 = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            isCcr: true
        )

        let dive2 = Dive(
            deviceId: device.id,
            startTimeUnix: 1700100000,
            endTimeUnix: 1700103600,
            maxDepthM: 15.0,
            avgDepthM: 10.0,
            bottomTimeSec: 2400,
            isCcr: false
        )

        try diveService.saveDive(dive1)
        try diveService.saveDive(dive2)

        // Query CCR only
        let ccrDives = try diveService.listDives(query: DiveQuery.ccrOnly())
        XCTAssertEqual(ccrDives.count, 1)
        XCTAssertEqual(ccrDives.first?.isCcr, true)

        // Query all
        let allDives = try diveService.listDives()
        XCTAssertEqual(allDives.count, 2)
    }

    // MARK: - Sample Tests

    func testSaveSamples() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

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
            DiveSample(diveId: dive.id, tSec: 60, depthM: 10.0, tempC: 20.0),
            DiveSample(diveId: dive.id, tSec: 120, depthM: 20.0, tempC: 18.0),
        ]

        try diveService.saveSamples(samples)
        let retrieved = try diveService.getSamples(diveId: dive.id)

        XCTAssertEqual(retrieved.count, 3)
        XCTAssertEqual(retrieved[0].tSec, 0)
        XCTAssertEqual(retrieved[1].depthM, 10.0)
    }

    // MARK: - Formula Tests

    func testSaveAndGetFormula() throws {
        let formula = Formula(
            name: "Deco Ratio",
            expression: "deco_time_min / bottom_time_min",
            description: "Ratio of deco to bottom time"
        )

        try diveService.saveFormula(formula)
        let retrieved = try diveService.getFormula(id: formula.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "Deco Ratio")
    }

    // MARK: - Formula Validation Tests

    func testValidateFormula() {
        let formulaService = FormulaService(database: database)

        // Valid formula
        XCTAssertNil(formulaService.validateFormula("1 + 2"))
        XCTAssertNil(formulaService.validateFormula("max_depth_m / 2"))

        // Invalid formula (empty)
        XCTAssertNotNil(formulaService.validateFormula(""))
    }

    // MARK: - Compute Tests

    func testComputeDiveStats() {
        let diveInput = DiveInput(
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            bottomTimeSec: 3000
        )

        let samples = [
            SampleInput(tSec: 0, depthM: 0.0, tempC: 22.0, setpointPpo2: nil, ceilingM: nil, gf99: nil),
            SampleInput(tSec: 60, depthM: 10.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil),
            SampleInput(tSec: 120, depthM: 30.0, tempC: 16.0, setpointPpo2: nil, ceilingM: nil, gf99: nil),
            SampleInput(tSec: 300, depthM: 30.0, tempC: 16.0, setpointPpo2: nil, ceilingM: nil, gf99: nil),
            SampleInput(tSec: 600, depthM: 0.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil),
        ]

        let stats = DivelogCompute.computeDiveStats(dive: diveInput, samples: samples)

        XCTAssertEqual(stats.maxDepthM, 30.0)
        XCTAssertEqual(stats.depthClass, .deep)
        XCTAssertEqual(stats.minTempC, 16.0)
        XCTAssertEqual(stats.maxTempC, 22.0)
    }

    func testComputeSegmentStats() {
        let samples = [
            SampleInput(tSec: 100, depthM: 10.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil),
            SampleInput(tSec: 200, depthM: 25.0, tempC: 18.0, setpointPpo2: nil, ceilingM: nil, gf99: nil),
            SampleInput(tSec: 300, depthM: 20.0, tempC: 19.0, setpointPpo2: nil, ceilingM: nil, gf99: nil),
            SampleInput(tSec: 400, depthM: 5.0, tempC: 21.0, setpointPpo2: nil, ceilingM: nil, gf99: nil),
        ]

        let stats = DivelogCompute.computeSegmentStats(startTSec: 100, endTSec: 300, samples: samples)

        XCTAssertEqual(stats.durationSec, 200)
        XCTAssertEqual(stats.maxDepthM, 25.0)
        XCTAssertEqual(stats.sampleCount, 3)
    }

    func testSupportedFunctions() {
        let functions = DivelogCompute.supportedFunctions()

        XCTAssertFalse(functions.isEmpty)

        let names = functions.map { $0.name }
        XCTAssertTrue(names.contains("min"))
        XCTAssertTrue(names.contains("max"))
        XCTAssertTrue(names.contains("round"))
    }
}
