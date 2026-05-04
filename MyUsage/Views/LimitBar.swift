import SwiftUI

/// A single limit row. v0.9.1 shape:
///
///     5-hour                                                47%   ← name (L) + pct (R)
///     ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  ← 4pt bar
///     resets 2h 14m · 16:30                  projected 118%       ← reset (L, with
///                                                                   absolute clock
///                                                                   time appended)
///                                                                   + alarm-only
///                                                                   projection note (R)
///
/// Three rows. Splitting pct (top-right) from reset (bottom-left)
/// gives each its own visual lane, instead of crowding both onto a
/// shared meta line — the user can scan "where am I" (top) and "when
/// does it reset" (bottom) without re-parsing a packed strip.
///
/// The bar is the slim 4pt rail. The dashed projection marker rides as
/// an .overlay on it, but only when projection actually crosses 100%
/// (see `alarmingProjection`). Healthy projections stay silent.
///
/// Pct gets a tinted Capsule **only** in warn / crit — healthy rows
/// just show bold mono text. Most of the popover is healthy at any
/// given moment; a coloured chip on every row would be visual noise.
struct LimitBar: View {
    let name: String
    let percent: Double
    var reset: String? = nil
    /// Projected final percent at reset, from
    /// `UsageWindow.projectedFinalPercent(now:)`. nil = math gated
    /// (window < 20% elapsed) or projection not applicable (no
    /// `windowDuration`, e.g. Antigravity per-model rows).
    var projectedPercent: Double? = nil
    /// When true, the name is rendered in monospaced 10.5pt — used by
    /// Antigravity per-model rows ("flash 47/200").
    var monoName: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1 — name (left) + pct (right).
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                nameView
                Spacer(minLength: 8)
                pctView
            }

            // Row 2 — the bar (4pt sage rail with optional projection
            // marker overlay; marker only renders for projected > 100%).
            ProgressTrack(
                percent: percent,
                projectedPercent: alarmingProjection,
                level: level
            )

            // Row 3 — reset (left, with absolute time appended) +
            // alarm-only projection note (right). Skipped entirely when
            // both are absent (Antigravity per-model rows).
            footerRow
        }
    }

    @ViewBuilder
    private var footerRow: some View {
        let note = projectionNote
        if reset != nil || note != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let reset {
                    Text(reset)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                Spacer(minLength: 0)
                if let note {
                    Text(note)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Self.warnAccent)
                }
            }
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.95))
        }
    }

    /// Percent renders as bold mono text; only **warn / crit** rows wrap
    /// it in a tinted Capsule "pill". Healthy rows stay clean — most of
    /// the popover is healthy at any given moment, and a colored chip on
    /// every row would just be visual noise. The pill is the alarm
    /// chrome. Padding stays consistent across states (transparent
    /// Capsule for healthy) so row height doesn't jitter when usage
    /// crosses the warn threshold.
    private var pctView: some View {
        Text("\(Int(percent.rounded()))%")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(pctBackground, in: Capsule())
    }

    private var pctBackground: Color {
        switch level {
        case .healthy: .clear
        case .warn:    Color(hue: 38.0/360.0, saturation: 0.92, brightness: 0.55).opacity(0.20)
        case .crit:    Color(hue: 8.0/360.0,  saturation: 0.78, brightness: 0.55).opacity(0.22)
        }
    }

    /// Effective projection — surfaced only when it warrants attention.
    /// The math (`UsageWindow.projectedFinalPercent`) returns nil when the
    /// window is too fresh; we additionally suppress everything ≤ 100%
    /// because a marker that sits on or just past the fill (e.g. current
    /// 29% / projected 31%) is pure noise — the user can already read
    /// "I have headroom" from the bar fill alone. Showing a projection
    /// signal becomes valuable only when it changes their understanding
    /// of risk, which means: only when overshoot is actually predicted.
    private var alarmingProjection: Double? {
        guard let p = projectedPercent, p > 100 else { return nil }
        return p
    }

    /// Footer-right text — only set when there's an alarming projection.
    /// Always uses the warn accent + semibold weight; there's no "safe"
    /// variant anymore (see `alarmingProjection`).
    private var projectionNote: String? {
        guard let p = alarmingProjection else { return nil }
        return "projected \(Int(p.rounded()))%"
    }

    private var level: LimitSafety.Level { LimitSafety.level(for: percent) }

    static let warnAccent = Color(hue: 28.0/360.0, saturation: 0.70, brightness: 0.55)
}

