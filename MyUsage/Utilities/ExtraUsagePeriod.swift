import Foundation

/// The window Claude's "extra usage" spend accumulates over.
///
/// The API reports the running total (`extra_usage.used_credits`) and nothing
/// else: no `resets_at`, no period bounds, and `daily` / `weekly` / `cap` /
/// `balance` / `auto_reload` all come back null. `/api/oauth/profile` carries
/// no billing-period field either. So the boundary has to be derived.
///
/// It is the **UTC calendar month**. Evidence:
///   - the cap field is literally named `monthly_limit`;
///   - the counter was observed at 6303 (\$63.03) late on 2026-07-31 and at 0
///     on 2026-08-01, i.e. it zeroed across the month boundary and not on the
///     subscription anniversary (2025-03-13);
///   - MyUsage's own ledger already buckets spend by UTC month
///     (`LedgerCalendar.monthKey`), and that rolled over at the same time.
///
/// This is an inference, not a documented contract. It is a safe one to act on:
/// if Anthropic ever moved the window to a billing anniversary, the countdown
/// would visibly disagree with the observed reset rather than fail silently.
enum ExtraUsagePeriod {

    /// Start (inclusive) and end (exclusive) of the period containing `now`.
    static func bounds(now: Date = .now) -> (start: Date, end: Date) {
        let start = LedgerCalendar.startOfMonthUTC(for: now)
        let end = LedgerCalendar.utc.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }

    /// A `UsageWindow` over the period, so extra usage reuses the same reset
    /// countdown, pace notch and projection machinery as every other limit
    /// instead of growing a parallel implementation.
    ///
    /// `percentUsed` is meaningful only when the account has a `monthly_limit`;
    /// callers without one use the window purely for its timing and feed the
    /// projection through `projectedSpend`.
    static func window(
        percentUsed: Double,
        now: Date = .now
    ) -> UsageWindow {
        let (start, end) = bounds(now: now)
        return UsageWindow(
            percentUsed: percentUsed,
            resetsAt: end,
            windowDuration: end.timeIntervalSince(start)
        )
    }

    /// Linear projection of where the month's spend lands at the current burn
    /// rate, in the same units as `spent`.
    ///
    /// Returns nil until enough of the month has elapsed for the rate to mean
    /// anything — the same reliability gate `UsageWindow` applies, which for a
    /// month is about six days. Without it, \$40 spent on the 1st would project
    /// to over \$1,200 and read as alarming when it is simply early.
    static func projectedSpend(
        spent: Double,
        now: Date = .now
    ) -> Double? {
        guard spent > 0 else { return nil }
        let (start, end) = bounds(now: now)
        let duration = end.timeIntervalSince(start)
        let elapsed = now.timeIntervalSince(start)
        guard duration > 0,
              elapsed >= max(60, duration * 0.20),
              elapsed <= duration
        else { return nil }
        return spent * duration / elapsed
    }
}
