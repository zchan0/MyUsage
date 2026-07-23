import Charts
import SwiftUI

struct ModelCostInsight: Equatable, Sendable {
    let name: String
    let sharePercent: Double
}

struct DailyModelCost: Identifiable, Equatable, Sendable {
    let name: String
    let costUSD: Double?

    var id: String { name }
}

enum DailyCostChartInsights {
    static func topModel(in series: [LedgerStore.DailyCost]) -> ModelCostInsight? {
        var totals: [String: Double] = [:]
        for day in series {
            for (model, cost) in day.byModel where cost > 0 {
                totals[model, default: 0] += cost
            }
        }

        let total = series.reduce(0) { $0 + max(0, $1.totalUSD) }
        return topModel(in: totals, totalUSD: total)
    }

    /// Cost values for one selected day, kept in the chart's stable 30-day
    /// family order. `nil` means that family had no cost on the selected day.
    /// "Other" mirrors the chart stack: unattributed cost plus folded
    /// long-tail families.
    static func dailyBreakdown(
        for day: LedgerStore.DailyCost,
        families: [String],
        otherLabel: String = "Other"
    ) -> [DailyModelCost] {
        let named = Set(families.filter { $0 != otherLabel })
        let namedTotal = day.byModel.reduce(0.0) { partial, entry in
            named.contains(entry.key) ? partial + max(0, entry.value) : partial
        }
        let otherCost = max(0, day.totalUSD - namedTotal)

        return families.map { family in
            let cost: Double?
            if family == otherLabel {
                cost = otherCost > 0.005 ? otherCost : nil
            } else if let value = day.byModel[family], value > 0 {
                cost = value
            } else {
                cost = nil
            }
            return DailyModelCost(name: family, costUSD: cost)
        }
    }

    static func topModel(
        in breakdown: [DailyModelCost],
        totalUSD: Double
    ) -> ModelCostInsight? {
        let totals: [String: Double] = Dictionary(
            uniqueKeysWithValues: breakdown.compactMap { entry in
                guard let cost = entry.costUSD, cost > 0 else { return nil }
                return (entry.name, cost)
            }
        )
        return topModel(in: totals, totalUSD: totalUSD)
    }

    private static func topModel(
        in totals: [String: Double],
        totalUSD: Double
    ) -> ModelCostInsight? {
        guard totalUSD > 0,
              let winner = totals.sorted(by: {
                  $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
              }).first
        else { return nil }

        let share = min(100, max(0, winner.value / totalUSD * 100))
        return ModelCostInsight(name: winner.key, sharePercent: share)
    }
}

/// Trailing-30-day daily cost, stacked by model family — shown on a
/// provider's own tab beneath the cost row.
///
/// Encoding decisions (see the dataviz procedure):
/// - Stacked bars: the job is change-over-time + composition.
/// - At most **4** named families (ranked by 30-day total); everything
///   else — plus the unattributed remainder of days whose ledger rows
///   carry no per-model breakdown — folds into a gray "Other".
/// - Model families share one muted provider hue and differ by opacity.
/// - Hover (chartXSelection) swaps the header line to the hovered day's
///   date + total — the tooltip equivalent for a 316pt-wide popover.
struct DailyCostChart: View {
    let kind: ProviderKind
    let series: [LedgerStore.DailyCost]

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDate: Date?

    /// One stacked segment (day × family).
    private struct Segment: Identifiable {
        let day: Date
        let family: String
        let usd: Double
        var id: String { "\(day.timeIntervalSince1970)-\(family)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chart
            legend
            insights
        }
    }

    // MARK: - Header

