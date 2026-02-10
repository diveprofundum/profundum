import Foundation
import GRDB

/// A gas mix used during a dive (e.g., air, nitrox, trimix).
public struct GasMix: Identifiable, Equatable, Sendable {
    public var id: String
    public var diveId: String
    public var mixIndex: Int
    public var o2Fraction: Float
    public var heFraction: Float
    public var usage: String?  // "none", "oxygen", "diluent", "sidemount"

    public init(
        id: String = UUID().uuidString,
        diveId: String,
        mixIndex: Int,
        o2Fraction: Float,
        heFraction: Float,
        usage: String? = nil
    ) {
        self.id = id
        self.diveId = diveId
        self.mixIndex = mixIndex
        self.o2Fraction = o2Fraction
        self.heFraction = heFraction
        self.usage = usage
    }
}

// MARK: - GRDB Conformance

extension GasMix: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "gas_mixes"

    enum CodingKeys: String, CodingKey {
        case id
        case diveId = "dive_id"
        case mixIndex = "mix_index"
        case o2Fraction = "o2_fraction"
        case heFraction = "he_fraction"
        case usage
    }
}
