import Foundation

/// Registry of known BLE-capable dive computers and their characteristic UUIDs.
public enum KnownDiveComputer: String, CaseIterable, Sendable {
    case shearwater
    case hwOstc
    case suuntoEon
    case garminDescent
    case maresGenius
    case halcyonSymbios

    /// The BLE service UUID used to discover this device during scanning.
    public var serviceUUID: String {
        switch self {
        case .shearwater:      return "FE25C237-0ECE-443C-B0AA-E02033E7029D"
        case .hwOstc:          return "0000FEFB-0000-1000-8000-00805F9B34FB"
        case .suuntoEon:       return "98AE7120-E62E-11E3-BADD-0002A5D5C51B"
        case .garminDescent:   return "6A4E2401-667B-11E3-949A-0800200C9A66"
        case .maresGenius:     return "CB3C4000-B2E0-4F77-8576-40470BCCE600"
        case .halcyonSymbios:  return "18424398-7CBC-11E9-8F9E-2A86E4087070"
        }
    }

    /// The BLE characteristic UUID used for reading data (Rx).
    ///
    /// For most devices this is also used for writes. For devices with separate
    /// Rx/Tx characteristics (e.g. Halcyon Symbios), use `writeCharacteristicUUID`
    /// for writes.
    public var characteristicUUID: String {
        switch self {
        case .shearwater:      return "27B7570B-359E-45A3-91BB-CF7E70049BD2"
        case .hwOstc:          return "00000001-0000-1000-8000-00805F9B34FB"
        case .suuntoEon:       return "98AE7121-E62E-11E3-BADD-0002A5D5C51B"
        case .garminDescent:   return "6A4E2403-667B-11E3-949A-0800200C9A66"
        case .maresGenius:     return "CB3C4002-B2E0-4F77-8576-40470BCCE600"
        case .halcyonSymbios:  return "00000101-8C3B-4F2C-A59E-8C08224F3253"
        }
    }

    /// Human-readable vendor name for UI display.
    public var vendorName: String {
        switch self {
        case .shearwater:      return "Shearwater"
        case .hwOstc:          return "Heinrichs Weikamp"
        case .suuntoEon:       return "Suunto"
        case .garminDescent:   return "Garmin"
        case .maresGenius:     return "Mares"
        case .halcyonSymbios:  return "Halcyon"
        }
    }

    /// The GATT service UUID used for data transfer after connection, when it
    /// differs from the advertised `serviceUUID` used during scanning.
    ///
    /// Most devices use the same UUID for both scanning and communication.
    /// Halcyon Symbios advertises one UUID but exposes a different data service.
    /// Returns `nil` for devices where `serviceUUID` is used for both.
    public var dataServiceUUID: String? {
        switch self {
        case .halcyonSymbios:  return "00000001-8C3B-4F2C-A59E-8C08224F3253"
        default:               return nil
        }
    }

    /// A separate BLE characteristic UUID used for writing (Tx), when the device
    /// uses distinct Rx and Tx characteristics.
    ///
    /// Most devices use a single bidirectional characteristic. Halcyon Symbios
    /// uses separate Rx (`characteristicUUID`) and Tx characteristics.
    /// Returns `nil` for devices that use `characteristicUUID` for both.
    public var writeCharacteristicUUID: String? {
        switch self {
        case .halcyonSymbios:  return "00000201-8C3B-4F2C-A59E-8C08224F3253"
        default:               return nil
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
