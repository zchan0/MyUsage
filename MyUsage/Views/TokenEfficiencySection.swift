import SwiftUI

/// Replaces the four raw token counters with the readings that actually move.
///
/// Design decisions and their reasons live in
/// `docs/ui-mockups/token-efficiency-v17.html`, which records the layout as
/// first shipped. The load-bearing ones:
///
/// - The rate is a **stat tile**, not a hero — the detail page already leads
///   with the 5-hour percentage, and a view gets one hero.
/// - The TTL notice pairs an icon and a sentence with the accent colour. It
///   never leans on hue alone — which also sidesteps a measured weakness in the
///   app's warn/crit pair (ΔE 11.1 unsimulated, below the legibility floor).
///
/// One departure from that mockup: the cache-hit meter it shows is gone. On
/// real data the ratio never leaves 91–98%, so the bar was always nearly full
/// and no reading of it changed anything. See `TokenEfficiency`.
struct TokenEfficiencySection: View {
    let kind: ProviderKind
    let reading: TokenEfficiency.Reading
    /// The current 5-hour window. The TTL notice needs both halves of it: the
    /// reset time, because the downgrade lifts at that moment and naming the
    /// countdown turns "wait" into a decision; and the percentage, because
    /// exhausting this window is what causes the downgrade in the first place.
    var session: UsageWindow?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rateRow.padding(.top, 10)
            if case .downgraded(let share) = reading.cacheTTL, sessionIsSpent {
                CacheTTLNotice(sharePercent: share, resetsAt: session?.resetsAt)
                    .padding(.top, 11)
            }
            footnote.padding(.top, 9)
        }
    }

    /// The server grants the 5-minute TTL *because* the 5-hour quota ran out,
    /// so a window nowhere near its cap is proof the downgrade is not live —
    /// whatever short-lived writes are sitting in today's totals came from a
    /// window that has since rolled over. Without this gate the notice can
    /// claim the quota is exhausted directly below a bar reading 0% used.
    ///
    /// Not 100%: the reported percentage lags the transcript, and the notice
    /// is worth showing while the cap is being approached.
    private var sessionIsSpent: Bool {
        guard let session else { return false }
        return session.percentUsed >= 80
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Token efficiency")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(dayLabel) · all accounts")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
    }

    /// A quiet day falls below the volume floor and the headline falls back to
    /// the last day that clears it, which can be a week old. Saying "today"
    /// over that is simply false — and it is the kind of false a user only
    /// catches by recognising their own numbers from last week.
    private var dayLabel: String {
        reading.isCurrentDay ? "today" : LedgerCalendar.shortLabel(for: reading.day)
    }

    /// The same day, worded to sit inside a sentence.
    private var dayPhrase: String {
        reading.isCurrentDay ? "today" : "on \(dayLabel)"
    }

    private var rateRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(rateText)
                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                    Text("/Mtok")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                if let delta = deltaText {
                    Text(delta)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Self.readableInk)
                }
            }
            Sparkline(values: reading.dailyRates, tint: tint)
                .frame(height: 26)
        }
        .help(rateExplanation)
    }

    /// What the number is and why it moves. Nothing else in the popover
    /// states a unit price, so it cannot be inferred from context.
    private var rateExplanation: String {
        var text = "What a million tokens of work cost you \(dayPhrase): spend "
            + "divided by tokens processed. It rises when a pricier model does "
            + "more of the work, or when less of the context comes from cache."
        if let baseline = reading.baselineRate {
            text += String(format: " Your recent median is $%.2f.", baseline)
        }
        return text
    }

    /// Spelled out rather than an arrow: a bare ↑ next to a price reads as
    /// "went up" without saying against what.
    private var deltaText: String? {
        guard let delta = reading.deltaPercent, abs(delta) >= 1 else { return nil }
        let direction = delta > 0 ? "above" : "below"
        return "\(Int(abs(delta).rounded()))% \(direction) your usual"
    }

    private var footnote: some View {
        Text(footnoteText)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Self.readableInk)
            .lineLimit(1)
            .help(footnoteExplanation)
    }

    /// "Processed", not "used". The figure is the billing denominator, and on
    /// an agentic client roughly 95% of it is one context re-read turn after
    /// turn — reading it as "how much I made today" is wrong by two orders of
    /// magnitude, so the word has to carry that.
    private var footnoteText: String {
        let total = TokenCountFormatter.string(reading.totalTokens)
        let generated = TokenCountFormatter.string(reading.generatedTokens)
        let reCached = TokenCountFormatter.string(reading.reCachedTokens)
        return "\(total) processed · \(generated) generated · \(reCached) re-cached"
    }

    /// The composition is the surprising part and the reason the total looks
    /// enormous, so it is one hover away rather than left to be guessed at.
    private var footnoteExplanation: String {
        return "Everything the model read or wrote \(dayPhrase) — the denominator "
            + "the rate is priced against. Most of it is the same context re-read "
            + "each turn, which is why the total dwarfs what was generated "
            + "(\(String(format: "%.1f", reading.outputPercent))% of it)."
    }

    /// Sub-dollar rates need a second decimal to move at all; past $10 the
    /// cents are noise.
    private var rateText: String {
        let rate = reading.effectiveRate
        return rate >= 10
            ? String(format: "$%.1f", rate)
            : String(format: "$%.2f", rate)
    }

    private var tint: Color { kind.usageTint(for: colorScheme) }

    /// Ink for the small monospaced lines that carry figures.
    ///
    /// `.secondary` is not enough here. Measured on the real popover surface it
    /// renders #868686 — 3.25:1, under the 4.5:1 floor for text this size — and
    /// neither a heavier weight nor a larger size moved it, because the
    /// hierarchical style itself is the ceiling. An explicit opacity is the only
    /// lever that does. Verified by sampling the rendered panel, not assumed.
    static let readableInk = Color.primary.opacity(0.80)
}

