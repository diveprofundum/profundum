import Foundation

/// Cached DateFormatter instances to avoid repeated allocations during rendering.
///
/// Dive timestamps are stored as local time encoded in UTC epoch seconds
/// (both Shearwater Cloud and BLE imports record the dive computer's local
/// clock without timezone conversion). Using UTC here avoids a double-offset
/// that would otherwise shift displayed times by the device's timezone.
enum DateFormatters {
    /// Medium date + short time (e.g., "Feb 10, 2026, 3:45 PM") — used in dive list rows.
    static let mediumDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Full date + short time (e.g., "Monday, February 10, 2026 at 3:45 PM") — used in dive detail.
    static let fullDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
