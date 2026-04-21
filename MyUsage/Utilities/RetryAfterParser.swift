import Foundation

/// Parses the HTTP `Retry-After` header (RFC 7231 §7.1.3).
///
/// The header can be either:
/// - A non-negative integer number of seconds (e.g. `"30"`), or
/// - An HTTP-date (e.g. `"Wed, 21 Oct 2026 07:28:00 GMT"`).
enum RetryAfterParser {
    /// Returns the delay in seconds from `now`, or `nil` if the value can't be
    /// parsed or resolves to a time in the past.
    static func seconds(from value: String, now: Date = .now) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let integer = TimeInterval(trimmed), integer >= 0 {
            return integer
        }

        if let date = httpDateFormatter.date(from: trimmed) {
            let delta = date.timeIntervalSince(now)
            return delta > 0 ? delta : 0
        }

        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
