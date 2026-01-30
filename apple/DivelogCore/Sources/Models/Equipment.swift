import Foundation
import GRDB

/// Diving equipment item.
public struct Equipment: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var serialNumber: String?
    public var serviceIntervalDays: Int?
    public var notes: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: String,
        serialNumber: String? = nil,
        serviceIntervalDays: Int? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.serialNumber = serialNumber
        self.serviceIntervalDays = serviceIntervalDays
        self.notes = notes
    }
}

// MARK: - GRDB Conformance

extension Equipment: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "equipment"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case serialNumber = "serial_number"
        case serviceIntervalDays = "service_interval_days"
        case notes
    }
}
