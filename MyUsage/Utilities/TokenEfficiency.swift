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
        /// USD per million tokens for the most recent day carrying enough
        /// volume to be meaningful.
        ///
        /// Deliberately *not* a 30-day average. This reading exists to catch
        /// anomalies, and an average over a month is the one window guaranteed
        /// to hide them: a day that costs 3× normal moves a 30-day mean by a
        /// few percent. The sparkline supplies the history; the headline is
        /// today.
        let effectiveRate: Double
        /// Median rate across the preceding days, so the headline can be read
        /// as "cheap or expensive **for me**" without knowing the usual range.
        /// nil until there are enough prior days to form one.
        let baselineRate: Double?
        /// Share of prompt tokens served from cache on the headline day
        /// (0–100). Same window as the rate, for the same reason.
        let cacheHitPercent: Double
        /// Share of prompt tokens that had to be re-cached (0–100). This is
        /// the actionable half: reads are nearly free, writes are not.
        let reCachePercent: Double
        /// Share of all tokens that were generated rather than re-read (0–100).
        let outputPercent: Double
        /// Tokens processed on the headline day — the denominator, not a
        /// headline.
        let totalTokens: Int
        /// How the headline day compares to `baselineRate`, in percent.
        /// nil when there is no baseline to compare against.
        var deltaPercent: Double? {
            guard let baselineRate, baselineRate > 0 else { return nil }
            return (effectiveRate / baselineRate - 1) * 100
        }
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
        // Only days with enough volume to produce a stable ratio. A day with
        // two requests yields a rate that is noise, and as the headline it
        // would be actively misleading.
        let usable = series.filter {
            !$0.tokens.isEmpty && $0.tokens.total >= minimumTokensPerDay && $0.totalUSD > 0
        }
        guard let latest = usable.last else { return nil }

        let day = latest.tokens
        let prompt = day.total - day.output
        let cached = day.cacheRead + day.cachedInput

        let history = usable.dropLast().suffix(sparklineDays).map {
            $0.totalUSD / (Double($0.tokens.total) / 1_000_000)
        }

        return Reading(
            effectiveRate: latest.totalUSD / (Double(day.total) / 1_000_000),
            baselineRate: median(of: history),
            cacheHitPercent: prompt > 0 ? Double(cached) / Double(prompt) * 100 : 0,
            reCachePercent: prompt > 0 ? Double(day.cacheWrite) / Double(prompt) * 100 : 0,
            outputPercent: day.total > 0 ? Double(day.output) / Double(day.total) * 100 : 0,
            totalTokens: day.total,
            dailyRates: dailyRates(from: usable, limit: sparklineDays),
            cacheTTL: ttlState(from: usable.suffix(ttlWindowDays))
        )
    }

    /// Median rather than mean: one runaway day should not redefine "normal".
    /// nil below three samples, where a median is not yet a baseline.
    static func median(of values: [Double]) -> Double? {
        guard values.count >= 3 else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
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
