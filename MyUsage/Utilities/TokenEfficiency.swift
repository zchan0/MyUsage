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
///
/// The cache *hit ratio* is deliberately not among them. Measured across this
/// app's own ledger it sits between 91% and 98% on every day with real volume,
/// while the effective rate over the same days swings 5×. There is no threshold
/// in it that means anything, and the rate already absorbs it — a cache that
/// stops working shows up as a more expensive million tokens.
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
        /// The day the headline describes, `YYYY-MM-DD` UTC. Carried because
        /// it is frequently *not* today: quiet days fall below
        /// `minimumTokensPerDay` and the headline falls back to the last day
        /// that clears it, which can be a week old. Labelling that "today"
        /// misreports the reading, so the day travels with it.
        let day: String
        /// Whether `day` is the current one.
        let isCurrentDay: Bool
        /// Share of all tokens that were generated rather than re-read (0–100).
        let outputPercent: Double
        /// Tokens the model actually wrote. Reported as a count rather than a
        /// share because the footnote's other figures are counts, and a
        /// percentage of a number two orders of magnitude larger is arithmetic
        /// the reader should not have to do.
        let generatedTokens: Int
        /// Tokens spent rebuilding cache that had expired.
        let reCachedTokens: Int
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

    /// A day carrying less write volume than this cannot support a verdict —
    /// a single context rebuild can be 200k tokens, so a barely-started day
    /// yields a share swung by one request. Silence is the correct output
    /// there; the alternative is a alert derived from one sample.
    ///
    /// This is what an earlier version tried to buy by widening the window to
    /// two days, at the cost of the staleness that made the notice permanent.
    /// A volume floor buys it without borrowing yesterday's evidence.
    static let minimumWritesForTTLVerdict = 500_000

    static func reading(
        from series: [LedgerStore.DailyCost],
        sparklineDays: Int = 14,
        today: String = LedgerCalendar.dayKey(for: .now)
    ) -> Reading? {
        // Only days with enough volume to produce a stable ratio. A day with
        // two requests yields a rate that is noise, and as the headline it
        // would be actively misleading.
        let usable = series.filter {
            !$0.tokens.isEmpty && $0.tokens.total >= minimumTokensPerDay && $0.totalUSD > 0
        }
        guard let latest = usable.last else { return nil }

        let tokens = latest.tokens

        let history = usable.dropLast().suffix(sparklineDays).map {
            $0.totalUSD / (Double($0.tokens.total) / 1_000_000)
        }

        return Reading(
            effectiveRate: latest.totalUSD / (Double(tokens.total) / 1_000_000),
            baselineRate: median(of: history),
            day: latest.day,
            isCurrentDay: latest.day == today,
            outputPercent: tokens.total > 0 ? Double(tokens.output) / Double(tokens.total) * 100 : 0,
            generatedTokens: tokens.output,
            reCachedTokens: tokens.cacheWrite,
            totalTokens: tokens.total,
            dailyRates: dailyRates(from: usable, limit: sparklineDays),
            // The full series, not `usable`: the TTL verdict has its own
            // volume floor, and the ambiguity check below needs the history
            // that the token floor would filter out.
            cacheTTL: ttlState(from: series, today: today)
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
    ///
    /// **Today only.** The notice claims a live condition, so it may only be
    /// drawn from live evidence. An earlier version summed the trailing two
    /// *usable* days — rows in the series, not calendar days — which meant a
    /// gap in usage pinned the verdict to whenever the user last worked hard.
    /// A downgrade from four days ago stayed on screen indefinitely, and its
    /// share was volume-weighted, so a clean current day contributing 2% of
    /// the window's writes could not clear it.
    static func ttlState(
        from series: some Collection<LedgerStore.DailyCost>,
        today: String = LedgerCalendar.dayKey(for: .now)
    ) -> CacheTTLState {
        guard let current = series.first(where: { $0.day == today }) else { return .unknown }

        let fiveMinute = current.tokens.cacheWrite5m
        let oneHour = current.tokens.cacheWrite1h
        guard fiveMinute + oneHour >= minimumWritesForTTLVerdict else { return .unknown }

        // A transcript predating the per-TTL split lands entirely in the
        // 5-minute bucket, which would read as a downgrade that never
        // happened. On its own an all-5m day cannot be told apart from one —
        // but if this account has ever produced 1-hour writes, its transcripts
        // do carry the split, and an all-5m day is a real all-day downgrade.
        if oneHour == 0 {
            let splitIsObservable = series.contains {
                $0.day != today && $0.tokens.cacheWrite1h > 0
            }
            guard splitIsObservable else { return .unknown }
        }

        let share = Double(fiveMinute) / Double(fiveMinute + oneHour) * 100
        return share >= downgradeAlertThreshold
            ? .downgraded(sharePercent: share)
            : .standard
    }
}
