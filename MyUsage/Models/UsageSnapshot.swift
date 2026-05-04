import Foundation

/// A single usage window (e.g., 5h session or 7d weekly).
struct UsageWindow: Sendable {
    /// Percentage used (0–100).
    let percentUsed: Double
    /// When this window resets.
    let resetsAt: Date?
    /// Total length of this window. When set, enables the burn-rate
    /// projection (`projectedFinalPercent`). Optional for backwards
    /// compatibility — providers that don't fill it in just don't get
    /// the "you'll run out before reset" indicator.
    var windowDuration: TimeInterval?

    init(
        percentUsed: Double,
        resetsAt: Date?,
        windowDuration: TimeInterval? = nil
    ) {
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
    }

    /// Percentage remaining (100 - percentUsed).
    var percentRemaining: Double { max(0, 100 - percentUsed) }

    /// Formatted time until reset, with the absolute clock time appended
    /// after a middle-dot separator. Caller renders this as a single
    /// chunk; the absolute portion answers "what time will that actually
    /// be" so the user doesn't have to mental-arithmetic the countdown.
    ///
    /// Format adapts to distance:
    ///   < 24h  →  `2h 14m · 16:30`
    ///   1d–7d  →  `5d 12h · Tue 09:00`
    ///   > 7d   →  `28d · May 28`     (Cursor billing cycle, etc.)
    ///
    /// Time + day templates use `setLocalizedDateFormatFromTemplate` so
    /// 12h vs 24h respects the system locale automatically.
    var resetCountdown: String? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSinceNow
        guard interval > 0 else { return "Resetting…" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        let relative: String
        if hours > 24 {
            let days = hours / 24
            relative = "\(days)d \(hours % 24)h"
        } else if hours > 0 {
            relative = "\(hours)h \(minutes)m"
        } else {
            relative = "\(minutes)m"
        }

        return "\(relative) · \(Self.absoluteResetText(for: resetsAt, interval: interval))"
    }

