import Foundation

// MARK: - Unit Enums

public enum DepthUnit: String, Codable, CaseIterable, Sendable {
    case meters
    case feet
}

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius
    case fahrenheit
}

public enum PressureUnit: String, Codable, CaseIterable, Sendable {
    case bar
    case psi
}

// MARK: - UnitFormatter

public enum UnitFormatter {

    // MARK: Conversion Constants

    private static let metersToFeet: Float = 3.28084
    private static let barToPsi: Float = 14.5038

    // MARK: Metric → Display

    public static func depth(_ meters: Float, unit: DepthUnit) -> Float {
        switch unit {
        case .meters: return meters
        case .feet: return meters * metersToFeet
        }
    }

    public static func temperature(_ celsius: Float, unit: TemperatureUnit) -> Float {
        switch unit {
        case .celsius: return celsius
        case .fahrenheit: return celsius * 9.0 / 5.0 + 32.0
        }
    }

    public static func pressure(_ bar: Float, unit: PressureUnit) -> Float {
        switch unit {
        case .bar: return bar
        case .psi: return bar * barToPsi
        }
    }

    // MARK: Display → Metric (for user input)

    public static func depthToMetric(_ value: Float, from unit: DepthUnit) -> Float {
        switch unit {
        case .meters: return value
        case .feet: return value / metersToFeet
        }
    }

    public static func temperatureToMetric(_ value: Float, from unit: TemperatureUnit) -> Float {
        switch unit {
        case .celsius: return value
        case .fahrenheit: return (value - 32.0) * 5.0 / 9.0
        }
    }

    // MARK: Formatted Strings

    public static func formatDepth(_ meters: Float, unit: DepthUnit, decimals: Int = 1) -> String {
        let converted = depth(meters, unit: unit)
        return String(format: "%.\(decimals)f %@", converted, depthLabel(unit))
    }

    public static func formatDepthCompact(_ meters: Float, unit: DepthUnit) -> String {
        let converted = depth(meters, unit: unit)
        return String(format: "%.1f%@", converted, depthLabel(unit))
    }

    public static func formatTemperature(_ celsius: Float, unit: TemperatureUnit, decimals: Int = 1) -> String {
        let converted = temperature(celsius, unit: unit)
        return String(format: "%.\(decimals)f%@", converted, temperatureLabel(unit))
    }

    // MARK: O2 Formatting (selects stored field based on preference)

    public static func formatO2Rate(cuftMin: Float?, lMin: Float?, unit: PressureUnit) -> String? {
        switch unit {
        case .psi:
            guard let rate = cuftMin else { return nil }
            return String(format: "%.2f cuft/min", rate)
        case .bar:
            guard let rate = lMin else { return nil }
            return String(format: "%.2f l/min", rate)
        }
    }

    public static func formatO2Consumed(psi: Float?, bar: Float?, unit: PressureUnit) -> String? {
        switch unit {
        case .psi:
            guard let consumed = psi else { return nil }
            return String(format: "%.0f psi", consumed)
        case .bar:
            guard let consumed = bar else { return nil }
            return String(format: "%.0f bar", consumed)
        }
    }

    // MARK: Unit Labels

    public static func depthLabel(_ unit: DepthUnit) -> String {
        switch unit {
        case .meters: return "m"
        case .feet: return "ft"
        }
    }

    public static func temperatureLabel(_ unit: TemperatureUnit) -> String {
        switch unit {
        case .celsius: return "\u{00B0}C"
        case .fahrenheit: return "\u{00B0}F"
        }
    }

    public static func pressureLabel(_ unit: PressureUnit) -> String {
        switch unit {
        case .bar: return "bar"
        case .psi: return "psi"
        }
    }

    // MARK: Imperial Formula Variables

    /// Adds imperial equivalents to a metric variable dictionary for formula evaluation.
    public static func addImperialVariables(to variables: inout [String: Double]) {
        // Depth conversions (m → ft)
        let depthKeys = ["max_depth", "avg_depth", "weighted_avg_depth", "max_ceiling"]
        for key in depthKeys {
            if let metricValue = variables["\(key)_m"] {
                variables["\(key)_ft"] = metricValue * Double(metersToFeet)
            }
        }

        // Temperature conversions (C → F)
        let tempKeys = ["min_temp", "max_temp", "avg_temp"]
        for key in tempKeys {
            if let celsius = variables["\(key)_c"] {
                variables["\(key)_f"] = celsius * 9.0 / 5.0 + 32.0
            }
        }
    }
}
