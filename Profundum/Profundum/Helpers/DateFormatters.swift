import Foundation

/// Cached DateFormatter instances to avoid repeated allocations during rendering.
enum DateFormatters {
    /// Medium date + short time (e.g., "Feb 10, 2026, 3:45 PM") — used in dive list rows.
    static let mediumDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Full date + short time (e.g., "Monday, February 10, 2026 at 3:45 PM") — used in dive detail.
    static let fullDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()
}
