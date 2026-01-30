import Foundation
import GRDB

/// A segment (portion) of a dive for analysis.
public struct Segment: Identifiable, Equatable, Sendable {
    public var id: String
    public var diveId: String
    public var name: String
    public var startTSec: Int32
    public var endTSec: Int32
    public var notes: String?

    public init(
        id: String = UUID().uuidString,
        diveId: String,
        name: String,
        startTSec: Int32,
        endTSec: Int32,
        notes: String? = nil
    ) {
        self.id = id
        self.diveId = diveId
        self.name = name
        self.startTSec = startTSec
        self.endTSec = endTSec
        self.notes = notes
    }
}

// MARK: - GRDB Conformance

extension Segment: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "segments"

    enum CodingKeys: String, CodingKey {
        case id
        case diveId = "dive_id"
        case name
        case startTSec = "start_t_sec"
        case endTSec = "end_t_sec"
        case notes
    }
}

// MARK: - Associations

extension Segment {
    static let dive = belongsTo(Dive.self)
    static let tags = hasMany(SegmentTag.self)

    /// Fetch all tags for this segment.
    public var tags: QueryInterfaceRequest<SegmentTag> {
        request(for: Segment.tags)
    }
}

/// A tag associated with a segment.
public struct SegmentTag: Equatable, Sendable {
    public var segmentId: String
    public var tag: String

    public init(segmentId: String, tag: String) {
        self.segmentId = segmentId
        self.tag = tag
    }
}

extension SegmentTag: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "segment_tags"

    enum CodingKeys: String, CodingKey {
        case segmentId = "segment_id"
        case tag
    }
}
