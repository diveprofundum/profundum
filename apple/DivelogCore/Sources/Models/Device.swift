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

    public init(
        id: String = UUID().uuidString,
        model: String,
        serialNumber: String,
        firmwareVersion: String,
        lastSyncUnix: Int64? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.model = model
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
        self.lastSyncUnix = lastSyncUnix
        self.isActive = isActive
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
    }
}