/// The alert this section exists for. A prompt-cache TTL downgrade is
/// server-side, invisible everywhere else, and expensive — context stops
/// surviving normal idle gaps, so it gets rebuilt several times as often.
///
/// **The body says what to do, not what happened.** The title already carries
/// the diagnosis, and the user cannot lift the downgrade — it is server-side.
/// What they can do is pace around it: work without long pauses so the
/// short-lived cache keeps getting refreshed, or stop until the window rolls
/// over. Naming the countdown makes that a real choice rather than "wait a
/// while". The measurement that triggered the notice moves to the tooltip,
/// where it belongs — it explains the alert, it is not the instruction.
private struct CacheTTLNotice: View {
    let sharePercent: Double
    let resetsAt: Date?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cache TTL downgraded to 5m")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(accent.opacity(colorScheme == .dark ? 0.13 : 0.10), in: RoundedRectangle(cornerRadius: 6))
        .help(diagnosis)
    }

    /// Imperative first. The countdown is the second half because it turns
    /// "or wait" into a decision — a 12-minute wait and a 3-hour one call for
    /// different behaviour, and the panel already knows which this is.
    private var detail: String {
        guard let resetsAt, resetsAt > .now else {
            return "Keep gaps under 5 min until the 5-hour window resets."
        }
        let countdown = OverviewSummary.shortCountdown(until: resetsAt)
        return "Keep gaps under 5 min. The 1-hour cache returns in \(countdown)."
    }

    /// Why the notice appeared, for anyone who wants to check it.
    private var diagnosis: String {
        "\(Int(sharePercent.rounded()))% of recent cache writes are short-lived. "
            + "Exhausting the 5-hour quota makes the server grant the 5-minute "
            + "cache instead of the 1-hour one, so context stops surviving idle gaps."
    }

    /// Lifted on the dark surface: the stock accent measures 1.78:1 there,
    /// well under the 3:1 floor.
    private var accent: Color {
        colorScheme == .dark
            ? Color(hue: 26.0 / 360.0, saturation: 0.58, brightness: 0.85)
            : LimitBar.warnAccent
    }
}

