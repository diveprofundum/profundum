import Foundation
import GRDB

/// A dive record with all metadata.
public struct Dive: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var deviceId: String
    public var startTimeUnix: Int64
    public var endTimeUnix: Int64
    public var maxDepthM: Float
    public var avgDepthM: Float
    public var bottomTimeSec: Int32
    public var isCcr: Bool
    public var decoRequired: Bool
    public var cnsPercent: Float
    public var otu: Float
    public var o2ConsumedPsi: Float?
    public var o2ConsumedBar: Float?
    public var o2RateCuftMin: Float?
    public var o2RateLMin: Float?
    public var o2TankFactor: Float?
    public var siteId: String?
    /// Dive number as reported by the dive computer.
    public var computerDiveNumber: Int?
    /// Fingerprint blob from the dive computer, used for deduplication.
    /// Deprecated: use `dive_source_fingerprints` table instead. Kept for backwards compat.
    public var fingerprint: Data?
    public var notes: String?
    public var minTempC: Float?
    public var maxTempC: Float?
    public var avgTempC: Float?
    public var endGf99: Float?
    public var gfLow: Int?
    public var gfHigh: Int?
    public var decoModel: String?
    public var salinity: String?
    public var surfacePressureBar: Float?
    public var lat: Double?
    public var lon: Double?
    public var groupId: String?
    public var environment: String?
    public var maxCeilingM: Float?
    public var visibility: String?
    public var weather: String?

    public init(
        id: String = UUID().uuidString,
        deviceId: String,
        startTimeUnix: Int64,
        endTimeUnix: Int64,
        maxDepthM: Float,
        avgDepthM: Float,
        bottomTimeSec: Int32,
        isCcr: Bool = false,
        decoRequired: Bool = false,
        cnsPercent: Float = 0,
        otu: Float = 0,
        o2ConsumedPsi: Float? = nil,
        o2ConsumedBar: Float? = nil,
        o2RateCuftMin: Float? = nil,
        o2RateLMin: Float? = nil,
        o2TankFactor: Float? = nil,
        siteId: String? = nil,
        computerDiveNumber: Int? = nil,
        fingerprint: Data? = nil,
        notes: String? = nil,
        minTempC: Float? = nil,
        maxTempC: Float? = nil,
        avgTempC: Float? = nil,
        endGf99: Float? = nil,
        gfLow: Int? = nil,
        gfHigh: Int? = nil,
        decoModel: String? = nil,
        salinity: String? = nil,
        surfacePressureBar: Float? = nil,
        lat: Double? = nil,
        lon: Double? = nil,
        groupId: String? = nil,
        maxCeilingM: Float? = nil,
        environment: String? = nil,
        visibility: String? = nil,
        weather: String? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.startTimeUnix = startTimeUnix
        self.endTimeUnix = endTimeUnix
        self.maxDepthM = maxDepthM
        self.avgDepthM = avgDepthM
        self.bottomTimeSec = bottomTimeSec
        self.isCcr = isCcr
        self.decoRequired = decoRequired
        self.cnsPercent = cnsPercent
        self.otu = otu
        self.o2ConsumedPsi = o2ConsumedPsi
        self.o2ConsumedBar = o2ConsumedBar
        self.o2RateCuftMin = o2RateCuftMin
        self.o2RateLMin = o2RateLMin
        self.o2TankFactor = o2TankFactor
        self.siteId = siteId
        self.computerDiveNumber = computerDiveNumber
        self.fingerprint = fingerprint
        self.notes = notes
        self.minTempC = minTempC
        self.maxTempC = maxTempC
        self.avgTempC = avgTempC
        self.endGf99 = endGf99
        self.gfLow = gfLow
        self.gfHigh = gfHigh
        self.decoModel = decoModel
        self.salinity = salinity
        self.surfacePressureBar = surfacePressureBar
        self.lat = lat
        self.lon = lon
        self.groupId = groupId
        self.maxCeilingM = maxCeilingM
        self.environment = environment
        self.visibility = visibility
        self.weather = weather
    }
}

// MARK: - GRDB Conformance

extension Dive: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dives"

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case startTimeUnix = "start_time_unix"
        case endTimeUnix = "end_time_unix"
        case maxDepthM = "max_depth_m"
        case avgDepthM = "avg_depth_m"
        case bottomTimeSec = "bottom_time_sec"
        case isCcr = "is_ccr"
        case decoRequired = "deco_required"
        case cnsPercent = "cns_percent"
        case otu
        case o2ConsumedPsi = "o2_consumed_psi"
        case o2ConsumedBar = "o2_consumed_bar"
        case o2RateCuftMin = "o2_rate_cuft_min"
        case o2RateLMin = "o2_rate_l_min"
        case o2TankFactor = "o2_tank_factor"
        case siteId = "site_id"
        case computerDiveNumber = "computer_dive_number"
        case fingerprint
        case notes
        case minTempC = "min_temp_c"
        case maxTempC = "max_temp_c"
        case avgTempC = "avg_temp_c"
        case endGf99 = "end_gf99"
        case gfLow = "gf_low"
        case gfHigh = "gf_high"
        case decoModel = "deco_model"
        case salinity
        case surfacePressureBar = "surface_pressure_bar"
        case lat
        case lon
        case groupId = "group_id"
        case maxCeilingM = "max_ceiling_m"
        case environment
        case visibility
        case weather
    }
}

// MARK: - Associations

extension Dive {
    static let samples = hasMany(DiveSample.self)
    static let segments = hasMany(Segment.self)
    static let tags = hasMany(DiveTag.self)
    static let diveTeammates = hasMany(DiveTeammate.self)
    static let diveEquipment = hasMany(DiveEquipment.self)
    static let device = belongsTo(Device.self)
    static let site = belongsTo(Site.self)

    /// Fetch all samples for this dive.
    public var samples: QueryInterfaceRequest<DiveSample> {
        request(for: Dive.samples)
    }

    /// Fetch all segments for this dive.
    public var segments: QueryInterfaceRequest<Segment> {
        request(for: Dive.segments)
    }

    /// Fetch all tags for this dive.
    public var tags: QueryInterfaceRequest<DiveTag> {
        request(for: Dive.tags)
    }
}

/// A tag associated with a dive.
public struct DiveTag: Equatable, Sendable {
    public var diveId: String
    public var tag: String

    public init(diveId: String, tag: String) {
        self.diveId = diveId
        self.tag = tag
    }
}

extension DiveTag: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dive_tags"

    enum CodingKeys: String, CodingKey {
        case diveId = "dive_id"
        case tag
    }
}

/// Junction table for dive-teammate relationships.
public struct DiveTeammate: Equatable, Sendable {
    public var diveId: String
    public var teammateId: String

    public init(diveId: String, teammateId: String) {
        self.diveId = diveId
        self.teammateId = teammateId
    }
}

extension DiveTeammate: Codable, FetchableRecord, PersistableRecord {
    // Keep table name as "dive_buddies" for backwards compatibility
    public static let databaseTableName = "dive_buddies"

    enum CodingKeys: String, CodingKey {
        case diveId = "dive_id"
        case teammateId = "buddy_id"  // Column name kept for backwards compatibility
    }
}

/// Junction table for dive-equipment relationships.
public struct DiveEquipment: Equatable, Sendable {
    public var diveId: String
    public var equipmentId: String

    public init(diveId: String, equipmentId: String) {
        self.diveId = diveId
        self.equipmentId = equipmentId
    }
}

extension DiveEquipment: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dive_equipment"

    enum CodingKeys: String, CodingKey {
        case diveId = "dive_id"
        case equipmentId = "equipment_id"
    }
}
