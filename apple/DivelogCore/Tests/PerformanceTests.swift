import XCTest
@testable import DivelogCore

final class PerformanceTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
    }

    // MARK: - Helpers

    private func createDevice() throws -> Device {
        let device = Device(model: "Bench Device", serialNumber: "BN01", firmwareVersion: "1.0")
        try diveService.saveDevice(device)
        return device
    }

    private func createDive(deviceId: String, index: Int) throws -> Dive {
        let dive = Dive(
            deviceId: deviceId,
            startTimeUnix: 1700000000 + Int64(index * 7200),
            endTimeUnix: 1700003600 + Int64(index * 7200),
            maxDepthM: Float.random(in: 10...60),
            avgDepthM: Float.random(in: 5...30),
            bottomTimeSec: Int32.random(in: 1200...3600),
            isCcr: index % 3 == 0,
            decoRequired: index % 2 == 0,
            cnsPercent: Float.random(in: 0...50),
            otu: Float.random(in: 0...40)
        )
        try diveService.saveDive(dive, tags: ["perf-test"], teammateIds: [], equipmentIds: [])
        return dive
    }

    private func createSamples(diveId: String, count: Int) throws {
        var samples: [DiveSample] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            samples.append(DiveSample(
                diveId: diveId,
                tSec: Int32(i * 10),
                depthM: Float.random(in: 0...40),
                tempC: Float.random(in: 10...25),
                setpointPpo2: 1.3,
                ceilingM: Float.random(in: 0...3),
                gf99: Float.random(in: 0...100)
            ))
        }
        try diveService.saveSamples(samples)
    }

    // MARK: - Benchmarks

    func testListDivesPerformance_100Dives() throws {
        let device = try createDevice()
        for i in 0..<100 {
            _ = try createDive(deviceId: device.id, index: i)
        }

        measure {
            _ = try? diveService.listDivesWithSites()
        }
    }

    func testSaveSamplesPerformance_1000Samples() throws {
        let device = try createDevice()
        let dive = try createDive(deviceId: device.id, index: 0)

        var samples: [DiveSample] = []
        for i in 0..<1000 {
            samples.append(DiveSample(
                diveId: dive.id,
                tSec: Int32(i * 2),
                depthM: Float.random(in: 0...40),
                tempC: Float.random(in: 10...25)
            ))
        }

        measure {
            _ = try? diveService.deleteSamples(diveId: dive.id)
            try? diveService.saveSamples(samples)
        }
    }

    func testGetDiveDetailPerformance() throws {
        let device = try createDevice()
        let dive = try createDive(deviceId: device.id, index: 0)
        try createSamples(diveId: dive.id, count: 500)

        // Add gas mixes
        try diveService.saveGasMixes([
            GasMix(diveId: dive.id, mixIndex: 0, o2Fraction: 0.21, heFraction: 0.35),
            GasMix(diveId: dive.id, mixIndex: 1, o2Fraction: 0.50, heFraction: 0),
            GasMix(diveId: dive.id, mixIndex: 2, o2Fraction: 1.0, heFraction: 0),
        ])

        measure {
            _ = try? diveService.getDiveDetail(diveId: dive.id)
        }
    }

    func testExportPerformance_50Dives() throws {
        let device = try createDevice()
        for i in 0..<50 {
            let dive = try createDive(deviceId: device.id, index: i)
            try createSamples(diveId: dive.id, count: 100)
        }

        let exportService = ExportService(database: database)

        measure {
            _ = try? exportService.exportAll()
        }
    }

    func testFormulaEvaluationPerformance() throws {
        let device = try createDevice()
        let dive = try createDive(deviceId: device.id, index: 0)
        try createSamples(diveId: dive.id, count: 1000)

        let formulaService = FormulaService(database: database)

        measure {
            _ = try? formulaService.evaluateFormulaForDive(
                "max_depth_m * bottom_time_min + cns_percent",
                diveId: dive.id
            )
        }
    }
}
