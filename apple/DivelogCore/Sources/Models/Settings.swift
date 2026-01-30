import Foundation
import GRDB

/// Time format preference.
public enum TimeFormat: String, Codable, Sendable {
    case hhMmSs = "HhMmSs"
    case mmSs = "MmSs"
}

/// Application settings.
public struct Settings: Identifiable, Equatable, Sendable {
    public var id: String
    public var timeFormat: TimeFormat

    public init(id: String = "default", timeFormat: TimeFormat = .hhMmSs) {
        self.id = id
        self.timeFormat = timeFormat
    }
}

// MARK: - GRDB Conformance

extension Settings: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "settings"

    enum CodingKeys: String, CodingKey {
        case id
        case timeFormat = "time_format"
    }
}
