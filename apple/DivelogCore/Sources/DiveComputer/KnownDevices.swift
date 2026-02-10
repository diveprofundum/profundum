import Foundation

/// Registry of known BLE-capable dive computers and their characteristic UUIDs.
public enum KnownDiveComputer: String, CaseIterable, Sendable {
    case shearwater
    case hwOstc
    case suuntoEon
    case garminDescent
    case maresGenius

    /// The BLE service UUID used to discover this device.
    public var serviceUUID: String {
        switch self {
        case .shearwater:    return "FE25C237-0ECE-443C-B0AA-E02033E7029D"
        case .hwOstc:        return "0000FEFB-0000-1000-8000-00805F9B34FB"
        case .suuntoEon:     return "98AE7120-E62E-11E3-BADD-0002A5D5C51B"
        case .garminDescent: return "6A4E2401-667B-11E3-949A-0800200C9A66"
        case .maresGenius:   return "CB3C4000-B2E0-4F77-8576-40470BCCE600"
        }
    }

    /// The BLE characteristic UUID used for data transfer.
    public var characteristicUUID: String {
        switch self {
        case .shearwater:    return "27B7570B-359E-45A3-91BB-CF7E70049BD2"
        case .hwOstc:        return "00000001-0000-1000-8000-00805F9B34FB"
        case .suuntoEon:     return "98AE7121-E62E-11E3-BADD-0002A5D5C51B"
        case .garminDescent: return "6A4E2403-667B-11E3-949A-0800200C9A66"
        case .maresGenius:   return "CB3C4002-B2E0-4F77-8576-40470BCCE600"
        }
    }

    /// Human-readable vendor name for UI display.
    public var vendorName: String {
        switch self {
        case .shearwater:    return "Shearwater"
        case .hwOstc:        return "Heinrichs Weikamp"
        case .suuntoEon:     return "Suunto"
        case .garminDescent: return "Garmin"
        case .maresGenius:   return "Mares"
        }
    }

    /// All service UUIDs to pass to `CBCentralManager.scanForPeripherals`.
    public static var allServiceUUIDs: [String] {
        allCases.map(\.serviceUUID)
    }

    /// Look up a known device by its advertised service UUID.
    public static func from(serviceUUID uuid: String) -> KnownDiveComputer? {
        let upper = uuid.uppercased()
        return allCases.first { $0.serviceUUID.uppercased() == upper }
    }
}
