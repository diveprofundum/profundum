import DivelogCore
import Foundation

/// Cached DateFormatter instances for dive time display.
///
/// Two timestamp conventions coexist:
/// - **Legacy (nil offset)**: local time encoded as UTC epoch seconds. Formatters
///   use UTC timezone to avoid double-offset.
/// - **Real UTC (non-nil offset)**: `Dive.displayStartDate` adds the offset,
///   converting back to local-as-UTC so these same UTC formatters produce
///   correct local times.
enum DateFormatters {

    // MARK: - Locale helpers

    /// Locale with hour cycle forced to 12-hour.
    private static let locale12h: Locale = {
        var components = Locale.Components(locale: .current)
        components.hourCycle = .oneToTwelve
        return Locale(components: components)
    }()

    /// Locale with hour cycle forced to 24-hour.
    private static let locale24h: Locale = {
        var components = Locale.Components(locale: .current)
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }()

    // MARK: - System (follows device 12/24h setting)

    /// Medium date + short time — used in dive list rows.
    private static let mediumSystem: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Full date + short time — used in dive detail.
    private static let fullSystem: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - 12-hour

    private static let medium12h: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale12h
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let full12h: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale12h
        f.dateStyle = .full
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - 24-hour

    private static let medium24h: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale24h
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let full24h: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale24h
        f.dateStyle = .full
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Public API

    static func mediumDateTime(clock: ClockFormat) -> DateFormatter {
        switch clock {
        case .system: return mediumSystem
        case .twelveHour: return medium12h
        case .twentyFourHour: return medium24h
        }
    }

    static func fullDateTime(clock: ClockFormat) -> DateFormatter {
        switch clock {
        case .system: return fullSystem
        case .twelveHour: return full12h
        case .twentyFourHour: return full24h
        }
    }
}
