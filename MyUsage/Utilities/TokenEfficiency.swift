import Foundation

/// Derived readings over token usage, for the popover's Token efficiency
/// section.
///
/// Raw counters (total / input / output / cache) describe the same shape every
/// day — for an agentic client, ~99% of tokens are prompt and ~97% of those are
/// cache reads. Nothing in that moves, so nothing in it is worth a glance.
/// These readings are the derivatives that do move, and their job is **anomaly
/// detection rather than optimization**: a healthy cache is not something the
/// user can improve, but a broken one costs 10–20× and is otherwise invisible
/// until the quota is gone.
enum TokenEfficiency {

    /// The one figure with real dynamic range: dollars per million tokens
    /// processed. It absorbs both model mix and cache efficiency, so a single
    /// number captures "am I paying more per unit of work than usual".
    struct Reading: Equatable, Sendable {
        /// USD per million tokens across the window.
        let effectiveRate: Double
        /// Share of prompt tokens served from cache (0–100).
        let cacheHitPercent: Double
        /// Share of prompt tokens that had to be re-cached (0–100). This is
        /// the actionable half: reads are nearly free, writes are not.
        let reCachePercent: Double
        /// Share of all tokens that were generated rather than re-read (0–100).
        let outputPercent: Double
        /// Total tokens across the window — the denominator, not a headline.
        let totalTokens: Int
        /// Per-day effective rate, oldest first, for the sparkline.
        let dailyRates: [Double]
        /// Whether the account is currently writing to the short-lived cache.
        let cacheTTL: CacheTTLState
    }

    /// Which prompt-cache TTL the server is granting.
    ///
    /// Claude Code asks for the 1-hour TTL. Exhausting the 5-hour quota makes
    /// the server hand back the 5-minute one instead, after which context stops
    /// surviving ordinary idle gaps and has to be rebuilt far more often. It is
    /// not a client-side setting and nothing else surfaces it — the only signal
    /// is which bucket the transcript's cache-creation tokens land in.
    enum CacheTTLState: Equatable, Sendable {
        /// Every cache write used the 1-hour TTL.
        case standard
        /// Some or all writes were downgraded to the 5-minute TTL.
        /// `sharePercent` is how much of the window's write volume that covers.
        case downgraded(sharePercent: Double)
        /// No cache writes in the window — nothing to report either way.
        case unknown
    }

    /// A day is only meaningful for the rate series once it has enough volume
    /// that the ratio is not dominated by a single request.
    static let minimumTokensPerDay = 50_000

    /// Below this share of write volume the 5-minute bucket is a rounding
    /// artifact (a session that happened to start at a quota boundary) rather
    /// than a sustained downgrade worth alerting on.
    static let downgradeAlertThreshold: Double = 15

    /// The TTL notice answers "is my cache degraded **now**", so it reads only
    /// the trailing days — averaged across a month a live downgrade dilutes
    /// below any useful threshold and the alert silently never fires. Two days
    /// rather than one because a day that has barely started carries too few
    /// writes to judge.
    static let ttlWindowDays = 2

    static func reading(
        from series: [LedgerStore.DailyCost],
        sparklineDays: Int = 14
    ) -> Reading? {
        let attributed = series.filter { !$0.tokens.isEmpty }
        guard !attributed.isEmpty else { return nil }

        var totals = TokenUsage.zero
        var cost = 0.0
        for day in attributed {
            totals += day.tokens
            cost += day.totalUSD
        }
        guard totals.total > 0 else { return nil }

        // Prompt tokens are everything the model read; output is what it wrote.
        let prompt = totals.total - totals.output
        let cached = totals.cacheRead + totals.cachedInput
        let writes = totals.cacheWrite

        return Reading(
            effectiveRate: cost / (Double(totals.total) / 1_000_000),
            cacheHitPercent: prompt > 0 ? Double(cached) / Double(prompt) * 100 : 0,
            reCachePercent: prompt > 0 ? Double(writes) / Double(prompt) * 100 : 0,
            outputPercent: Double(totals.output) / Double(totals.total) * 100,
            totalTokens: totals.total,
            dailyRates: dailyRates(from: attributed, limit: sparklineDays),
            cacheTTL: ttlState(from: attributed.suffix(ttlWindowDays))
        )
    }

    /// Per-day rate for the trailing `limit` days that carry enough volume.
    /// Thin days are dropped rather than plotted, because a day with one
    /// request produces a rate that is noise and would dominate the y-range.
    static func dailyRates(
        from series: [LedgerStore.DailyCost],
        limit: Int
    ) -> [Double] {
        series
            .filter { $0.tokens.total >= minimumTokensPerDay && $0.totalUSD > 0 }
            .suffix(limit)
            .map { $0.totalUSD / (Double($0.tokens.total) / 1_000_000) }
    }

    /// Reads the TTL the server actually granted out of the write buckets.
    static func ttlState(from series: some Collection<LedgerStore.DailyCost>) -> CacheTTLState {
        var fiveMinute = 0
        var oneHour = 0
        for day in series {
            fiveMinute += day.tokens.cacheWrite5m
            oneHour += day.tokens.cacheWrite1h
        }
        let total = fiveMinute + oneHour
        guard total > 0 else { return .unknown }

        // A transcript predating the per-TTL split lands entirely in the
        // 5-minute bucket, which would read as a downgrade that never
        // happened. Requiring some 1-hour volume distinguishes "downgraded
        // partway through" from "we simply cannot tell".
        guard oneHour > 0 else { return .unknown }

        let share = Double(fiveMinute) / Double(total) * 100
        return share >= downgradeAlertThreshold
            ? .downgraded(sharePercent: share)
            : .standard
    }
}
