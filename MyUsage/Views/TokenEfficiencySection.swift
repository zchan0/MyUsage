import SwiftUI

/// Replaces the four raw token counters with the readings that actually move.
///
/// Design decisions and their reasons live in
/// `docs/ui-mockups/token-efficiency-v17.html`. The load-bearing ones:
///
/// - The rate is a **stat tile**, not a hero — the detail page already leads
///   with the 5-hour percentage, and a view gets one hero.
/// - The meter's track is a lighter step of the provider's own hue rather than
///   a neutral gray, so the reading carries across the whole bar.
/// - The TTL notice pairs an icon and a sentence with the accent colour. It
///   never leans on hue alone — which also sidesteps a measured weakness in the
///   app's warn/crit pair (ΔE 11.1 unsimulated, below the legibility floor).
struct TokenEfficiencySection: View {
    let kind: ProviderKind
    let reading: TokenEfficiency.Reading

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rateRow.padding(.top, 10)
            meter.padding(.top, 11)
            if case .downgraded(let share) = reading.cacheTTL {
                CacheTTLNotice(sharePercent: share).padding(.top, 11)
            }
            footnote.padding(.top, 8)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Token efficiency")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("30 days · all accounts")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var rateRow: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(rateText)
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                Text("/Mtok")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Sparkline(values: reading.dailyRates, tint: tint)
                .frame(height: 26)
        }
        .help("Dollars per million tokens processed — model mix and cache efficiency in one number.")
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cache hits")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(reading.cacheHitPercent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.18))
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * min(1, reading.cacheHitPercent / 100))
                }
            }
            .frame(height: 5)
        }
        .help("Share of prompt tokens served from cache. Reads cost a tenth of fresh input.")
    }

    private var footnote: some View {
        Text(footnoteText)
            .font(.system(size: 9, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private var footnoteText: String {
        let total = TokenCountFormatter.string(reading.totalTokens)
        let output = String(format: "%.1f", reading.outputPercent)
        let reCache = String(format: "%.0f", reading.reCachePercent)
        return "\(total) tokens · \(output)% output · \(reCache)% re-cached"
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
}

/// The alert this section exists for. A prompt-cache TTL downgrade is
/// server-side, invisible everywhere else, and expensive — context stops
/// surviving normal idle gaps, so it gets rebuilt several times as often.
///
/// The copy names the cause and the recovery condition, because an alert the
/// user cannot act on is just an alarm.
private struct CacheTTLNotice: View {
    let sharePercent: Double

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
        .help("Exhausting the 5-hour quota makes the server grant the short-lived cache instead of the 1-hour one.")
    }

    private var detail: String {
        "\(Int(sharePercent.rounded()))% of cache writes are short-lived — context expires after minutes, not an hour. Lifts when the 5-hour window resets."
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
        TokenEfficiencySection(
            kind: .claude,
            reading: TokenEfficiency.Reading(
                effectiveRate: 1.30, cacheHitPercent: 97, reCachePercent: 3,
                outputPercent: 0.5, totalTokens: 772_000_000,
                dailyRates: [1.2, 1.5, 1.1, 1.9, 1.0, 1.4, 0.9, 1.3, 1.6, 1.2, 1.4, 1.1, 1.3, 1.3],
                cacheTTL: .standard
            )
        )
        Divider()
        TokenEfficiencySection(
            kind: .claude,
            reading: TokenEfficiency.Reading(
                effectiveRate: 1.78, cacheHitPercent: 90, reCachePercent: 10,
                outputPercent: 0.5, totalTokens: 772_000_000,
                dailyRates: [1.2, 1.5, 1.1, 1.9, 1.0, 1.4, 0.9, 1.3, 1.6, 1.2, 1.5, 1.9, 2.1, 2.4],
                cacheTTL: .downgraded(sharePercent: 36)
            )
        )
    }
    .padding(16)
    .frame(width: PopoverLayout.width)
}
#endif
