import Foundation

/// Local token activity and agent-reported costs, grouped by calendar day and hour.
struct LocalUsageReport: Sendable, Equatable {
    struct ModelMetrics: Sendable, Equatable {
        var tokens: TokenUsage = .zero
        var reportedCostUSD: Double = 0

        var totalTokens: Int { tokens.total }

        var cacheHitRate: Double? {
            let hits = tokens.cacheRead + tokens.cachedInput
            let promptTotal = tokens.input + tokens.cacheWrite + hits
            guard promptTotal > 0 else { return nil }
            return Double(hits) / Double(promptTotal) * 100
        }

        static func + (lhs: Self, rhs: Self) -> Self {
            Self(tokens: lhs.tokens + rhs.tokens, reportedCostUSD: lhs.reportedCostUSD + rhs.reportedCostUSD)
        }

        static func += (lhs: inout Self, rhs: Self) {
            lhs = lhs + rhs
        }
    }

    struct Bucket: Identifiable, Sendable, Equatable {
        let id: String
        let date: Date
        let label: String
        var models: [String: ModelMetrics]

        var totalTokens: Int { combinedTokens.total }
        var reportedCostUSD: Double { combinedMetrics(models).reportedCostUSD }
        var combinedTokens: TokenUsage { combinedMetrics(models).tokens }
        var cacheHitRate: Double? { combinedMetrics(models).cacheHitRate }
    }

    struct ModelSummary: Identifiable, Sendable, Equatable {
        var id: String { name }
        let name: String
        let tokens: Int
        let cacheHitRate: Double?
        let reportedCostUSD: Double
    }

    struct ScopeSummary: Sendable, Equatable {
        let totalTokens: Int
        let cacheHitRate: Double?
        let reportedCostUSD: Double
        let models: [ModelSummary]
    }

    let days: [Bucket]
    let hours: [Bucket]
    let hasReportedCost: Bool
    let orderedModelNames: [String]
    private let totalsByModel: [String: ModelMetrics]

    var summary30d: ScopeSummary { summarize(totalsByModel) }
    var summaryToday: ScopeSummary { summarize(days.last?.models ?? [:]) }

    func modelRows(for bucket: Bucket) -> [ModelSummary] {
        orderedModelNames.map { Self.modelSummary($0, metrics: bucket.models[$0]) }
    }

    func modelRows(for summary: ScopeSummary) -> [ModelSummary] {
        let byName = Dictionary(summary.models.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return orderedModelNames.map { byName[$0] ?? Self.modelSummary($0, metrics: nil) }
    }

    static func build(
        daily: [Date: [String: ModelMetrics]],
        hourlyToday: [Int: [String: ModelMetrics]],
        now: Date,
        calendar: Calendar
    ) -> LocalUsageReport {
        let today = calendar.startOfDay(for: now)
        let dayID = DateFormatter()
        dayID.locale = Locale(identifier: "en_US_POSIX")
        dayID.calendar = calendar
        dayID.timeZone = calendar.timeZone
        dayID.dateFormat = "yyyy-MM-dd"
        let dayLabel = DateFormatter()
        dayLabel.locale = dayID.locale
        dayLabel.calendar = calendar
        dayLabel.timeZone = calendar.timeZone
        dayLabel.dateFormat = "MMM d"

        let days = (-29...0).map { offset in
            let date = calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
            return Bucket(id: dayID.string(from: date), date: date,
                          label: offset == 0 ? "Today" : dayLabel.string(from: date),
                          models: daily[date] ?? [:])
        }

        // Keep a slot for each wall-clock hour. A skipped hour uses the next
        // valid instant and a repeated hour uses the first occurrence.
        let hours = (0..<24).map { hour in
            let label = String(format: "%02d:00", hour)
            let matching = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today,
                                         matchingPolicy: .nextTime, repeatedTimePolicy: .first)
            let date = matching.flatMap { calendar.isDate($0, inSameDayAs: today) ? $0 : nil } ?? today
            return Bucket(id: label, date: date, label: label, models: hourlyToday[hour] ?? [:])
        }

        var totals: [String: ModelMetrics] = [:]
        for day in days {
            for (name, metrics) in day.models {
                totals[name, default: ModelMetrics()] += metrics
            }
        }
        let names = totals.sorted { left, right in
            if left.value.totalTokens != right.value.totalTokens {
                return left.value.totalTokens > right.value.totalTokens
            }
            if left.value.reportedCostUSD != right.value.reportedCostUSD {
                return left.value.reportedCostUSD > right.value.reportedCostUSD
            }
            return left.key < right.key
        }.map(\.key)

        return LocalUsageReport(
            days: days,
            hours: hours,
            hasReportedCost: days.contains { $0.reportedCostUSD > 0 } || hours.contains { $0.reportedCostUSD > 0 },
            orderedModelNames: names,
            totalsByModel: totals
        )
    }

    private func summarize(_ models: [String: ModelMetrics]) -> ScopeSummary {
        let combined = Self.combinedMetrics(models)
        return ScopeSummary(
            totalTokens: combined.totalTokens,
            cacheHitRate: combined.cacheHitRate,
            reportedCostUSD: combined.reportedCostUSD,
            models: orderedModelNames.compactMap { name in
                models[name].map { Self.modelSummary(name, metrics: $0) }
            }
        )
    }

    private static func combinedMetrics(_ models: [String: ModelMetrics]) -> ModelMetrics {
        // Fix the addition order for floating-point costs.
        models.keys.sorted().reduce(into: ModelMetrics()) { total, name in
            total += models[name, default: .init()]
        }
    }

    private static func modelSummary(_ name: String, metrics: ModelMetrics?) -> ModelSummary {
        let metrics = metrics ?? ModelMetrics()
        return ModelSummary(name: name, tokens: metrics.totalTokens,
                            cacheHitRate: metrics.cacheHitRate, reportedCostUSD: metrics.reportedCostUSD)
    }
}
