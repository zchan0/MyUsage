import SwiftUI

/// A single limit row used inside `ProviderCard`. Shape:
///
///     name (left)            PCT  reset (right, mono baseline)
///     ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔  (4pt sage rail — coloured at warn/crit)
///
/// Percent and reset live in fixed-width trailing columns so multiple
/// rows in the same card column-align cleanly. The bar fill stays
/// neutral (sage) by default and only adopts the warn/crit palette
/// once the limit crosses 75% / 90%. Brand color is never used in the
/// bar — that channel belongs to the brand-icon tile in the card head.
struct LimitBar: View {
    let name: String
    let percent: Double
    var reset: String? = nil
    /// When true, the name is rendered in monospaced 10.5pt — used by
    /// Antigravity per-model rows ("flash 47/200").
    var monoName: Bool = false
    /// When true, the reset slot reserves a fixed width even when empty,
    /// so percentages and reset texts column-align across multiple rows
    /// in the same card. Antigravity per-model rows pass `false` because
    /// they never carry a reset string and don't need that column.
    var reservesResetSlot: Bool = true

    private let pctColumnWidth: CGFloat = 38
    private let resetColumnWidth: CGFloat = 86

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                nameView
                Spacer(minLength: 8)
                Text(pctString)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(pctColor)
                    .frame(width: pctColumnWidth, alignment: .trailing)
                if reservesResetSlot {
                    Text(reset ?? "")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary.opacity(0.7))
                        .frame(width: resetColumnWidth, alignment: .trailing)
                }
            }
            ProgressTrack(percent: percent, level: level)
        }
    }

    @ViewBuilder
    private var nameView: some View {
        if monoName {
            Text(name)
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
        } else {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.95))
        }
    }

    private var level: LimitSafety.Level { LimitSafety.level(for: percent) }

    private var pctString: String { "\(Int(percent.rounded()))%" }

    private var pctColor: Color {
        switch level {
        case .healthy: .primary.opacity(0.92)
        case .warn:    Color(hue: 38.0/360.0, saturation: 0.92, brightness: 0.62)
        case .crit:    Color(hue: 8.0/360.0,  saturation: 0.78, brightness: 0.66)
        }
    }
}

/// The 4pt rail under a `LimitBar`. Pulled out so it can be reused by other
/// usage rows (e.g. an on-demand row that lives in a denser layout).
struct ProgressTrack: View {
    let percent: Double
    var level: LimitSafety.Level = .healthy
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))

                Capsule()
                    .fill(fillColor)
                    .frame(width: max(0, geo.size.width * min(percent, 100) / 100))
                    .animation(.easeInOut(duration: 0.4), value: percent)
            }
        }
        .frame(height: height)
    }

    private var fillColor: Color {
        switch level {
        // Sage green, matched to the safety palette used by Settings →
        // Sync status indicator. Low saturation keeps the popover calm
        // while still communicating "this is healthy" — distinguishable
        // from the neutral-gray track at a glance, where the previous
        // gray-on-gray fill was indistinguishable from a missing-data
        // state.
        case .healthy: Color(hue: 145.0/360.0, saturation: 0.45, brightness: 0.55)
        case .warn:    Color(hue: 38.0/360.0,  saturation: 0.92, brightness: 0.55)
        case .crit:    Color(hue: 8.0/360.0,   saturation: 0.78, brightness: 0.58)
        }
    }
}

#Preview("Limits") {
    VStack(alignment: .leading, spacing: 12) {
        LimitBar(name: "5-hour", percent: 47, reset: "resets 2h 14m")
        LimitBar(name: "Weekly", percent: 25, reset: "resets Sun")
        LimitBar(name: "Weekly", percent: 78, reset: "resets Sun")
        LimitBar(name: "Weekly", percent: 91, reset: "resets Sun")
        LimitBar(name: "flash 47/200", percent: 23, monoName: true, reservesResetSlot: false)
    }
    .padding(16)
    .frame(width: 320)
}
