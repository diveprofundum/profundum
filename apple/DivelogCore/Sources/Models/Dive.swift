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
        siteId: String? = nil
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
    }
}

// MARK: - Associations

extension Dive {
    static let samples = hasMany(DiveSample.self)
    static let segments = hasMany(Segment.self)
    static let tags = hasMany(DiveTag.self)
    static let diveBuddies = hasMany(DiveBuddy.self)
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

/// Junction table for dive-buddy relationships.
public struct DiveBuddy: Equatable, Sendable {
    public var diveId: String
    public var buddyId: String

    public init(diveId: String, buddyId: String) {
        self.diveId = diveId
        self.buddyId = buddyId
    }
}

extension DiveBuddy: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dive_buddies"

    enum CodingKeys: String, CodingKey {
        case diveId = "dive_id"
        case buddyId = "buddy_id"
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
