import Foundation
import GRDB

/// Per-computer deco and environment settings for a multi-device dive.
public struct DiveDeviceSettings: Equatable, Sendable {
    public var diveId: String
    public var deviceId: String
    public var gfLow: Int?
    public var gfHigh: Int?
    public var decoModel: String?
    public var salinity: String?
    public var surfacePressureBar: Float?
    public var isPrimary: Bool

    public init(
        diveId: String,
        deviceId: String,
        gfLow: Int? = nil,
        gfHigh: Int? = nil,
        decoModel: String? = nil,
        salinity: String? = nil,
        surfacePressureBar: Float? = nil,
        isPrimary: Bool = false
    ) {
        self.diveId = diveId
        self.deviceId = deviceId
        self.gfLow = gfLow
        self.gfHigh = gfHigh
        self.decoModel = decoModel
        self.salinity = salinity
        self.surfacePressureBar = surfacePressureBar
        self.isPrimary = isPrimary
    }
}

// MARK: - GRDB Conformance

extension DiveDeviceSettings: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dive_device_settings"

    enum CodingKeys: String, CodingKey {
        case diveId = "dive_id"
        case deviceId = "device_id"
        case gfLow = "gf_low"
        case gfHigh = "gf_high"
        case decoModel = "deco_model"
        case salinity
        case surfacePressureBar = "surface_pressure_bar"
        case isPrimary = "is_primary"
    }
}

// MARK: - Import Helpers

extension DiveDeviceSettings {
    /// Inserts or replaces per-device settings from a parsed dive computer import.
    static func upsert(
        diveId: String,
        deviceId: String,
        gfLow: Int?,
        gfHigh: Int?,
        decoModel: String?,
        salinity: String?,
        surfacePressureBar: Float?,
        isPrimary: Bool,
        db: Database
    ) throws {
        let settings = DiveDeviceSettings(
            diveId: diveId,
            deviceId: deviceId,
            gfLow: gfLow,
            gfHigh: gfHigh,
            decoModel: decoModel,
            salinity: salinity,
            surfacePressureBar: surfacePressureBar,
            isPrimary: isPrimary
        )
        try settings.insert(db, onConflict: .replace)
    }

    /// Creates a per-device settings row when missing (re-import backfill).
    static func backfillIfMissing(
        diveId: String,
        deviceId: String,
        gfLow: Int?,
        gfHigh: Int?,
        decoModel: String?,
        salinity: String?,
        surfacePressureBar: Float?,
        isPrimary: Bool,
        db: Database
    ) throws {
        let exists = try Self
            .filter(Column("dive_id") == diveId)
            .filter(Column("device_id") == deviceId)
            .fetchCount(db) > 0
        guard !exists else { return }
        try upsert(
            diveId: diveId,
            deviceId: deviceId,
            gfLow: gfLow,
            gfHigh: gfHigh,
            decoModel: decoModel,
            salinity: salinity,
            surfacePressureBar: surfacePressureBar,
            isPrimary: isPrimary,
            db: db
        )
    }
}
