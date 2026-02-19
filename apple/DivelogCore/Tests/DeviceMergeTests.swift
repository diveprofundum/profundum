import XCTest
@testable import DivelogCore

final class DeviceMergeTests: XCTestCase {
    var database: DivelogDatabase!
    var diveService: DiveService!

    override func setUp() async throws {
        database = try DivelogDatabase(path: ":memory:")
        diveService = DiveService(database: database)
    }

    // MARK: - displayName

    func testDisplayNameManufacturerAndModel() {
        let device = Device(model: "Petrel 3", serialNumber: "SN1", firmwareVersion: "",
                            manufacturer: "Shearwater")
        XCTAssertEqual(device.displayName, "Shearwater Petrel 3")
    }

    func testDisplayNameModelEqualsManufacturer() {
        let device = Device(model: "Shearwater", serialNumber: "SN1", firmwareVersion: "",
                            manufacturer: "Shearwater")
        XCTAssertEqual(device.displayName, "Shearwater")
    }

    func testDisplayNameModelPrefixedByManufacturer() {
        let device = Device(model: "Shearwater Petrel 3", serialNumber: "SN1", firmwareVersion: "",
                            manufacturer: "Shearwater")
        XCTAssertEqual(device.displayName, "Shearwater Petrel 3")
    }

    func testDisplayNameNilManufacturer() {
        let device = Device(model: "Perdix", serialNumber: "SN1", firmwareVersion: "")
        XCTAssertEqual(device.displayName, "Perdix")
    }

    func testDisplayNameEmptyManufacturer() {
        let device = Device(model: "Perdix", serialNumber: "SN1", firmwareVersion: "",
                            manufacturer: "")
        XCTAssertEqual(device.displayName, "Perdix")
    }

    func testDisplayNameEmptyModelFallsBackToManufacturer() {
        let device = Device(model: "", serialNumber: "SN1", firmwareVersion: "",
                            manufacturer: "Shearwater")
        XCTAssertEqual(device.displayName, "Shearwater")
    }

    func testDisplayNameBothEmpty() {
        let device = Device(model: "", serialNumber: "SN1", firmwareVersion: "",
                            manufacturer: "")
        XCTAssertEqual(device.displayName, "")
    }

    // MARK: - findDeviceBySerial

    func testFindDeviceBySerial() throws {
        let device = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                            firmwareVersion: "", manufacturer: "Shearwater")
        try diveService.saveDevice(device)

