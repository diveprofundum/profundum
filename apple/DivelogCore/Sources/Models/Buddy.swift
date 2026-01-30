import Foundation
import GRDB

/// A dive buddy (diving partner).
public struct Buddy: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var contact: String?
    public var notes: String?

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        contact: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.contact = contact
        self.notes = notes
    }
}

// MARK: - GRDB Conformance

extension Buddy: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "buddies"

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case contact
        case notes
    }
}