    /// Default: range label + 30d total. While hovering: that day + its
    /// total. Doubles as the value readout required by the palette's
    /// contrast-relief rule.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(selectedDay.map { Self.dayLabel($0.day) } ?? "Rolling 30-day cost")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            if selectedDay == nil {
                Text("all accounts")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            Text(ProviderCardCostRow.formatCost(selectedDay?.totalUSD ?? totalUSD))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.9))
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart(segments) { segment in
            BarMark(
                x: .value("Day", segment.day, unit: .day),
                y: .value("Cost", segment.usd),
                width: .fixed(6)
            )
            .foregroundStyle(by: .value("Model", segment.family))
            .cornerRadius(1.5)
            .opacity(dimmed(segment.day) ? 0.35 : 1.0)
        }
        .chartForegroundStyleScale(domain: familyOrder, range: familyColors)
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedDate)
        // Pin the domain to the full trailing-30-day window. Without it
        // the axis collapses to the data extent — two days of usage
        // rendered as two enormous bars filling the plot.
        .chartXScale(domain: xDomain)
        // Leave a little air above the tallest stack so it does not visually
        // collide with the total in the header.
        .chartYScale(domain: 0...yAxisCeiling)
        .chartXAxis {
            AxisMarks(values: xAxisDates) { value in
                // Closure form + fixedSize: Charts width-limits a *centered*
                // boundary label to twice its distance from the plot edge, so
                // the last tick renders as "J…". fixedSize makes the text lay
                // out at its ideal width and overflow its slot instead of
                // truncating; the trailing plot inset gives that overflow room.
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xAxisLabel(for: date))
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.65))
                            .fixedSize()
                            .offset(x: axisLabelOffset(for: date))
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        // Boundary labels are centred on the first/last tick. Give them enough
        // plot inset to render their full localized date without clipping.
        .chartPlotStyle {
            $0.padding(.leading, 18)
                .padding(.trailing, 30)
        }
        .frame(height: 96)
    }

    private var yAxisCeiling: Double {
        let dailyStacks = Dictionary(grouping: segments, by: \.day)
            .values
            .map { $0.reduce(0) { $0 + $1.usd } }
        let maximum = dailyStacks.max() ?? 0
        return max(0.01, maximum * 1.12)
    }

    /// Trailing 30 days ending today (UTC day buckets, matching the data).
    private var xDomain: ClosedRange<Date> {
        let todayStart = Self.parseDay(LedgerCalendar.dayKey(for: .now)) ?? .now
        let end = todayStart.addingTimeInterval(86_400)
        return end.addingTimeInterval(-30 * 86_400)...end
    }

    private var xAxisDates: [Date] {
        let start = xDomain.lowerBound
        return [
            start,
            start.addingTimeInterval(14 * 86_400),
            xDomain.upperBound.addingTimeInterval(-86_400),
        ]
    }

    /// Charts centres boundary labels on their ticks, then clips them to the
    /// axis lane. Pull the two boundary labels inward by half a short date.
    private func axisLabelOffset(for date: Date) -> CGFloat {
        guard let first = xAxisDates.first, let last = xAxisDates.last else { return 0 }
        if abs(date.timeIntervalSince(first)) < 1 { return 14 }
        if abs(date.timeIntervalSince(last)) < 1 { return -14 }
        return 0
    }

    /// Stable legend keys. Hover adds the selected day's model costs without
    /// changing family order or color mapping. A two-column grid keeps up to
    /// five chart families readable without making the popover excessively
    /// tall.
    private var legend: some View {
        LazyVGrid(columns: legendColumns, alignment: .leading, spacing: 4) {
            ForEach(Array(zip(familyOrder, familyColors)), id: \.0) { family, color in
                legendItem(family: family, color: color)
            }
        }
    }

    private var legendColumns: [GridItem] {
        let count = max(1, min(2, familyOrder.count))
        return Array(
            repeating: GridItem(.flexible(), spacing: 12, alignment: .leading),
            count: count
        )
    }

    private func legendItem(family: String, color: Color) -> some View {
        let cost = selectedModelCosts?[family]
        let isAbsent = selectedDay != nil && cost == nil

        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(family)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if selectedDay != nil {
                Spacer(minLength: 3)
                Text(Self.modelCostLabel(cost))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isAbsent ? 0.45 : 1)
    }

    /// One quiet answer beneath the legend: which model accounts for the
    /// largest share of the visible 30-day cost. The right edge anchors the
    /// chart in time without forcing a default hover selection that would dim
    /// every other bar.
    @ViewBuilder
    private var insights: some View {
        if let topModel {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Top model")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Text(topModel.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(Int(topModel.sharePercent.rounded()))%")
                    .font(.system(size: 8.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 8)

                Text(insightScopeLabel)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Data shaping

    private static let otherLabel = "Other"

    /// Families ranked by 30-day total, capped at 4 + "Other".
    private var familyOrder: [String] {
        var totals: [String: Double] = [:]
        var hasOther = false
        for dayEntry in series {
            var attributed = 0.0
            for (family, usd) in dayEntry.byModel {
                totals[family, default: 0] += usd
                attributed += usd
            }
            if dayEntry.totalUSD - attributed > 0.005 { hasOther = true }
        }

        let ranked = totals
            .sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }
            .map(\.key)
        var order = Array(ranked.prefix(Self.maxNamedFamilies))
        if ranked.count > Self.maxNamedFamilies { hasOther = true }
        if hasOther { order.append(Self.otherLabel) }
        return order
    }

    private static let maxNamedFamilies = 4

    private var segments: [Segment] {
        let named = Set(familyOrder.filter { $0 != Self.otherLabel })
        var result: [Segment] = []
        for dayEntry in series {
            guard let day = Self.parseDay(dayEntry.day) else { continue }
            var other = dayEntry.totalUSD
            for (family, usd) in dayEntry.byModel where named.contains(family) {
                result.append(Segment(day: day, family: family, usd: usd))
                other -= usd
            }
            // Unattributed remainder + folded long-tail families.
            if other > 0.005 {
                result.append(Segment(day: day, family: Self.otherLabel, usd: other))
            }
        }
        return result
    }

    /// One muted provider hue, layered by opacity. Model composition remains
    /// legible without turning a utility chart into the page's focal point.
    private var familyColors: [Color] {
        let base: Color = switch kind {
        case .claude:
            colorScheme == .dark
                ? Color(red: 0.86, green: 0.56, blue: 0.42)
                : Color(red: 0.68, green: 0.39, blue: 0.27)
        case .codex:
            colorScheme == .dark
                ? Color(red: 80 / 255, green: 196 / 255, blue: 158 / 255)
                : Color(red: 16 / 255, green: 138 / 255, blue: 108 / 255)
        case .cursor:
            colorScheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.66)
        case .antigravity:
            colorScheme == .dark
                ? Color(red: 0.66, green: 0.53, blue: 0.86)
                : Color(red: 0.46, green: 0.34, blue: 0.65)
        }
        let opacities = [0.68, 0.46, 0.31, 0.21]

        return familyOrder.map { family in
            if family == Self.otherLabel {
                return Color.primary.opacity(0.18)
            }
            let index = familyOrder.firstIndex(of: family) ?? 0
            return base.opacity(opacities[min(index, opacities.count - 1)])
        }
    }

    // MARK: - Selection

    private var selectedDay: LedgerStore.DailyCost? {
        guard let selectedDate else { return nil }
        let key = LedgerCalendar.dayKey(for: selectedDate)
        return series.first { $0.day == key }
    }

    private var selectedBreakdown: [DailyModelCost]? {
        guard let selectedDay else { return nil }
        return DailyCostChartInsights.dailyBreakdown(
            for: selectedDay,
            families: familyOrder,
            otherLabel: Self.otherLabel
        )
    }

    private var selectedModelCosts: [String: Double]? {
        guard let selectedBreakdown else { return nil }
        return Dictionary(uniqueKeysWithValues: selectedBreakdown.compactMap { entry in
            guard let cost = entry.costUSD else { return nil }
            return (entry.name, cost)
        })
    }

    /// While a day is hovered, un-hovered bars recede slightly so the
    /// readout in the header is visually anchored to one column.
    private func dimmed(_ day: Date) -> Bool {
        guard let selected = selectedDay else { return false }
        return LedgerCalendar.dayKey(for: day) != selected.day
    }

    private var totalUSD: Double {
        series.reduce(0) { $0 + $1.totalUSD }
    }

    private var topModel: ModelCostInsight? {
        if let selectedDay, let selectedBreakdown {
            return DailyCostChartInsights.topModel(
                in: selectedBreakdown,
                totalUSD: selectedDay.totalUSD
            )
        }
        return DailyCostChartInsights.topModel(in: series)
    }

    private var insightScopeLabel: String {
        selectedDay.map { Self.dayLabel($0.day) } ?? "30d ago → Today"
    }

    // MARK: - Formatting

    private static func parseDay(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        return LedgerCalendar.utc.date(from: comps)
    }

    /// "JUL 12" style header label for a hovered day.
    private static func dayLabel(_ day: String) -> String {
        guard let date = parseDay(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date).uppercased()
    }

    private static func modelCostLabel(_ cost: Double?) -> String {
        guard let cost, cost > 0 else { return "—" }
        if cost < 0.01 { return "<$0.01" }
        return ProviderCardCostRow.formatCost(cost, estimated: false)
    }

    private func xAxisLabel(for date: Date) -> String {
        if let last = xAxisDates.last, abs(date.timeIntervalSince(last)) < 1 {
            return "Today"
        }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}

#Preview {
    let today = Date.now
    let series: [LedgerStore.DailyCost] = (0..<30).compactMap { offset in
        let date = today.addingTimeInterval(Double(-offset) * 86_400)
        let opus = Double.random(in: 0...4)
        let sonnet = Double.random(in: 0...2)
        let unattributed = offset % 5 == 0 ? 0.8 : 0
        return LedgerStore.DailyCost(
            day: LedgerCalendar.dayKey(for: date),
            totalUSD: opus + sonnet + unattributed,
            byModel: ["Opus": opus, "Sonnet": sonnet]
        )
    }
    .reversed()

    return DailyCostChart(kind: .claude, series: Array(series))
        .padding(16)
        .frame(width: 340)
}
