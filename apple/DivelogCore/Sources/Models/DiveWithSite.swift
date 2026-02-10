import Foundation
import GRDB

/// A dive with its associated site name, loaded in a single query.
/// Used to avoid N+1 queries when displaying dive lists.
public struct DiveWithSite: Identifiable, Equatable, Hashable, Sendable {
    public let dive: Dive
    public let siteName: String?

    public var id: String { dive.id }

    public init(dive: Dive, siteName: String?) {
        self.dive = dive
        self.siteName = siteName
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(dive.id)
    }
}

// MARK: - GRDB Conformance

extension DiveWithSite: FetchableRecord {
    /// Initialize from a database row containing both dive and site columns.
    public init(row: Row) throws {
        dive = try Dive(row: row)
        // Site name comes from the joined sites table
        siteName = row["siteName"]
    }
}

// MARK: - Association Request

extension Dive {
    /// Request for fetching dives with their site names.
    static func withSiteRequest() -> QueryInterfaceRequest<DiveWithSite> {
        Dive
            .annotated(withOptional: Dive.site.select(Column("name").forKey("siteName")))
            .asRequest(of: DiveWithSite.self)
    }
}