/// Trend line for the effective rate. Recessive by design — the series is
/// context for the number beside it, so only the current point takes the
/// accent, ringed in the surface colour so it reads against the line.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    /// The popover sits on a translucent material, so `.background` resolves
    /// to something near-transparent. The ring needs a literal surface tone.
    private var surfaceRing: Color {
        colorScheme == .dark
            ? Color(red: 0.169, green: 0.176, blue: 0.192)
            : Color(white: 0.949)
    }

    var body: some View {
        GeometryReader { geo in
            if let points = points(in: geo.size) {
                ZStack {
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(
                        Color.primary.opacity(0.30),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                    if let last = points.last {
                        // 2px surface ring per the mark spec — without an
                        // opaque ring the dot merges into the line it sits on.
                        Circle()
                            .fill(Color.primary.opacity(0.001))
                            .frame(width: 9, height: 9)
                            .overlay(
                                Circle()
                                    .fill(tint)
                                    .frame(width: 5.5, height: 5.5)
                                    .overlay(
                                        Circle().strokeBorder(surfaceRing, lineWidth: 2)
                                            .frame(width: 9, height: 9)
                                    )
                            )
                            .position(last)
                    }
                }
            }
        }
    }

    /// nil when there is not enough of a series to draw a line. A flat series
    /// is centred rather than divided by a zero range.
    private func points(in size: CGSize) -> [CGPoint]? {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return nil }
        let inset: CGFloat = 3
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let range = high - low
        let usableHeight = size.height - inset * 2
        let step = (size.width - inset * 2) / CGFloat(values.count - 1)

        return values.enumerated().map { index, value in
            let fraction = range > 0 ? (value - low) / range : 0.5
            return CGPoint(
                x: inset + CGFloat(index) * step,
                y: inset + usableHeight * (1 - fraction)
            )
        }
    }
}

#if DEBUG
#Preview("Token efficiency") {
    VStack(spacing: 0) {
        // Healthy, current day.
        TokenEfficiencySection(
            kind: .claude,
            reading: TokenEfficiency.Reading(
                effectiveRate: 1.30, baselineRate: 1.28,
                day: LedgerCalendar.dayKey(for: .now), isCurrentDay: true,
                outputPercent: 0.5, generatedTokens: 260_000,
                reCachedTokens: 1_600_000, totalTokens: 52_000_000,
                dailyRates: [1.2, 1.5, 1.1, 1.9, 1.0, 1.4, 0.9, 1.3, 1.6, 1.2, 1.4, 1.1, 1.3, 1.3],
                cacheTTL: .standard
            ),
            session: UsageWindow(percentUsed: 12, resetsAt: .now.addingTimeInterval(4 * 3600))
        )
        Divider()
        // Live downgrade: today's writes are short-lived *and* the window
        // that causes it is nearly spent. Both halves are required.
        TokenEfficiencySection(
            kind: .claude,
            reading: TokenEfficiency.Reading(
                effectiveRate: 1.78, baselineRate: 1.28,
                day: LedgerCalendar.dayKey(for: .now), isCurrentDay: true,
                outputPercent: 0.5, generatedTokens: 260_000,
                reCachedTokens: 1_600_000, totalTokens: 52_000_000,
                dailyRates: [1.2, 1.5, 1.1, 1.9, 1.0, 1.4, 0.9, 1.3, 1.6, 1.2, 1.5, 1.9, 2.1, 2.4],
                cacheTTL: .downgraded(sharePercent: 36)
            ),
            session: UsageWindow(
                percentUsed: 97,
                resetsAt: .now.addingTimeInterval(2 * 3600 + 31 * 60)
            )
        )
        Divider()
        // Quiet stretch: the headline falls back to the last day with volume,
        // and says so rather than calling week-old numbers "today".
        TokenEfficiencySection(
            kind: .claude,
            reading: TokenEfficiency.Reading(
                effectiveRate: 0.76, baselineRate: 1.28,
                day: "2026-08-01", isCurrentDay: false,
                outputPercent: 0.2, generatedTokens: 425_000,
                reCachedTokens: 7_600_000, totalTokens: 212_000_000,
                dailyRates: [1.2, 1.5, 1.1, 1.9, 1.0, 1.4, 0.9, 1.3, 1.6, 0.76],
                cacheTTL: .unknown
            ),
            session: UsageWindow(percentUsed: 0, resetsAt: .now.addingTimeInterval(4 * 3600))
        )
    }
    .padding(16)
    .frame(width: PopoverLayout.width)
}
#endif
