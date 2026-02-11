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

    // MARK: - Teammate Tests

    func testSaveAndGetTeammate() throws {
        let teammate = Teammate(displayName: "John Doe", contact: "john@example.com", certificationLevel: "Advanced Open Water")

        try diveService.saveTeammate(teammate)
        let retrieved = try diveService.getTeammate(id: teammate.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.displayName, "John Doe")
        XCTAssertEqual(retrieved?.certificationLevel, "Advanced Open Water")
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

        try diveService.saveDive(dive, tags: ["training", "deep"], teammateIds: [], equipmentIds: [])
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
            SampleInput(tSec: 0, depthM: 0.0, tempC: 22.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil),
            SampleInput(tSec: 60, depthM: 10.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil),
            SampleInput(tSec: 120, depthM: 30.0, tempC: 16.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil),
            SampleInput(tSec: 300, depthM: 30.0, tempC: 16.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil),
            SampleInput(tSec: 600, depthM: 0.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil),
        ]

        let stats = DivelogCompute.computeDiveStats(dive: diveInput, samples: samples)

        XCTAssertEqual(stats.maxDepthM, 30.0)
        XCTAssertEqual(stats.depthClass, .deep)
        XCTAssertEqual(stats.minTempC, 16.0)
        XCTAssertEqual(stats.maxTempC, 22.0)
    }

    func testComputeSegmentStats() {
        let samples = [
            SampleInput(tSec: 100, depthM: 10.0, tempC: 20.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil),
            SampleInput(tSec: 200, depthM: 25.0, tempC: 18.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil),
            SampleInput(tSec: 300, depthM: 20.0, tempC: 19.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil),
            SampleInput(tSec: 400, depthM: 5.0, tempC: 21.0, setpointPpo2: nil, ceilingM: nil, gf99: nil, gasmixIndex: nil),
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

    // MARK: - Sample Data Tests

    func testHasSampleDataInitiallyFalse() throws {
        let sampleService = SampleDataService(database: database)
        XCTAssertFalse(try sampleService.hasSampleData())
    }

    func testLoadSampleData() throws {
        let sampleService = SampleDataService(database: database)

        // Initially empty
        XCTAssertFalse(try sampleService.hasSampleData())

        // Load sample data
        try sampleService.loadSampleData()

        // Now has data
        XCTAssertTrue(try sampleService.hasSampleData())

        // Check devices were created
        let devices = try diveService.listDevices(includeArchived: true)
        XCTAssertEqual(devices.count, 4)
        XCTAssertTrue(devices.contains { $0.model == "Shearwater Petrel 3" })
        XCTAssertTrue(devices.contains { $0.model == "Garmin Descent Mk2i" })

        // Check one device is archived
        let activeDevices = try diveService.listDevices(includeArchived: false)
        XCTAssertEqual(activeDevices.count, 3)

        // Check sites were created
        let sites = try diveService.listSites()
        XCTAssertEqual(sites.count, 4)
        XCTAssertTrue(sites.contains { $0.name == "Ginnie Springs - Ballroom" })

        // Check teammates were created
        let teammates = try diveService.listTeammates()
        XCTAssertEqual(teammates.count, 3)

        // Check dives were created
        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 5)

        // Check for CCR dives
        let ccrDives = try diveService.listDives(query: DiveQuery.ccrOnly())
        XCTAssertEqual(ccrDives.count, 2)

        // Check for deco dives
        let decoDives = try diveService.listDives(query: DiveQuery.decoOnly())
        XCTAssertEqual(decoDives.count, 1)
    }

    func testLoadSampleDataCreatesSamples() throws {
        let sampleService = SampleDataService(database: database)
        try sampleService.loadSampleData()

        // Get a dive and check it has samples
        let dives = try diveService.listDives()
        let dive = dives.first!

        let samples = try diveService.getSamples(diveId: dive.id)
        XCTAssertFalse(samples.isEmpty)

        // Samples should be ordered by time
        for i in 1..<samples.count {
            XCTAssertGreaterThan(samples[i].tSec, samples[i-1].tSec)
        }
    }

    func testClearAllData() throws {
        let sampleService = SampleDataService(database: database)

        // Load then clear
        try sampleService.loadSampleData()
        XCTAssertTrue(try sampleService.hasSampleData())

        try sampleService.clearAllData()
        XCTAssertFalse(try sampleService.hasSampleData())

        // Verify all tables are empty
        let devices = try diveService.listDevices(includeArchived: true)
        XCTAssertEqual(devices.count, 0)

        let dives = try diveService.listDives()
        XCTAssertEqual(dives.count, 0)
    }

    // MARK: - Device Archive Tests

    func testArchiveDevice() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        // Initially active
        var devices = try diveService.listDevices(includeArchived: false)
        XCTAssertEqual(devices.count, 1)

        // Archive it
        let archived = try diveService.archiveDevice(id: device.id)
        XCTAssertTrue(archived)

        // No longer in active list
        devices = try diveService.listDevices(includeArchived: false)
        XCTAssertEqual(devices.count, 0)

        // Still in full list
        devices = try diveService.listDevices(includeArchived: true)
        XCTAssertEqual(devices.count, 1)
        XCTAssertFalse(devices.first!.isActive)
    }

    func testRestoreDevice() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0", isActive: false)
        try diveService.saveDevice(device)

        // Initially archived
        var devices = try diveService.listDevices(includeArchived: false)
        XCTAssertEqual(devices.count, 0)

        // Restore it
        let restored = try diveService.restoreDevice(id: device.id)
        XCTAssertTrue(restored)

        // Now in active list
        devices = try diveService.listDevices(includeArchived: false)
        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices.first!.isActive)
    }

    // MARK: - Dive Computer Field Tests

    func testDeviceDiveComputerFields() throws {
        let device = Device(
            model: "Shearwater Perdix",
            serialNumber: "SN99",
            firmwareVersion: "2.0",
            vendorId: 0x1234,
            productId: 0x5678,
            bleUuid: "FE25C237-0ECE-443C-B0AA-E02033E7029D"
        )
        try diveService.saveDevice(device)

        let retrieved = try diveService.getDevice(id: device.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.vendorId, 0x1234)
        XCTAssertEqual(retrieved?.productId, 0x5678)
        XCTAssertEqual(retrieved?.bleUuid, "FE25C237-0ECE-443C-B0AA-E02033E7029D")
    }

    func testDeviceWithoutDiveComputerFields() throws {
        let device = Device(model: "Manual", serialNumber: "SN0", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let retrieved = try diveService.getDevice(id: device.id)
        XCTAssertNotNil(retrieved)
        XCTAssertNil(retrieved?.vendorId)
        XCTAssertNil(retrieved?.productId)
        XCTAssertNil(retrieved?.bleUuid)
    }

    func testDiveFingerprintRoundTrip() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let fingerprint = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 25.0,
            avgDepthM: 15.0,
            bottomTimeSec: 2400,
            computerDiveNumber: 42,
            fingerprint: fingerprint
        )

        try diveService.saveDive(dive)
        let retrieved = try diveService.getDive(id: dive.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.computerDiveNumber, 42)
        XCTAssertEqual(retrieved?.fingerprint, fingerprint)
    }

    // MARK: - Equipment Service Date Tests

    func testEquipmentWithServiceDate() throws {
        let lastService = Int64(Date().timeIntervalSince1970) - (30 * 24 * 3600) // 30 days ago
        let equipment = Equipment(
            name: "Primary Reg",
            kind: "Regulator",
            serviceIntervalDays: 365,
            lastServiceDate: lastService
        )
        try diveService.saveEquipment(equipment)

        let retrieved = try diveService.getEquipment(id: equipment.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "Primary Reg")
        XCTAssertEqual(retrieved?.serviceIntervalDays, 365)
        XCTAssertEqual(retrieved?.lastServiceDate, lastService)
    }

    func testEquipmentWithoutServiceDate() throws {
        let equipment = Equipment(
            name: "Backup Light",
            kind: "Light"
        )
        try diveService.saveEquipment(equipment)

        let retrieved = try diveService.getEquipment(id: equipment.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "Backup Light")
        XCTAssertNil(retrieved?.serviceIntervalDays)
        XCTAssertNil(retrieved?.lastServiceDate)
    }

    func testDiveWithoutFingerprint() throws {
        let device = Device(model: "Test", serialNumber: "SN", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000
        )

        try diveService.saveDive(dive)
        let retrieved = try diveService.getDive(id: dive.id)

        XCTAssertNotNil(retrieved)
        XCTAssertNil(retrieved?.computerDiveNumber)
        XCTAssertNil(retrieved?.fingerprint)
    }

    // MARK: - UnitFormatter Tests

    func testDepthConversion() {
        let meters: Float = 10.0
        let feet = UnitFormatter.depth(meters, unit: .feet)
        XCTAssertEqual(feet, 32.8084, accuracy: 0.01)

        // Identity
        XCTAssertEqual(UnitFormatter.depth(meters, unit: .meters), meters)
    }

    func testDepthRoundTrip() {
        let original: Float = 30.0
        let feet = UnitFormatter.depth(original, unit: .feet)
        let backToMeters = UnitFormatter.depthToMetric(feet, from: .feet)
        XCTAssertEqual(backToMeters, original, accuracy: 0.01)
    }

    func testTemperatureConversion() {
        let celsius: Float = 20.0
        let fahrenheit = UnitFormatter.temperature(celsius, unit: .fahrenheit)
        XCTAssertEqual(fahrenheit, 68.0, accuracy: 0.01)

        // Identity
        XCTAssertEqual(UnitFormatter.temperature(celsius, unit: .celsius), celsius)
    }

    func testTemperatureRoundTrip() {
        let original: Float = 16.0
        let fahrenheit = UnitFormatter.temperature(original, unit: .fahrenheit)
        let backToCelsius = UnitFormatter.temperatureToMetric(fahrenheit, from: .fahrenheit)
        XCTAssertEqual(backToCelsius, original, accuracy: 0.01)
    }

    func testPressureConversion() {
        let bar: Float = 200.0
        let psi = UnitFormatter.pressure(bar, unit: .psi)
        XCTAssertEqual(psi, 2900.76, accuracy: 0.1)

        // Identity
        XCTAssertEqual(UnitFormatter.pressure(bar, unit: .bar), bar)
    }

    func testFormatDepth() {
        XCTAssertEqual(UnitFormatter.formatDepth(30.0, unit: .meters), "30.0 m")
        XCTAssertEqual(UnitFormatter.formatDepth(10.0, unit: .feet), "32.8 ft")
    }

    func testFormatDepthCompact() {
        XCTAssertEqual(UnitFormatter.formatDepthCompact(30.0, unit: .meters), "30.0m")
        XCTAssertEqual(UnitFormatter.formatDepthCompact(10.0, unit: .feet), "32.8ft")
    }

    func testFormatTemperature() {
        XCTAssertEqual(UnitFormatter.formatTemperature(20.0, unit: .celsius), "20.0\u{00B0}C")
        XCTAssertEqual(UnitFormatter.formatTemperature(20.0, unit: .fahrenheit), "68.0\u{00B0}F")
    }

    func testUnitLabels() {
        XCTAssertEqual(UnitFormatter.depthLabel(.meters), "m")
        XCTAssertEqual(UnitFormatter.depthLabel(.feet), "ft")
        XCTAssertEqual(UnitFormatter.temperatureLabel(.celsius), "\u{00B0}C")
        XCTAssertEqual(UnitFormatter.temperatureLabel(.fahrenheit), "\u{00B0}F")
        XCTAssertEqual(UnitFormatter.pressureLabel(.bar), "bar")
        XCTAssertEqual(UnitFormatter.pressureLabel(.psi), "psi")
    }

    func testO2Formatting() {
        // PSI mode: uses cuft/min
        XCTAssertEqual(UnitFormatter.formatO2Rate(cuftMin: 0.45, lMin: 12.7, unit: .psi), "0.45 cuft/min")
        XCTAssertEqual(UnitFormatter.formatO2Consumed(psi: 1500, bar: 103, unit: .psi), "1500 psi")

        // Bar mode: uses l/min
        XCTAssertEqual(UnitFormatter.formatO2Rate(cuftMin: 0.45, lMin: 12.7, unit: .bar), "12.70 l/min")
        XCTAssertEqual(UnitFormatter.formatO2Consumed(psi: 1500, bar: 103, unit: .bar), "103 bar")

        // Nil values
        XCTAssertNil(UnitFormatter.formatO2Rate(cuftMin: nil, lMin: nil, unit: .psi))
        XCTAssertNil(UnitFormatter.formatO2Consumed(psi: nil, bar: nil, unit: .bar))
    }

    // MARK: - Imperial Formula Variables

    func testAddImperialVariables() {
        var vars: [String: Double] = [
            "max_depth_m": 30.0,
            "avg_depth_m": 18.0,
            "weighted_avg_depth_m": 20.0,
            "max_ceiling_m": 3.0,
            "min_temp_c": 16.0,
            "max_temp_c": 22.0,
            "avg_temp_c": 19.0,
        ]

        UnitFormatter.addImperialVariables(to: &vars)

        XCTAssertEqual(vars["max_depth_ft"]!, 30.0 * 3.28084, accuracy: 0.01)
        XCTAssertEqual(vars["avg_depth_ft"]!, 18.0 * 3.28084, accuracy: 0.01)
        XCTAssertEqual(vars["weighted_avg_depth_ft"]!, 20.0 * 3.28084, accuracy: 0.01)
        XCTAssertEqual(vars["max_ceiling_ft"]!, 3.0 * 3.28084, accuracy: 0.01)
        XCTAssertEqual(vars["min_temp_f"]!, 60.8, accuracy: 0.1)
        XCTAssertEqual(vars["max_temp_f"]!, 71.6, accuracy: 0.1)
        XCTAssertEqual(vars["avg_temp_f"]!, 66.2, accuracy: 0.1)

        // Original values unchanged
        XCTAssertEqual(vars["max_depth_m"], 30.0)
    }

    // MARK: - Settings Unit Persistence

    func testSettingsWithUnitPreferences() throws {
        let settings = Settings(
            depthUnit: .feet,
            temperatureUnit: .fahrenheit,
            pressureUnit: .psi
        )
        try diveService.saveSettings(settings)

        let loaded = try diveService.getSettings()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.depthUnit, .feet)
        XCTAssertEqual(loaded?.temperatureUnit, .fahrenheit)
        XCTAssertEqual(loaded?.pressureUnit, .psi)
    }

    func testSettingsDefaultsToMetric() throws {
        let settings = Settings()
        try diveService.saveSettings(settings)

        let loaded = try diveService.getSettings()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.depthUnit, .meters)
        XCTAssertEqual(loaded?.temperatureUnit, .celsius)
        XCTAssertEqual(loaded?.pressureUnit, .bar)
    }

    func testSettingsNullColumnsDefaultToMetric() throws {
        // Insert a row with NULL unit columns (simulating pre-migration data)
        try database.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO settings (id, time_format) VALUES ('test_null', 'HhMmSs')
            """)
        }

        let loaded = try database.dbQueue.read { db in
            try Settings.fetchOne(db, key: "test_null")
        }

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.depthUnit, .meters)
        XCTAssertEqual(loaded?.temperatureUnit, .celsius)
        XCTAssertEqual(loaded?.pressureUnit, .bar)
    }

    // MARK: - Batch Detail Loading

    func testGetDiveDetail() throws {
        let device = Device(model: "Detail Test", serialNumber: "DT01", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000,
            isCcr: true
        )
        try diveService.saveDive(dive, tags: ["deep", "ccr"], teammateIds: [], equipmentIds: [])

        // Add samples
        let samples = [
            DiveSample(diveId: dive.id, tSec: 0, depthM: 0.0, tempC: 22.0),
            DiveSample(diveId: dive.id, tSec: 60, depthM: 15.0, tempC: 20.0),
            DiveSample(diveId: dive.id, tSec: 120, depthM: 30.0, tempC: 18.0),
        ]
        try diveService.saveSamples(samples)

        // Add gas mixes
        try diveService.saveGasMixes([
            GasMix(diveId: dive.id, mixIndex: 0, o2Fraction: 0.21, heFraction: 0.35),
        ])

        // Add source fingerprint
        try diveService.saveSourceFingerprints([
            DiveSourceFingerprint(diveId: dive.id, deviceId: device.id, fingerprint: Data([0x01, 0x02]))
        ])

        let detail = try diveService.getDiveDetail(diveId: dive.id)

        XCTAssertEqual(detail.samples.count, 3)
        XCTAssertEqual(detail.tags.count, 2)
        XCTAssertTrue(detail.tags.contains("deep"))
        XCTAssertTrue(detail.tags.contains("ccr"))
        XCTAssertEqual(detail.gasMixes.count, 1)
        XCTAssertEqual(detail.gasMixes.first?.heFraction, 0.35)
        XCTAssertEqual(detail.sourceFingerprints.count, 1)
        XCTAssertEqual(detail.sourceDeviceNames.count, 1)
        XCTAssertTrue(detail.sourceDeviceNames.first?.contains("Detail Test") ?? false)
    }

    // MARK: - Export Tests

    func testExportDivesSubset() throws {
        let device = Device(model: "Export Test", serialNumber: "EX01", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive1 = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        )
        let dive2 = Dive(
            deviceId: device.id,
            startTimeUnix: 1700100000,
            endTimeUnix: 1700103600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000
        )
        try diveService.saveDive(dive1, tags: ["deep"], teammateIds: [], equipmentIds: [])
        try diveService.saveDive(dive2)

        // Add a sample for dive1
        try diveService.saveSamples([
            DiveSample(diveId: dive1.id, tSec: 0, depthM: 0.0, tempC: 22.0),
            DiveSample(diveId: dive1.id, tSec: 60, depthM: 30.0, tempC: 18.0),
        ])

        let exportService = ExportService(database: database)

        // Export only dive1
        let data = try exportService.exportDives(ids: [dive1.id])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ExportData.self, from: data)

        XCTAssertEqual(export.dives.count, 1)
        XCTAssertEqual(export.dives.first?.dive.id, dive1.id)
        XCTAssertEqual(export.dives.first?.tags, ["deep"])
        XCTAssertEqual(export.dives.first?.samples.count, 2)
        XCTAssertEqual(export.devices.count, 1)
    }

    func testExportDivesEmptyIdsExportsAll() throws {
        let device = Device(model: "Export All", serialNumber: "EA01", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        try diveService.saveDive(Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 30.0,
            avgDepthM: 18.0,
            bottomTimeSec: 3000
        ))
        try diveService.saveDive(Dive(
            deviceId: device.id,
            startTimeUnix: 1700100000,
            endTimeUnix: 1700103600,
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2000
        ))

        let exportService = ExportService(database: database)
        let data = try exportService.exportDives(ids: [])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ExportData.self, from: data)

        XCTAssertEqual(export.dives.count, 2)
    }

    func testExportDivesAsCSV() throws {
        let device = Device(model: "CSV Test", serialNumber: "CSV01", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let site = Site(name: "Blue Hole")
        try diveService.saveSite(site, tags: [])

        try diveService.saveDive(Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 40.0,
            avgDepthM: 25.0,
            bottomTimeSec: 2400,
            siteId: site.id,
            notes: "Great dive",
            minTempC: 16.0,
            maxTempC: 22.0
        ))

        let exportService = ExportService(database: database)
        let data = try exportService.exportDivesAsCSV(ids: [])
        let csv = String(data: data, encoding: .utf8)!

        // Check header
        XCTAssertTrue(csv.hasPrefix("date,site,max_depth_m,duration_min,bottom_time_min,min_temp_c,max_temp_c,is_ccr,deco_required,cns_percent,notes\n"))

        // Check that it has exactly 2 lines (header + 1 dive)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)

        // Check data row contains expected values
        let row = String(lines[1])
        XCTAssertTrue(row.contains("Blue Hole"))
        XCTAssertTrue(row.contains("40.0"))
        XCTAssertTrue(row.contains("16.0"))
        XCTAssertTrue(row.contains("22.0"))
        XCTAssertTrue(row.contains("Great dive"))
    }

    func testExportCSVEscapesCommas() throws {
        let device = Device(model: "CSV Escape", serialNumber: "CSE01", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let site = Site(name: "Blue Hole, Belize")
        try diveService.saveSite(site, tags: [])

        try diveService.saveDive(Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,
            maxDepthM: 40.0,
            avgDepthM: 25.0,
            bottomTimeSec: 2400,
            siteId: site.id
        ))

        let exportService = ExportService(database: database)
        let data = try exportService.exportDivesAsCSV(ids: [])
        let csv = String(data: data, encoding: .utf8)!

        XCTAssertTrue(csv.contains("\"Blue Hole, Belize\""))
    }

    // MARK: - Surface Interval

    func testSurfaceInterval() throws {
        let device = Device(model: "SI Test", serialNumber: "SI01", firmwareVersion: "1.0")
        try diveService.saveDevice(device)

        let dive1 = Dive(
            deviceId: device.id,
            startTimeUnix: 1700000000,
            endTimeUnix: 1700003600,     // ends at t+3600
            maxDepthM: 20.0,
            avgDepthM: 12.0,
            bottomTimeSec: 2400
        )
        let dive2 = Dive(
            deviceId: device.id,
            startTimeUnix: 1700007200,   // starts at t+7200 → SI = 7200 - 3600 = 3600
            endTimeUnix: 1700010800,
            maxDepthM: 15.0,
            avgDepthM: 10.0,
            bottomTimeSec: 2000
        )

        try diveService.saveDive(dive1)
        try diveService.saveDive(dive2)

        // Surface interval before dive2 should be 3600 seconds (1 hour)
        let si = try diveService.surfaceInterval(beforeDive: dive2)
        XCTAssertEqual(si, 3600)

        // First dive has no surface interval
        let siFirst = try diveService.surfaceInterval(beforeDive: dive1)
        XCTAssertNil(siFirst)
    }
}
