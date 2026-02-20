import Foundation
import GRDB

/// A dive computer device.
public struct Device: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var model: String
    public var serialNumber: String
    public var firmwareVersion: String
    public var lastSyncUnix: Int64?
    /// Whether the device is active. Archived devices are kept for dive history provenance.
    public var isActive: Bool
    /// libdivecomputer vendor ID for device identification.
    public var vendorId: Int?
    /// libdivecomputer product ID for device identification.
    public var productId: Int?
    /// CoreBluetooth peripheral UUID for reconnection.
    public var bleUuid: String?
    /// Manufacturer name (e.g. "Shearwater"). Nullable for backwards compat.
    public var manufacturer: String?

    public init(
        id: String = UUID().uuidString,
        model: String,
        serialNumber: String,
        firmwareVersion: String,
        lastSyncUnix: Int64? = nil,
        isActive: Bool = true,
        vendorId: Int? = nil,
        productId: Int? = nil,
        bleUuid: String? = nil,
        manufacturer: String? = nil
    ) {
        self.id = id
        self.model = model
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
        self.lastSyncUnix = lastSyncUnix
        self.isActive = isActive
        self.vendorId = vendorId
        self.productId = productId
        self.bleUuid = bleUuid
        self.manufacturer = manufacturer
    }

    /// Model names that are placeholders and should be replaced by more specific values.
    public static let genericModelNames: Set<String> = [
        "Shearwater", "Shearwater (Unknown)", "Unknown Dive Computer", "Unknown"
    ]

    /// A human-readable name combining manufacturer and model when they differ.
    public var displayName: String {
        if let manufacturer, !manufacturer.isEmpty {
            if model.isEmpty {
                return manufacturer
            }
            if model != manufacturer, !model.hasPrefix(manufacturer) {
                return "\(manufacturer) \(model)"
            }
        }
        return model
    }

    /// Display name with serial number appended when available (e.g. "Petrel 3 (A31F4CE2)").
    public var detailDisplayName: String {
        serialNumber != "unknown"
            ? "\(displayName) (\(serialNumber))"
            : displayName
    }
}

// MARK: - GRDB Conformance

extension Device: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "devices"

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case serialNumber = "serial_number"
        case firmwareVersion = "firmware_version"
        case lastSyncUnix = "last_sync_unix"
        case isActive = "is_active"
        case vendorId = "vendor_id"
        case productId = "product_id"
        case bleUuid = "ble_uuid"
        case manufacturer
    }
}