/// The bar host: 4pt thin capsule rail with the fill and an optional
/// dashed projection marker overlay. Reusable for any usage-style row.
///
/// The bar (track + fill) is hard-constrained to `height`. The projection
/// marker lives in an `.overlay` so its vertical overhang is *visual
/// only* — it can extend a few pt above/below the bar without bloating
/// the layout (an early version put it in the ZStack and the bar grew
/// to match the marker's height).
///
/// We deliberately don't draw a "100% reference line" at the bar's right
/// edge. The bar's right edge IS the 100% boundary — an extra rule there
/// read as visual debris. The dashed marker only ever appears in the
/// overshoot case (caller passes `projectedPercent` only when > 100%,
/// see `LimitBar.alarmingProjection`), so the marker always overflows
/// past the right edge and the "vs. the limit" relationship is implicit.
struct ProgressTrack: View {
    let percent: Double
    /// When non-nil, draws a dashed vertical marker at this position
    /// (clamped 0–200% so the bar overflow doesn't run off the card).
    var projectedPercent: Double? = nil
    var level: LimitSafety.Level = .healthy
    var height: CGFloat = 4

    /// 3pt overhang each side gives the marker enough vertical presence
    /// to read against a thin 4pt bar — total marker = 10pt.
    private static let markerOverhang: CGFloat = 3

    var body: some View {
        bar
            .frame(height: height)
            .overlay(alignment: .leading) { markerOverlay }
    }

    private var bar: some View {
        GeometryReader { geo in
            let fillWidth = max(0, geo.size.width * min(percent, 100) / 100)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))

                Capsule()
                    .fill(fillColor)
                    .frame(width: fillWidth)
                    .animation(.easeInOut(duration: 0.4), value: percent)
            }
        }
    }

    @ViewBuilder
    private var markerOverlay: some View {
        if let p = projectedPercent {
            GeometryReader { geo in
                let w = geo.size.width
                let isAlarm = p > 100
                let markerX = w * min(max(p, 0), 200) / 100
                let totalHeight = height + Self.markerOverhang * 2
                let yOffset = -Self.markerOverhang

                DashedMarker(
                    color: isAlarm ? LimitBar.warnAccent : Color.primary.opacity(0.32),
                    totalHeight: totalHeight
                )
                .offset(x: markerX - 0.75, y: yOffset)
            }
            .allowsHitTesting(false)
        }
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

/// A vertical dashed line rendered as a column of axis-aligned
/// rectangles. We tried a single Path stroke with `StrokeStyle.dash`
/// first; the antialiasing on a 1.5pt-wide butt-capped stroke was
/// uneven per dash and the line read as faintly slanted. Stacking
/// integer-height rectangles in a VStack guarantees pixel-aligned
/// segments at any total height.
private struct DashedMarker: View {
    let color: Color
    let totalHeight: CGFloat
    private let dashHeight: CGFloat = 3
    private let gapHeight: CGFloat = 2
    private let strokeWidth: CGFloat = 1.5

    var body: some View {
        VStack(spacing: gapHeight) {
            ForEach(0..<dashCount, id: \.self) { _ in
                Rectangle()
                    .fill(color)
                    .frame(width: strokeWidth, height: dashHeight)
            }
        }
        // Center the dash column inside the overhang frame. With the
        // current bar (4pt + 3pt overhang each side = 10pt) two dashes
        // (3+2+3 = 8pt) sit in the centre with 1pt empty top + 1pt
        // empty bottom — visually balanced. Other bar heights degrade
        // gracefully with the same .center alignment.
        .frame(width: strokeWidth, height: totalHeight, alignment: .center)
    }

    private var dashCount: Int {
        let unit = dashHeight + gapHeight
        return max(1, Int((totalHeight + gapHeight) / unit))
    }
}

#Preview("Limits") {
    VStack(alignment: .leading, spacing: 14) {
        // Healthy, no projection
        LimitBar(name: "5-hour", percent: 6, reset: "resets 4h 46m · 19:00")
        // Healthy with safe projection (suppressed by alarmingProjection)
        LimitBar(name: "Weekly", percent: 31, reset: "resets 5d 12h · Tue 09:00", projectedPercent: 58)
        // Warn band → pct gets amber pill
        LimitBar(name: "Weekly", percent: 78, reset: "resets 3d 4h · Sat 12:00")
        // Crit band + alarm projection → red pill + overflow marker + footer note
        LimitBar(name: "Daily cap", percent: 91, reset: "resets in 4h · 18:30", projectedPercent: 145)
        // Antigravity-style: no reset, no projection, no pill
        LimitBar(name: "flash 47/200", percent: 23, monoName: true)
    }
    .padding(16)
    .frame(width: 320)
}
