import Foundation
import GRDB

/// A single sample point from a dive.
public struct DiveSample: Equatable, Sendable {
    public var diveId: String
    public var tSec: Int32
    public var depthM: Float
    public var tempC: Float
    public var setpointPpo2: Float?
    public var ceilingM: Float?
    public var gf99: Float?

    public init(
        diveId: String,
        tSec: Int32,
        depthM: Float,
        tempC: Float,
        setpointPpo2: Float? = nil,
        ceilingM: Float? = nil,
        gf99: Float? = nil
    ) {
        self.diveId = diveId
        self.tSec = tSec
        self.depthM = depthM
        self.tempC = tempC
        self.setpointPpo2 = setpointPpo2
        self.ceilingM = ceilingM
        self.gf99 = gf99
    }
}

// MARK: - GRDB Conformance

extension DiveSample: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "samples"

    enum CodingKeys: String, CodingKey {
        case diveId = "dive_id"
        case tSec = "t_sec"
        case depthM = "depth_m"
        case tempC = "temp_c"
        case setpointPpo2 = "setpoint_ppo2"
        case ceilingM = "ceiling_m"
        case gf99
    }
}

// MARK: - Associations

extension DiveSample {
    static let dive = belongsTo(Dive.self)
}
