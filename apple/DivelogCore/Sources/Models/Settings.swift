import Foundation
import GRDB

/// Time format preference.
public enum TimeFormat: String, Codable, Sendable {
    case hhMmSs = "HhMmSs"
    case mmSs = "MmSs"
}

/// Appearance mode preference.
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// Application settings.
public struct Settings: Identifiable, Equatable, Sendable {
    public var id: String
    public var timeFormat: TimeFormat
    public var depthUnit: DepthUnit
    public var temperatureUnit: TemperatureUnit
    public var pressureUnit: PressureUnit
    public var appearanceMode: AppearanceMode

    public init(
        id: String = "default",
        timeFormat: TimeFormat = .hhMmSs,
        depthUnit: DepthUnit = .meters,
        temperatureUnit: TemperatureUnit = .celsius,
        pressureUnit: PressureUnit = .bar,
        appearanceMode: AppearanceMode = .system
    ) {
        self.id = id
        self.timeFormat = timeFormat
        self.depthUnit = depthUnit
        self.temperatureUnit = temperatureUnit
        self.pressureUnit = pressureUnit
        self.appearanceMode = appearanceMode
    }
}

// MARK: - GRDB Conformance

extension Settings: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "settings"

    enum CodingKeys: String, CodingKey {
        case id
        case timeFormat = "time_format"
        case depthUnit = "depth_unit"
        case temperatureUnit = "temperature_unit"
        case pressureUnit = "pressure_unit"
        case appearanceMode = "appearance_mode"
    }
}

extension Settings: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timeFormat, forKey: .timeFormat)
        try container.encode(depthUnit, forKey: .depthUnit)
        try container.encode(temperatureUnit, forKey: .temperatureUnit)
        try container.encode(pressureUnit, forKey: .pressureUnit)
        try container.encode(appearanceMode, forKey: .appearanceMode)
    }
}

extension Settings: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        timeFormat = try container.decode(TimeFormat.self, forKey: .timeFormat)
        depthUnit = try container.decodeIfPresent(DepthUnit.self, forKey: .depthUnit) ?? .meters
        temperatureUnit = try container.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit) ?? .celsius
        pressureUnit = try container.decodeIfPresent(PressureUnit.self, forKey: .pressureUnit) ?? .bar
        appearanceMode = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? .system
    }
}
