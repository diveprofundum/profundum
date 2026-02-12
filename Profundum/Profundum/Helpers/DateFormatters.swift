import DivelogCore
import Foundation

/// Cached DateFormatter instances for dive time display.
///
/// Dive timestamps are stored as local time encoded in UTC epoch seconds
/// (both Shearwater Cloud and BLE imports record the dive computer's local
/// clock without timezone conversion). Using UTC here avoids a double-offset
/// that would otherwise shift displayed times by the device's timezone.
enum DateFormatters {

    // MARK: - System (follows device 12/24h setting)

    /// Medium date + short time — used in dive list rows.
    static let mediumSystem: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Full date + short time — used in dive detail.
    static let fullSystem: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - 12-hour

    private static let medium12h: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        let template = DateFormatter.dateFormat(
            fromTemplate: "MMMdyyyyhmma", options: 0, locale: .current
        )
        f.dateFormat = template
        return f
    }()

    private static let full12h: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        let template = DateFormatter.dateFormat(
            fromTemplate: "EEEEMMMMdyyyyhmma", options: 0, locale: .current
        )
        f.dateFormat = template
        return f
    }()

    // MARK: - 24-hour

    private static let medium24h: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        let template = DateFormatter.dateFormat(
            fromTemplate: "MMMdyyyyHHmm", options: 0, locale: .current
        )
        f.dateFormat = template
        return f
    }()

    private static let full24h: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        let template = DateFormatter.dateFormat(
            fromTemplate: "EEEEMMMMdyyyyHHmm", options: 0, locale: .current
        )
        f.dateFormat = template
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
