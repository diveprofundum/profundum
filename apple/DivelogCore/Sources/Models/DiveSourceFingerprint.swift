import Foundation
import GRDB

/// Links a dive to a source fingerprint from a specific device.
/// A merged dive (from multiple computers) has multiple fingerprints.
public struct DiveSourceFingerprint: Identifiable, Equatable, Sendable {
    public var id: String
    public var diveId: String
    public var deviceId: String
    public var fingerprint: Data
    public var sourceType: String

    public init(
        id: String = UUID().uuidString,
        diveId: String,
        deviceId: String,
        fingerprint: Data,
        sourceType: String = "shearwater_cloud"
    ) {
        self.id = id
        self.diveId = diveId
        self.deviceId = deviceId
        self.fingerprint = fingerprint
        self.sourceType = sourceType
    }
}

// MARK: - GRDB Conformance

extension DiveSourceFingerprint: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dive_source_fingerprints"

    enum CodingKeys: String, CodingKey {
        case id
        case diveId = "dive_id"
        case deviceId = "device_id"
        case fingerprint
        case sourceType = "source_type"
    }
}
