import SwiftUI

/// Keeps pace next to usage while leaving reset timing in its own visual row.
/// A raw "pace 54%" asks the reader to do subtraction; this says whether
/// current usage is over or under that reference and by how much.
struct PaceReadout: View {
    let percentUsed: Double
    let pacePercent: Double

    private var delta: Double { percentUsed - pacePercent }
    private var roundedPoints: Int { Int(abs(delta).rounded()) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("Pace now \(Int(pacePercent.rounded()))%")
                .foregroundStyle(.secondary.opacity(0.74))

            Text("·")
                .foregroundStyle(.tertiary)

            Text(comparison)
                .foregroundStyle(comparisonColor)
        }
        .font(.system(size: 11, weight: delta >= 10 ? .semibold : .regular, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var comparison: String {
        guard roundedPoints > 1 else { return "on pace" }
        return "\(roundedPoints) pts \(delta > 0 ? "over" : "under")"
    }

    private var comparisonColor: AnyShapeStyle {
        if delta >= 10 {
            return AnyShapeStyle(LimitBar.warnAccent)
        }
        return AnyShapeStyle(.secondary.opacity(0.74))
    }
}

/// Reset timing is deliberately not mixed into the pace comparison. The
/// clock and eyebrow establish it as temporal context rather than another
/// utilization signal.
struct ResetCountdownReadout: View {
    let resetsAt: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 9.5, weight: .medium))

            Text("RESET")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.5)

            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()

            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary.opacity(0.72))
        .accessibilityElement(children: .combine)
    }

    private var value: String {
        guard let resetsAt else { return "not reported" }
        return "in \(OverviewSummary.shortCountdown(until: resetsAt))"
    }
}

#Preview("Pace Readouts") {
    VStack(alignment: .leading, spacing: 10) {
        PaceReadout(percentUsed: 42, pacePercent: 54)
        PaceReadout(percentUsed: 68, pacePercent: 59)
        PaceReadout(percentUsed: 72, pacePercent: 52)
        ResetCountdownReadout(resetsAt: .now.addingTimeInterval(4 * 60 * 60))
    }
    .padding()
}
