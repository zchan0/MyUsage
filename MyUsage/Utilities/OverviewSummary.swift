import Foundation

/// Shared reset countdown used by the current provider overview and details.
enum OverviewSummary {
    /// Compact duration: `2h 14m`, `5d 12h`, `8m`, or `now` after reset.
    static func shortCountdown(until date: Date, now: Date = .now) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "now" }
        let totalMinutes = Int(interval) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
