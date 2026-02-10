import Foundation
import GRDB

/// A dive teammate (diving partner).
public struct Teammate: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var contact: String?
    public var certificationLevel: String?
    public var notes: String?

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        contact: String? = nil,
        certificationLevel: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.contact = contact
        self.certificationLevel = certificationLevel
        self.notes = notes
    }
}

// MARK: - GRDB Conformance

extension Teammate: Codable, FetchableRecord, PersistableRecord {
    // Keep table name as "buddies" for backwards compatibility
    public static let databaseTableName = "buddies"

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case contact
        case certificationLevel = "certification_level"
        case notes
    }
}

// MARK: - Type Alias for Migration

/// Alias for backwards compatibility during transition
@available(*, deprecated, renamed: "Teammate")
public typealias Buddy = Teammate
