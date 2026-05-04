import SwiftUI

/// A single limit row. v0.9 shape:
///
///     5-hour 47%                              resets 2h 14m   ← meta (name + pct L,
///                                                                     reset R)
///     ░░░░░░░░░░░░░░░░░░│░░░░░░░░░░░░░░░░                    ← 4pt bar (sage by
///                                                                     default; warn/crit
///                                                                     fill at 75/90)
///                                          projected 118%     ← alarm-only footer
///                                                              (right-aligned, warn
///                                                              amber, only when
///                                                              projection > 100%)
///
/// The bar reverts to the thin 4pt rail it was before v0.8. Putting the
/// percent inside a fatter bar made the bar feel chunky relative to the
/// rest of the card; pulling pct out into the meta row lets the bar do
/// what bars do best — a discrete, slim spatial signal — while the
/// numeric reading sits with its semantic neighbours (name, reset).
///
/// The dashed projection marker still rides as an .overlay on the bar,
/// but only when the projection actually crosses 100% (see
/// `alarmingProjection`). Healthy projections stay silent — bar fill
/// alone communicates "you have headroom".
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
            metaRow

            ProgressTrack(
                percent: percent,
                projectedPercent: alarmingProjection,
                level: level
            )

            if let note = projectionNote {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(note)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Self.warnAccent)
                }
            }
        }
    }

    /// Top row: name + percent on the left as a unit, reset right-aligned.
    /// When reset is nil (Antigravity per-model rows) the row collapses
    /// to just `name pct` on the left with no phantom right slot.
    private var metaRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            nameView
            pctView
            Spacer(minLength: 8)
            if let reset {
                Text(reset)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary.opacity(0.7))
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

    /// Percent is the headline number on this row — bigger (13pt) and
    /// heavier (bold) than the 11pt semibold name, so the eye lands on
    /// the digit first and the name reads as its label. With
    /// `.firstTextBaseline` alignment the larger cap height naturally
    /// rises above the name's cap, reinforcing the label → value
    /// relationship without any explicit baseline gymnastics.
    private var pctView: some View {
        Text("\(Int(percent.rounded()))%")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(pctColor)
    }

    /// Percent text colour mirrors the bar fill's safety level. The bar
    /// fill already shows warn/crit, but having the number adopt the
    /// same hue makes the state pop in the meta row without forcing the
    /// user to read the bar to confirm.
    private var pctColor: Color {
        switch level {
        case .healthy: .primary
        case .warn:    Color(hue: 38.0/360.0, saturation: 0.92, brightness: 0.62)
        case .crit:    Color(hue: 8.0/360.0,  saturation: 0.78, brightness: 0.66)
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
        // No projection — fresh window (math gated)
        LimitBar(name: "5-hour · fresh", percent: 6, reset: "resets 4h 46m")
        // Projection ≤ 100% — silent (noise-gated; pure visual would be
        // a marker right next to the fill which adds nothing)
        LimitBar(name: "Weekly · calm", percent: 31, reset: "resets Sun", projectedPercent: 58)
        // Will overshoot — marker overflows past right edge, footer alarm
        LimitBar(name: "5-hour · burning hot", percent: 47, reset: "resets 2h 14m", projectedPercent: 115)
        // Already in warn band + deep overshoot
        LimitBar(name: "Daily cap · alarm", percent: 88, reset: "resets in 4h", projectedPercent: 145)
        // Antigravity-style: no reset, no projection
        LimitBar(name: "flash 47/200", percent: 23, monoName: true)
    }
    .padding(16)
    .frame(width: 320)
}