    private static func absoluteResetText(for date: Date, interval: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        if interval < 24 * 3600 {
            formatter.setLocalizedDateFormatFromTemplate("Hm")
        } else if interval < 7 * 86400 {
            formatter.setLocalizedDateFormatFromTemplate("EEEHm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }

    /// Where the user would be right now if they were on a steady "burn
    /// 100% across the full window" pace. Returns the on-pace position
    /// as a percent (0–100). If the bar's actual fill is past this
    /// number, the user is ahead of pace; if behind, they're slower.
    ///
    /// Renderable as a small marker on the bar — fill-past-marker reads
    /// as "I'm burning hot", fill-behind-marker reads as "I have
    /// runway". Communicates velocity without requiring the user to do
    /// arithmetic on percentages and elapsed time.
    ///
    /// Note: unlike `projectedFinalPercent` this does NOT need a noise
    /// gate. The position is deterministic from time alone — there's
    /// no usage data being extrapolated, so even a brand-new window
    /// has a meaningful (just very-near-zero) on-pace position.
    func onPacePercent(now: Date = .now) -> Double? {
        guard let resetsAt, let windowDuration, windowDuration > 0 else { return nil }
        let timeRemaining = resetsAt.timeIntervalSince(now)
        guard timeRemaining > 0 else { return nil }
        let elapsed = windowDuration - timeRemaining
        guard elapsed > 0 else { return nil }
        return min(100, elapsed / windowDuration * 100)
    }

    /// Linear extrapolation: if usage continues at the current burn rate
    /// (% per second, derived from elapsed time in this window), what
    /// percent would we land at when the window resets?
    ///
    /// Returns `nil` when projection isn't meaningful: window duration
    /// unknown, no reset time, already past reset, or **not enough of
    /// the window has elapsed** for the burn rate to be reliable. We
    /// require the lesser of (60 seconds) or (20% of window duration) —
    /// e.g. a 5-hour window needs at least 1h of data before projection,
    /// and a 7-day window needs ~1.4d. Without this gate, a single early
    /// prompt of 5% in the first 10 minutes of a 5h window would extrapolate
    /// to ~150% and false-trigger the overshoot indicator for hours.
    ///
    /// The result is intentionally NOT capped — callers cap at render
    /// time so a "you'll be at 230% by Sunday" can still be detected
    /// upstream (e.g. for a stronger warning).
    func projectedFinalPercent(now: Date = .now) -> Double? {
        guard let resetsAt, let windowDuration, windowDuration > 0 else {
            return nil
        }
        let timeRemaining = resetsAt.timeIntervalSince(now)
        guard timeRemaining > 0 else { return nil }
        let elapsed = windowDuration - timeRemaining
        let minElapsed = max(60, windowDuration * 0.20)
        guard elapsed >= minElapsed else { return nil }
        return percentUsed * windowDuration / elapsed
    }
}

/// One row of the per-model breakdown shown under Claude's weekly bar.
/// Anthropic's `/api/oauth/usage` returns separate utilization values
/// for `seven_day_sonnet`, `seven_day_opus`, etc. — this surfaces them
/// as a list, sorted by percent so the heaviest consumer reads first.
struct WeeklyModelUsage: Sendable, Equatable, Identifiable {
    let label: String       // "Sonnet", "Opus", "Haiku"
    let percent: Double
    var id: String { label }
}

/// Per-model quota info (used by Antigravity).
struct ModelQuota: Identifiable, Sendable {
    let id = UUID()
    /// Display label, e.g., "Claude Sonnet 4.5"
    let label: String
    /// Remaining fraction (0.0 = depleted, 1.0 = full)
    let remainingFraction: Double
    /// When this model's quota resets.
    let resetsAt: Date?

    /// Percentage used (0–100).
    var percentUsed: Double { (1.0 - remainingFraction) * 100 }
}

/// Credit / billing info.
struct CreditInfo: Sendable {
    /// Amount spent or remaining (in dollars).
    let amount: Double
    /// Budget limit (in dollars), nil if unlimited.
    let limit: Double?
    /// Currency code.
    let currency: String

    /// Formatted display: "$5.39" or "$232.22 / $400.00"
    var formatted: String {
        if let limit {
            return String(format: "$%.2f / $%.2f", amount, limit)
        }
        return String(format: "$%.2f", amount)
    }
}

/// Unified usage snapshot from any provider.
struct UsageSnapshot: Sendable {
    // MARK: - Rolling windows (Claude, Codex)
    var sessionUsage: UsageWindow?
    var weeklyUsage: UsageWindow?
    /// Per-model breakdown of the weekly window. Populated only for
    /// Claude (Anthropic's API exposes it; OpenAI's Codex does not).
    /// Sorted by percent descending; only models with > 0% included.
    var weeklyByModel: [WeeklyModelUsage] = []

    // MARK: - Billing cycle (Cursor)
    var totalUsagePercent: Double?
    var billingCycleEnd: Date?
    var spentAmount: CreditInfo?

    // MARK: - Per-model quotas (Antigravity)
    var modelQuotas: [ModelQuota] = []

    // MARK: - Common
    var planName: String?
    var email: String?
    var credits: CreditInfo?
    var onDemandSpend: CreditInfo?
    var lastRefreshed: Date = .now

    /// Estimated spend (USD) so far this calendar month.
    /// - Claude/Codex: computed from local JSONL logs × API pricing.
    /// - Cursor: sum of included spend + on-demand spend from the billing API.
    /// - nil when the provider doesn't compute one.
    var monthlyEstimatedCost: Double?

    // MARK: - Computed

    /// On-demand usage percentage (0–100), nil if no limit set.
    var onDemandUsagePercent: Double? {
        guard let od = onDemandSpend, let limit = od.limit, limit > 0 else { return nil }
        return od.amount / limit * 100
    }

    /// The worst-case (highest) usage percentage across all windows.
    var worstUsagePercent: Double {
        let candidates: [Double?] = [
            sessionUsage?.percentUsed,
            weeklyUsage?.percentUsed,
            totalUsagePercent,
            onDemandUsagePercent,
            modelQuotas.isEmpty ? nil : modelQuotas.map(\.percentUsed).max()
        ]
        return candidates.compactMap { $0 }.max() ?? 0
    }
}
