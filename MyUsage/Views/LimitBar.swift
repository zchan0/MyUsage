import SwiftUI

/// A single limit row. v4 shape:
///
///     5-hour                                          ← meta (name)
///     ████████░░|░░░░░░│░░░░  47%                     ← 10pt bar w/ fill,
///                                                       projection marker (dashed),
///                                                       100% quota line, % inside
///     resets 2h 14m              projected 118%       ← footer (reset L, note R)
///
/// The bar is the visual anchor: at 10pt it's tall enough to host the
/// percent text, the dashed projection marker, and the 100% quota line
/// without losing legibility. The marker and quota line only render
/// when `projectedPercent` is non-nil (the math gates this — see
/// `UsageWindow.projectedFinalPercent`). When the projection clears
/// 100% the marker overflows past the bar's right edge, the marker +
/// footer note both pick up the warn accent, and the footer wording
/// shifts from `~XX% by reset` to `projected XXX%`.
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
        VStack(alignment: .leading, spacing: 5) {
            nameView

            ProgressTrack(
                percent: percent,
                projectedPercent: projectedPercent,
                level: level
            )

            footerView
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

    @ViewBuilder
    private var footerView: some View {
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
                    Text(note.text)
                        .font(.system(size: 10, weight: note.isAlarm ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(note.isAlarm ? Self.warnAccent : .secondary.opacity(0.7))
                }
            }
        }
    }

    /// Footer-right text + severity flag derived from `projectedPercent`.
    /// Wording shifts at the 100% boundary so the user reads "approaching"
    /// vs. "overshooting" without parsing colour.
    private var projectionNote: (text: String, isAlarm: Bool)? {
        guard let p = projectedPercent else { return nil }
        let rounded = Int(p.rounded())
        if p > 100 {
            return ("projected \(rounded)%", true)
        } else {
            return ("~\(rounded)% by reset", false)
        }
    }

    private var level: LimitSafety.Level { LimitSafety.level(for: percent) }

    static let warnAccent = Color(hue: 28.0/360.0, saturation: 0.70, brightness: 0.55)
}

/// The bar host: 10pt tall capsule rail with the fill, optional dashed
/// projection marker, optional 100% quota reference line, and the percent
/// text right-anchored inside. Reusable for any usage-style row that wants
/// the same visual treatment.
struct ProgressTrack: View {
    let percent: Double
    /// When non-nil, draws a dashed vertical marker at this position
    /// (clamped 0–200% so the bar overflow doesn't run off the card).
    /// The 100% quota reference line is drawn alongside.
    var projectedPercent: Double? = nil
    var level: LimitSafety.Level = .healthy
    var height: CGFloat = 10

    private static let markerWidth: CGFloat = 1.5
    private static let markerOverhang: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillWidth = max(0, w * min(percent, 100) / 100)

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.primary.opacity(0.10))

                // Fill (current usage)
                Capsule()
                    .fill(fillColor)
                    .frame(width: fillWidth)
                    .animation(.easeInOut(duration: 0.4), value: percent)

                // Quota reference line at 100% — only when there's a
                // marker to relate to.
                if projectedPercent != nil {
                    quotaLine.offset(x: w - 0.5)
                }

                // Projected marker — clamped to 200% so a wildly hot
                // burn rate doesn't render off-card.
                if let p = projectedPercent {
                    let isAlarm = p > 100
                    let markerX = w * min(max(p, 0), 200) / 100
                    DashedMarker(color: isAlarm ? LimitBar.warnAccent : Color.primary.opacity(0.30))
                        .frame(width: Self.markerWidth, height: height + Self.markerOverhang * 2)
                        .offset(x: markerX - Self.markerWidth / 2, y: -Self.markerOverhang)
                }

                // Percent text right-anchored inside the bar.
                HStack {
                    Spacer(minLength: 0)
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.85))
                        .shadow(color: pctShadow, radius: 1, x: 0, y: 0)
                        .padding(.trailing, 7)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(height: height)
    }

    /// Soft halo behind the percent text so it stays readable both on the
    /// sage fill (light text on mid-saturation green) and on the gray
    /// track (light text on light gray). Uses background colour so it
    /// adapts to light/dark mode automatically.
    private var pctShadow: Color { Color(.windowBackgroundColor).opacity(0.85) }

    private var quotaLine: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 1, height: height + Self.markerOverhang * 2)
            .offset(y: -Self.markerOverhang)
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

/// A vertical dashed line. We render it as a Path stroke with a dash
/// pattern rather than a series of stacked rectangles so it stays crisp
/// at any height and the dash rhythm renders identically in light/dark
/// without per-segment work.
private struct DashedMarker: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .butt, dash: [3, 2]))
        }
    }
}

#Preview("Limits") {
    VStack(alignment: .leading, spacing: 14) {
        // No projection — fresh window
        LimitBar(name: "5-hour · fresh", percent: 6, reset: "resets 4h 46m")
        // Safe projection
        LimitBar(name: "Weekly · safe", percent: 31, reset: "resets Sun", projectedPercent: 58)
        // Will overshoot (alarm)
        LimitBar(name: "5-hour · burning hot", percent: 47, reset: "resets 2h 14m", projectedPercent: 115)
        // Already in warn band + deep overshoot
        LimitBar(name: "Daily cap · alarm", percent: 88, reset: "resets in 4h", projectedPercent: 145)
        // Antigravity-style: no reset, no projection
        LimitBar(name: "flash 47/200", percent: 23, monoName: true)
    }
    .padding(16)
    .frame(width: 320)
}
