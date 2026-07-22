import SwiftUI

/// A single limit row: label/value, continuous provider-tinted rail, then
/// reset and pace metadata. Forecasting stays quiet unless usage is projected
/// to cross 100%, keeping routine states calm and comparable.
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
    /// Where the fill would sit right now on a steady burn-100%-across-
    /// the-window pace, from `UsageWindow.onPacePercent(now:)`. Rendered
    /// twice — a solid notch on the track AND a "pace N%" footer note —
    /// so the reading works both geometrically and literally. nil = not
    /// applicable (no window duration, cached snapshot).
    var pacePercent: Double? = nil
    /// When true, this row's cached value is from a window that has since
    /// reset (an inactive multi-account snapshot viewed past its
    /// `resetsAt`). The percentage is no longer meaningful and we can't
    /// fetch the live one, so render an empty muted rail with "—" instead
    /// of a stale number. See `ProviderCardLimits`.
    var expired: Bool = false
    /// Optional provider-brand fill. Severity still lives in the percent and
    /// forecast text; the rail stays visually consistent within a provider.
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Row 1 — name (left) + pct (right).
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                nameView
                Spacer(minLength: 8)
                pctView
            }

            // Row 2 — the bar (4pt sage rail with optional projection
            // marker overlay; marker only renders for projected > 100%).
            // Expired rows force an empty rail — the cached fill would
            // misrepresent a window that has already reset.
            ProgressTrack(
                percent: expired ? 0 : percent,
                projectedPercent: alarmingProjection,
                pacePercent: expired ? nil : pacePercent,
                level: expired ? .healthy : level,
                tint: tint
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
        let pace = paceNote
        if reset != nil || note != nil || pace != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let reset {
                    Text(reset)
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                Spacer(minLength: 0)
                // One right-hand slot: the overshoot alarm outranks the
                // routine pace reading — both at once would crowd the row
                // and the alarm already implies "you're over pace".
                if let note {
                    Text(note)
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Self.warnAccent)
                } else if let pace {
                    Text(pace)
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary.opacity(0.55))
                }
            }
        }
    }

    /// Footer-right pace text — always-on companion to the track notch.
    private var paceNote: String? {
        guard !expired, let pace = pacePercent else { return nil }
        return "pace \(Int(pace.rounded()))%"
    }

    @ViewBuilder
    private var nameView: some View {
        if monoName {
            Text(name)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
        } else {
            Text(name)
                .font(.system(size: 12.5, weight: .semibold))
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
        Text(expired ? "—" : "\(Int(percent.rounded()))%")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(expired ? AnyShapeStyle(.secondary.opacity(0.5)) : AnyShapeStyle(.primary))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(expired ? .clear : pctBackground, in: Capsule())
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
        guard !expired, let p = projectedPercent, p > 100 else { return nil }
        return p
    }

    /// Footer-right text — only set when there's an alarming projection.
    /// Always uses the warn accent + semibold weight; there's no "safe"
    /// variant anymore (see `alarmingProjection`).
    private var projectionNote: String? {
        guard let p = alarmingProjection else { return nil }
        return "projected \(Int(p.rounded()))%"
    }

    /// Severity for the bar fill + pct pill. Takes the **higher** of the
    /// current-usage band and the projection-alarm band — so a row at 58%
    /// (healthy by current usage) but with a projected 274% (clear
    /// overshoot) renders the bar amber, not sage. Without this, the
    /// footer "projected XXX%" note screams while the bar visually says
    /// "you're fine" — confusing and inconsistent.
    private var level: LimitSafety.Level {
        let currentLevel = LimitSafety.level(for: percent)
        guard let projected = alarmingProjection else { return currentLevel }
        // projected > 100 always at least warn; > 150 escalates to crit.
        let projectedLevel: LimitSafety.Level = projected > 150 ? .crit : .warn
        return max(currentLevel, projectedLevel)
    }

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
    /// When non-nil, draws a solid neutral notch at this position — the
    /// on-pace reference. Fill left of the notch = headroom, right =
    /// burning hot. Solid vs the projection marker's dashes so the two
    /// never read as the same signal.
    var pacePercent: Double? = nil
    var level: LimitSafety.Level = .healthy
    var height: CGFloat = 6
    var tint: Color? = nil

    /// 3pt overhang each side gives the marker enough vertical presence
    /// to read against a thin 4pt bar — total marker = 10pt.
    private static let markerOverhang: CGFloat = 3

    var body: some View {
        bar
            .frame(height: height)
            .overlay(alignment: .leading) { paceOverlay }
            .overlay(alignment: .leading) { markerOverlay }
    }

    private var bar: some View {
        GeometryReader { geo in
            let fillWidth = max(0, geo.size.width * min(percent, 100) / 100)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(fillColor)
                    .frame(width: fillWidth)
                    .animation(.easeInOut(duration: 0.4), value: percent)
            }
        }
    }

    @ViewBuilder
    private var paceOverlay: some View {
        if let pace = pacePercent {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(Color.primary.opacity(0.50))
                    .frame(width: 2, height: height + Self.markerOverhang * 2)
                    .offset(
                        x: geo.size.width * min(max(pace, 0), 100) / 100 - 1,
                        y: -Self.markerOverhang
                    )
            }
            .allowsHitTesting(false)
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

    private var fillColor: Color { tint ?? level.accent }
}

extension LimitSafety.Level {
    /// Shared severity accent — bar fills, hero stat numbers, pct pills.
    ///
    /// Sage green for healthy, matched to the safety palette used by
    /// Settings → Sync status indicator. Low saturation keeps the popover
    /// calm while still communicating "this is healthy" — distinguishable
    /// from the neutral-gray track at a glance.
    var accent: Color {
        switch self {
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
        // Healthy, ahead of pace (fill past the notch)
        LimitBar(name: "5-hour", percent: 47, reset: "resets 2h 14m · 16:30", pacePercent: 43)
        // Healthy with headroom (fill behind the notch); safe projection suppressed
        LimitBar(name: "Weekly", percent: 31, reset: "resets 5d 12h · Tue 09:00", projectedPercent: 58, pacePercent: 55)
        // Warn band → pct gets amber pill
        LimitBar(name: "Weekly", percent: 78, reset: "resets 3d 4h · Sat 12:00", pacePercent: 60)
        // Crit band + alarm projection → red pill + overflow marker; alarm
        // note takes the pace slot
        LimitBar(name: "Daily cap", percent: 91, reset: "resets in 4h · 18:30", projectedPercent: 145, pacePercent: 55)
        // Antigravity-style: no reset, no projection, no pill, no pace
        LimitBar(name: "flash 47/200", percent: 23, monoName: true)
    }
    .padding(16)
    .frame(width: 320)
}