        let found = try diveService.findDeviceBySerial("A31F4CE2")
        XCTAssertEqual(found?.id, device.id)
    }

    func testFindDeviceBySerialExcludesEmpty() throws {
        let device = Device(model: "Unknown", serialNumber: "", firmwareVersion: "")
        try diveService.saveDevice(device)

        XCTAssertNil(try diveService.findDeviceBySerial(""))
    }

    func testFindDeviceBySerialExcludesUnknown() throws {
        let device = Device(model: "Unknown", serialNumber: "unknown", firmwareVersion: "")
        try diveService.saveDevice(device)

        XCTAssertNil(try diveService.findDeviceBySerial("unknown"))
    }

    func testFindDeviceBySerialExcludesArchived() throws {
        let device = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                            firmwareVersion: "", isActive: false)
        try diveService.saveDevice(device)

        XCTAssertNil(try diveService.findDeviceBySerial("A31F4CE2"))
    }

    func testFindDeviceBySerialWithExcludingId() throws {
        let device1 = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                             firmwareVersion: "", manufacturer: "Shearwater")
        let device2 = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                             firmwareVersion: "", bleUuid: "BLE-123")
        try diveService.saveDevice(device1)
        try diveService.saveDevice(device2)

        // Excluding device2 should return device1
        let found = try diveService.findDeviceBySerial("A31F4CE2", excludingId: device2.id)
        XCTAssertEqual(found?.id, device1.id)

        // Excluding device1 should return device2
        let found2 = try diveService.findDeviceBySerial("A31F4CE2", excludingId: device1.id)
        XCTAssertEqual(found2?.id, device2.id)
    }

    // MARK: - mergeDevices

    func testMergeDevicesReassignsDives() throws {
        let cloudDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                                 firmwareVersion: "", manufacturer: "Shearwater")
        let bleDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                               firmwareVersion: "1.2.3", bleUuid: "BLE-UUID")
        try diveService.saveDevice(cloudDevice)
        try diveService.saveDevice(bleDevice)

        // Create a dive owned by the BLE device
        let dive = Dive(deviceId: bleDevice.id, startTimeUnix: 1000, endTimeUnix: 2000,
                        maxDepthM: 30, avgDepthM: 20, bottomTimeSec: 1000,
                        isCcr: false, decoRequired: false)
        try diveService.saveDive(dive)

        let merged = try diveService.mergeDevices(winnerId: cloudDevice.id, loserId: bleDevice.id)
        XCTAssertTrue(merged)

        // Dive should now belong to cloud device
        let updatedDive = try diveService.getDive(id: dive.id)
        XCTAssertEqual(updatedDive?.deviceId, cloudDevice.id)

        // Loser should be archived with bleUuid cleared
        let loser = try diveService.getDevice(id: bleDevice.id)
        XCTAssertEqual(loser?.isActive, false)
        XCTAssertNil(loser?.bleUuid)

        // Winner should have inherited bleUuid and firmware
        let winner = try diveService.getDevice(id: cloudDevice.id)
        XCTAssertEqual(winner?.bleUuid, "BLE-UUID")
        XCTAssertEqual(winner?.firmwareVersion, "1.2.3")
    }

    func testMergeDevicesAdoptsSpecificModel() throws {
        let cloudDevice = Device(model: "Shearwater", serialNumber: "A31F4CE2",
                                 firmwareVersion: "", manufacturer: "Shearwater")
        let bleDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                               firmwareVersion: "", bleUuid: "BLE-UUID")
        try diveService.saveDevice(cloudDevice)
        try diveService.saveDevice(bleDevice)

        try diveService.mergeDevices(winnerId: cloudDevice.id, loserId: bleDevice.id)

        let winner = try diveService.getDevice(id: cloudDevice.id)
        XCTAssertEqual(winner?.model, "Petrel 3")
    }

    func testMergeDevicesKeepsSpecificModelOnWinner() throws {
        let cloudDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                                 firmwareVersion: "", manufacturer: "Shearwater")
        let bleDevice = Device(model: "Unknown Dive Computer", serialNumber: "A31F4CE2",
                               firmwareVersion: "", bleUuid: "BLE-UUID")
        try diveService.saveDevice(cloudDevice)
        try diveService.saveDevice(bleDevice)

        try diveService.mergeDevices(winnerId: cloudDevice.id, loserId: bleDevice.id)

        let winner = try diveService.getDevice(id: cloudDevice.id)
        XCTAssertEqual(winner?.model, "Petrel 3")
    }

    func testMergeDevicesSelfMergeReturnsFalse() throws {
        let device = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                            firmwareVersion: "", bleUuid: "BLE-UUID")
        try diveService.saveDevice(device)

        let result = try diveService.mergeDevices(winnerId: device.id, loserId: device.id)
        XCTAssertFalse(result)

        // Device should be unchanged
        let fetched = try diveService.getDevice(id: device.id)
        XCTAssertEqual(fetched?.isActive, true)
        XCTAssertEqual(fetched?.bleUuid, "BLE-UUID")
    }

    func testMergeDevicesNotFoundReturnsFalse() throws {
        let device = Device(model: "Petrel 3", serialNumber: "SN1", firmwareVersion: "")
        try diveService.saveDevice(device)

        let result = try diveService.mergeDevices(winnerId: device.id, loserId: "nonexistent")
        XCTAssertFalse(result)
    }

    func testMergeDevicesInheritsManufacturer() throws {
        let cloudDevice = Device(model: "Unknown", serialNumber: "A31F4CE2",
                                 firmwareVersion: "")
        let bleDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                               firmwareVersion: "", manufacturer: "Shearwater")
        try diveService.saveDevice(cloudDevice)
        try diveService.saveDevice(bleDevice)

        try diveService.mergeDevices(winnerId: cloudDevice.id, loserId: bleDevice.id)

        let winner = try diveService.getDevice(id: cloudDevice.id)
        XCTAssertEqual(winner?.manufacturer, "Shearwater")
        XCTAssertEqual(winner?.model, "Petrel 3")
    }

    // MARK: - Freshness-sensitive merge fields

    func testMergeDevicesOverwritesWinnerBleUuid() throws {
        let cloudDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                                 firmwareVersion: "1.0", bleUuid: "OLD-UUID",
                                 manufacturer: "Shearwater")
        let bleDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                               firmwareVersion: "1.2.3", bleUuid: "NEW-UUID")
        try diveService.saveDevice(cloudDevice)
        try diveService.saveDevice(bleDevice)

        try diveService.mergeDevices(winnerId: cloudDevice.id, loserId: bleDevice.id)

        let winner = try diveService.getDevice(id: cloudDevice.id)
        // Loser's bleUuid should overwrite winner's stale value
        XCTAssertEqual(winner?.bleUuid, "NEW-UUID")
        // Loser's firmware should overwrite winner's older version
        XCTAssertEqual(winner?.firmwareVersion, "1.2.3")
    }

    func testMergeDevicesKeepsWinnerBleUuidWhenLoserEmpty() throws {
        let cloudDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                                 firmwareVersion: "", bleUuid: "EXISTING-UUID",
                                 manufacturer: "Shearwater")
        let bleDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                               firmwareVersion: "")
        try diveService.saveDevice(cloudDevice)
        try diveService.saveDevice(bleDevice)

        try diveService.mergeDevices(winnerId: cloudDevice.id, loserId: bleDevice.id)

        let winner = try diveService.getDevice(id: cloudDevice.id)
        XCTAssertEqual(winner?.bleUuid, "EXISTING-UUID")
    }

    func testMergeDevicesTakesNewerLastSyncUnix() throws {
        let cloudDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                                 firmwareVersion: "", lastSyncUnix: 1000,
                                 manufacturer: "Shearwater")
        let bleDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                               firmwareVersion: "", lastSyncUnix: 2000,
                               bleUuid: "BLE-UUID")
        try diveService.saveDevice(cloudDevice)
        try diveService.saveDevice(bleDevice)

        try diveService.mergeDevices(winnerId: cloudDevice.id, loserId: bleDevice.id)

        let winner = try diveService.getDevice(id: cloudDevice.id)
        XCTAssertEqual(winner?.lastSyncUnix, 2000)
    }

    func testMergeDevicesKeepsWinnerLastSyncWhenNewer() throws {
        let cloudDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                                 firmwareVersion: "", lastSyncUnix: 3000,
                                 manufacturer: "Shearwater")
        let bleDevice = Device(model: "Petrel 3", serialNumber: "A31F4CE2",
                               firmwareVersion: "", lastSyncUnix: 1000,
                               bleUuid: "BLE-UUID")
        try diveService.saveDevice(cloudDevice)
        try diveService.saveDevice(bleDevice)

        try diveService.mergeDevices(winnerId: cloudDevice.id, loserId: bleDevice.id)

        let winner = try diveService.getDevice(id: cloudDevice.id)
        XCTAssertEqual(winner?.lastSyncUnix, 3000)
    }

    // MARK: - genericModelNames

    func testGenericModelNamesCoversAllPlaceholders() {
        let expected: Set<String> = [
            "Shearwater", "Shearwater (Unknown)", "Unknown Dive Computer", "Unknown"
        ]
        XCTAssertEqual(Device.genericModelNames, expected)
    }
}
