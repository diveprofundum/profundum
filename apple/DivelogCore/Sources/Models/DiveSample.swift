import Foundation
import GRDB

/// A single sample point from a dive.
public struct DiveSample: Identifiable, Equatable, Sendable {
    public var id: String
    public var diveId: String
    public var deviceId: String?
    public var tSec: Int32
    public var depthM: Float
    public var tempC: Float
    public var setpointPpo2: Float?
    public var ceilingM: Float?
    public var gf99: Float?
    public var ppo2_1: Float?
    public var ppo2_2: Float?
    public var ppo2_3: Float?
    public var cns: Float?
    public var tankPressure1Bar: Float?
    public var tankPressure2Bar: Float?
    public var ttsSec: Int?
    public var ndlSec: Int?
    public var decoStopDepthM: Float?
    public var rbtSec: Int?
    public var gasmixIndex: Int?
    public var atPlusFiveTtsMin: Int?

    /// Δ+5: projected change in TTS if diver stays 5 more minutes at current depth.
    /// Positive = accumulating deco, negative = clearing deco, nil = no data.
    public var deltaFiveTtsMin: Int? {
        guard let atPlusFive = atPlusFiveTtsMin else { return nil }
        guard let tts = ttsSec else { return atPlusFive }
        return atPlusFive - (tts / 60)
    }

    public init(
        id: String = UUID().uuidString,
        diveId: String,
        deviceId: String? = nil,
        tSec: Int32,
        depthM: Float,
        tempC: Float,
        setpointPpo2: Float? = nil,
        ceilingM: Float? = nil,
        gf99: Float? = nil,
        ppo2_1: Float? = nil,
        ppo2_2: Float? = nil,
        ppo2_3: Float? = nil,
        cns: Float? = nil,
        tankPressure1Bar: Float? = nil,
        tankPressure2Bar: Float? = nil,
        ttsSec: Int? = nil,
        ndlSec: Int? = nil,
        decoStopDepthM: Float? = nil,
        rbtSec: Int? = nil,
        gasmixIndex: Int? = nil,
        atPlusFiveTtsMin: Int? = nil
    ) {
        self.id = id
        self.diveId = diveId
        self.deviceId = deviceId
        self.tSec = tSec
        self.depthM = depthM
        self.tempC = tempC
        self.setpointPpo2 = setpointPpo2
        self.ceilingM = ceilingM
        self.gf99 = gf99
        self.ppo2_1 = ppo2_1
        self.ppo2_2 = ppo2_2
        self.ppo2_3 = ppo2_3
        self.cns = cns
        self.tankPressure1Bar = tankPressure1Bar
        self.tankPressure2Bar = tankPressure2Bar
        self.ttsSec = ttsSec
        self.ndlSec = ndlSec
        self.decoStopDepthM = decoStopDepthM
        self.rbtSec = rbtSec
        self.gasmixIndex = gasmixIndex
        self.atPlusFiveTtsMin = atPlusFiveTtsMin
    }
}

// MARK: - GRDB Conformance

extension DiveSample: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "samples"

    enum CodingKeys: String, CodingKey {
        case id
        case diveId = "dive_id"
        case deviceId = "device_id"
        case tSec = "t_sec"
        case depthM = "depth_m"
        case tempC = "temp_c"
        case setpointPpo2 = "setpoint_ppo2"
        case ceilingM = "ceiling_m"
        case gf99
        case ppo2_1
        case ppo2_2
        case ppo2_3
        case cns
        case tankPressure1Bar = "tank_pressure_1_bar"
        case tankPressure2Bar = "tank_pressure_2_bar"
        case ttsSec = "tts_sec"
        case ndlSec = "ndl_sec"
        case decoStopDepthM = "deco_stop_depth_m"
        case rbtSec = "rbt_sec"
        case gasmixIndex = "gasmix_index"
        case atPlusFiveTtsMin = "at_plus_five_tts_min"
    }
}

// MARK: - Associations

extension DiveSample {
    static let dive = belongsTo(Dive.self)
}
