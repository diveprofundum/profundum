import Foundation
import GRDB

/// A dive site location.
public struct Site: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var lat: Double?
    public var lon: Double?
    public var notes: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        lat: Double? = nil,
        lon: Double? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.notes = notes
    }
}

// MARK: - GRDB Conformance

extension Site: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sites"
}

// MARK: - Associations

extension Site {
    static let tags = hasMany(SiteTag.self)

    /// Fetches tags for this site.
    public var tags: QueryInterfaceRequest<SiteTag> {
        request(for: Site.tags)
    }
}

/// A tag associated with a site.
public struct SiteTag: Equatable, Sendable {
    public var siteId: String
    public var tag: String

    public init(siteId: String, tag: String) {
        self.siteId = siteId
        self.tag = tag
    }
}

extension SiteTag: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "site_tags"

    enum CodingKeys: String, CodingKey {
        case siteId = "site_id"
        case tag
    }
}
