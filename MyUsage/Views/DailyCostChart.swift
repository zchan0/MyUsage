import Charts
import SwiftUI

/// Trailing-30-day daily cost, stacked by model family — shown on a
/// provider's own tab beneath the cost row.
///
/// Encoding decisions (see the dataviz procedure):
/// - Stacked bars: the job is change-over-time + composition.
/// - At most **4** named families (ranked by 30-day total); everything
///   else — plus the unattributed remainder of days whose ledger rows
///   carry no per-model breakdown — folds into a gray "Other".
/// - Categorical hues come from a CVD-validated fixed-order palette
///   (validated against the popover's light & dark surfaces; the two
///   low-contrast light slots are mitigated by the always-on legend
///   and the hover readout, per the relief rule).
/// - One y-axis; recessive grid; legend chips wear text tokens, color
///   only lives in the dot.
/// - Hover (chartXSelection) swaps the header line to the hovered day's
///   date + total — the tooltip equivalent for a 316pt-wide popover.
struct DailyCostChart: View {
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
        VStack(alignment: .leading, spacing: 6) {
            header
            chart
            legend
        }
    }

    // MARK: - Header

    /// Default: range label + 30d total. While hovering: that day + its
    /// total. Doubles as the value readout required by the palette's
    /// contrast-relief rule.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(selectedDay.map { Self.dayLabel($0.day) } ?? "LAST 30 DAYS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary.opacity(0.75))

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
                y: .value("Cost", segment.usd)
            )
            .foregroundStyle(by: .value("Model", segment.family))
            .cornerRadius(1.5)
            .opacity(dimmed(segment.day) ? 0.35 : 1.0)
        }
        .chartForegroundStyleScale(domain: familyOrder, range: familyColors)
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel {
                    if let usd = value.as(Double.self) {
                        Text("$\(usd, format: .number.precision(.fractionLength(0)))")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                }
            }
        }
        .frame(height: 96)
    }

    /// Compact legend chips: color dot + family name in secondary text.
    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(Array(zip(familyOrder, familyColors)), id: \.0) { family, color in
                HStack(spacing: 4) {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                    Text(family)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
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

        let ranked = totals.sorted { $0.value > $1.value }.map(\.key)
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

    /// Fixed-order categorical palette (dataviz reference slots 1–4),
    /// validated for both popover surfaces; "Other" is a neutral gray,
    /// never a series hue.
    private var familyColors: [Color] {
        let slots: [Color] = colorScheme == .dark
            ? [
                Color(red: 0x39/255.0, green: 0x87/255.0, blue: 0xE5/255.0),
                Color(red: 0x00/255.0, green: 0x83/255.0, blue: 0x00/255.0),
                Color(red: 0xD5/255.0, green: 0x51/255.0, blue: 0x81/255.0),
                Color(red: 0xC9/255.0, green: 0x85/255.0, blue: 0x00/255.0),
            ]
            : [
                Color(red: 0x2A/255.0, green: 0x78/255.0, blue: 0xD6/255.0),
                Color(red: 0x00/255.0, green: 0x83/255.0, blue: 0x00/255.0),
                Color(red: 0xE8/255.0, green: 0x7B/255.0, blue: 0xA4/255.0),
                Color(red: 0xED/255.0, green: 0xA1/255.0, blue: 0x00/255.0),
            ]

        return familyOrder.map { family in
            if family == Self.otherLabel {
                return Color.primary.opacity(0.25)
            }
            let index = familyOrder.firstIndex(of: family) ?? 0
            return slots[min(index, slots.count - 1)]
        }
    }

    // MARK: - Selection

    private var selectedDay: LedgerStore.DailyCost? {
        guard let selectedDate else { return nil }
        let key = LedgerCalendar.dayKey(for: selectedDate)
        return series.first { $0.day == key }
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

    return DailyCostChart(series: Array(series))
        .padding(16)
        .frame(width: 340)
}
