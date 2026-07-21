import Foundation

/// Pure computations behind the Overview summary tiles (Today / This month /
/// Next reset). Kept out of the view so every number the tiles show is unit-
/// testable with injected inputs — no ledger, no clock, no providers.
enum OverviewSummary {

    // MARK: - Cost aggregation

    /// Sum of every provider's ledger cost for today (UTC day bucket, same
    /// bucketing the ledger writes). 0 when no provider has a row today —
    /// a fresh day genuinely is $0 so far.
    static func todayTotal(
        dailyCosts: [ProviderKind: [LedgerStore.DailyCost]],
        now: Date = .now
    ) -> Double {
        let today = LedgerCalendar.dayKey(for: now)
        return dailyCosts.values.reduce(0) { acc, series in
            acc + series.filter { $0.day == today }.reduce(0) { $0 + $1.totalUSD }
        }
    }

    /// Mean daily cost across the `days` calendar days *before* today,
    /// summed over all providers. Days with no ledger row count as $0 —
    /// averaging only recorded days would inflate quiet weeks. nil when the
    /// window contains no data at all (fresh install): a delta against an
    /// empty baseline is meaningless.
    static func trailingDailyAverage(
        dailyCosts: [ProviderKind: [LedgerStore.DailyCost]],
        days: Int = 7,
        now: Date = .now
    ) -> Double? {
        guard days > 0 else { return nil }
        let window = Set((1...days).map {
            LedgerCalendar.dayKey(for: now.addingTimeInterval(Double(-$0) * 86_400))
        })
        var sum = 0.0
        var sawData = false
        for series in dailyCosts.values {
            for entry in series where window.contains(entry.day) {
                sum += entry.totalUSD
                sawData = true
            }
        }
        guard sawData else { return nil }
        return sum / Double(days)
    }

    /// Sum of every provider's total for one `YYYY-MM` month key. nil when
    /// the ledger has no rows for that month (distinct from a genuine $0 —
    /// for a *past* month, absence means "no history", and the tile should
    /// omit the comparison rather than claim last month cost $0.00).
    static func monthTotal(
        monthlyTotals: [String: [ProviderKind: Double]],
        monthKey: String
    ) -> Double? {
        guard let byProvider = monthlyTotals[monthKey], !byProvider.isEmpty else { return nil }
        return byProvider.values.reduce(0, +)
    }

    /// `YYYY-MM` key of the calendar month before the one containing `now`.
    static func previousMonthKey(now: Date = .now) -> String {
        let start = LedgerCalendar.startOfMonthUTC(for: now)
        return LedgerCalendar.monthKey(for: start.addingTimeInterval(-86_400))
    }

    /// "↑ 38% vs 7d avg" / "↓ 12% vs 7d avg" — or "13× 7d avg" once the
    /// ratio passes 4×: live data showed a heavy day over a quiet week
    /// rendering "↑1202% vs 7d avg", which is unreadable and blows out
    /// the tile. nil when the average is ~zero (no meaningful baseline).
    static func deltaCaption(today: Double, average: Double?) -> String? {
        guard let average, average > 0.005 else { return nil }
        let ratio = today / average
        if ratio >= 4 {
            return "\(Int(ratio.rounded()))× 7d avg"
        }
        let deltaPct = (today - average) / average * 100
        let arrow = deltaPct >= 0 ? "↑" : "↓"
        return "\(arrow) \(Int(abs(deltaPct).rounded()))% vs 7d avg"
    }

    /// One provider's trailing daily costs as a dense series (oldest →
    /// newest, ending today), with $0 filled in for days that have no
    /// ledger row — the sparkline shape is wrong if quiet days collapse
    /// out of the x-axis. nil when the whole window is empty (no line is
    /// better than a flat fake one).
    static func trailingDailySeries(
        series: [LedgerStore.DailyCost],
        days: Int = 14,
        now: Date = .now
    ) -> [Double]? {
        guard days > 0 else { return nil }
        let byDay = Dictionary(series.map { ($0.day, $0.totalUSD) }, uniquingKeysWith: +)
        var values: [Double] = []
        var sawData = false
        for offset in stride(from: days - 1, through: 0, by: -1) {
            let key = LedgerCalendar.dayKey(for: now.addingTimeInterval(Double(-offset) * 86_400))
            let usd = byDay[key] ?? 0
            if byDay[key] != nil { sawData = true }
            values.append(usd)
        }
        return sawData ? values : nil
    }

    /// Aggregate all providers into one dense trailing series for Overview.
    static func trailingDailySeries(
        dailyCosts: [ProviderKind: [LedgerStore.DailyCost]],
        days: Int = 14,
        now: Date = .now
    ) -> [Double]? {
        let combined = dailyCosts.values.flatMap { $0 }
        return trailingDailySeries(series: combined, days: days, now: now)
    }

    // MARK: - Next reset

    /// One reset candidate: a provider's window and when it unlocks.
    struct ResetCandidate {
        let providerName: String
        let windowLabel: String
        let resetsAt: Date?
    }

    struct NextReset: Equatable {
        let providerName: String
        let windowLabel: String
        let resetsAt: Date
    }

    /// The soonest future reset across all candidates — "which window
    /// unlocks next". Past dates are skipped (a reset that already happened
    /// isn't something to wait for; the next refresh clears it).
    static func nextReset(
        from candidates: [ResetCandidate],
        now: Date = .now
    ) -> NextReset? {
        candidates
            .compactMap { candidate -> NextReset? in
                guard let at = candidate.resetsAt, at > now else { return nil }
                return NextReset(
                    providerName: candidate.providerName,
                    windowLabel: candidate.windowLabel,
                    resetsAt: at
                )
            }
            .min { $0.resetsAt < $1.resetsAt }
    }

    /// Compact countdown for the tile value: `2h 14m`, `5d 12h`, `8m`.
    /// (No absolute clock time — the tile's sub-line carries the window
    /// identity instead; the per-card meta rows keep the full form.)
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
