import Foundation
import GRDB

/// Query builder for filtering and paginating dives.
public struct DiveQuery: Sendable {
    public var startTimeMin: Int64?
    public var startTimeMax: Int64?
    public var minDepthM: Float?
    public var maxDepthM: Float?
    public var isCcr: Bool?
    public var decoRequired: Bool?
    public var tagAny: [String]
    public var siteId: String?
    public var buddyId: String?
    public var limit: Int?
    public var offset: Int?

    public init(
        startTimeMin: Int64? = nil,
        startTimeMax: Int64? = nil,
        minDepthM: Float? = nil,
        maxDepthM: Float? = nil,
        isCcr: Bool? = nil,
        decoRequired: Bool? = nil,
        tagAny: [String] = [],
        siteId: String? = nil,
        buddyId: String? = nil,
        limit: Int? = 50,
        offset: Int? = nil
    ) {
        self.startTimeMin = startTimeMin
        self.startTimeMax = startTimeMax
        self.minDepthM = minDepthM
        self.maxDepthM = maxDepthM
        self.isCcr = isCcr
        self.decoRequired = decoRequired
        self.tagAny = tagAny
        self.siteId = siteId
        self.buddyId = buddyId
        self.limit = limit
        self.offset = offset
    }

    /// Build a GRDB request from this query.
    public func request() -> QueryInterfaceRequest<Dive> {
        var request = Dive.all()

        // Time range filter
        if let min = startTimeMin {
            request = request.filter(Column("start_time_unix") >= min)
        }
        if let max = startTimeMax {
            request = request.filter(Column("start_time_unix") <= max)
        }

        // Depth filter
        if let min = minDepthM {
            request = request.filter(Column("max_depth_m") >= min)
        }
        if let max = maxDepthM {
            request = request.filter(Column("max_depth_m") <= max)
        }

        // Boolean filters
        if let ccr = isCcr {
            request = request.filter(Column("is_ccr") == ccr)
        }
        if let deco = decoRequired {
            request = request.filter(Column("deco_required") == deco)
        }

        // Site filter
        if let siteId {
            request = request.filter(Column("site_id") == siteId)
        }

        // Buddy filter (via join)
        if let buddyId {
            request = request.joining(required: Dive.diveBuddies.filter(Column("buddy_id") == buddyId))
        }

        // Tag filter (any of the tags)
        if !tagAny.isEmpty {
            request = request.joining(required: Dive.tags.filter(tagAny.contains(Column("tag"))))
        }

        // Sort by date descending (most recent first)
        request = request.order(Column("start_time_unix").desc)

        // Pagination
        if let limit {
            request = request.limit(limit, offset: offset ?? 0)
        }

        return request
    }
}

// MARK: - Convenience Extensions

extension DiveQuery {
    /// Query for recent dives.
    public static func recent(limit: Int = 50) -> DiveQuery {
        DiveQuery(limit: limit)
    }

    /// Query for CCR dives only.
    public static func ccrOnly(limit: Int = 50) -> DiveQuery {
        DiveQuery(isCcr: true, limit: limit)
    }

    /// Query for dives requiring decompression.
    public static func decoOnly(limit: Int = 50) -> DiveQuery {
        DiveQuery(decoRequired: true, limit: limit)
    }

    /// Query for dives at a specific site.
    public static func atSite(_ siteId: String, limit: Int = 50) -> DiveQuery {
        DiveQuery(siteId: siteId, limit: limit)
    }

    /// Query for dives with a specific buddy.
    public static func withBuddy(_ buddyId: String, limit: Int = 50) -> DiveQuery {
        DiveQuery(buddyId: buddyId, limit: limit)
    }

    /// Query for dives with any of the specified tags.
    public static func withTags(_ tags: [String], limit: Int = 50) -> DiveQuery {
        DiveQuery(tagAny: tags, limit: limit)
    }
}
