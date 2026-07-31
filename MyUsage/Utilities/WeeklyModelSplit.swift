import Foundation

/// Splits the account-wide weekly limit into per-model shares.
///
/// Pooled Claude plans (Max included) report exactly two caps — `session` and
/// `weekly_all`. There is no `weekly_scoped` entry for Fable, Opus or anything
/// else, so the API cannot answer "how much of my week did Fable eat". The
/// local ledger can: it records per-model cost per day, which is the only
/// per-model signal that exists on such an account.
///
/// Each row is therefore the model's estimated slice **of the weekly bar**:
/// `weeklyPercentUsed × (model cost ÷ attributed cost in the window)`. Rows sum
/// to the weekly percentage, so they read against the same axis, the same reset
/// and the same pace notch as the Weekly instrument itself — no separate
/// countdown or projection, because the window is literally the weekly one.
///
/// This is an estimate. Anthropic weights quota by its own internal cost model,
/// not by list price, and the ledger aggregates whole UTC days while the weekly
/// window starts mid-day. Callers must label it as such.
enum WeeklyModelSplit {

    /// Ignore slices that would render as "0%" — a row that rounds to nothing
    /// costs a line and says nothing.
    private static let minimumPercent = 0.5

    /// - Parameters:
    ///   - series: Daily costs for the provider, ascending by UTC day.
    ///   - weeklyPercentUsed: Current utilization of the weekly cap (0–100).
    ///   - weeklyResetsAt: When the weekly window rolls over.
    ///   - windowDuration: Length of the weekly window.
    /// - Returns: Rows sorted by descending share, sharing the weekly reset.
    static func rows(
        series: [LedgerStore.DailyCost],
        weeklyPercentUsed: Double,
        weeklyResetsAt: Date?,
        windowDuration: TimeInterval = 7 * 24 * 3600,
        now: Date = .now
    ) -> [WeeklyModelUsage] {
        guard weeklyPercentUsed > 0,
              let weeklyResetsAt,
              windowDuration > 0
        else { return [] }

        // Day granularity is all the ledger has, so take every UTC day the
        // window touches, inclusive of the partial first and last days.
        let windowStart = weeklyResetsAt.addingTimeInterval(-windowDuration)
        let firstDay = LedgerCalendar.dayKey(for: windowStart)
        let lastDay = LedgerCalendar.dayKey(for: min(now, weeklyResetsAt))

        var costByModel: [String: Double] = [:]
        for entry in series where entry.day >= firstDay && entry.day <= lastDay {
            for (model, usd) in entry.byModel where usd > 0 {
                costByModel[model, default: 0] += usd
            }
        }

        let attributed = costByModel.values.reduce(0, +)
        guard attributed > 0 else { return [] }

        return costByModel
            .map { model, usd in
                WeeklyModelUsage(
                    label: model,
                    percent: weeklyPercentUsed * usd / attributed,
                    resetsAt: weeklyResetsAt
                )
            }
            .filter { $0.percent >= minimumPercent }
            .sorted {
                $0.percent == $1.percent
                    ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                    : $0.percent > $1.percent
            }
    }
}
