import SwiftUI

struct QuotaRunwayRow: View {
    let win: String
    let percent: Double
    var wide = false
    var pacePercent: Double?
    var reset: String?
    var verdict: String?
    var risk = false
    var detailSummary: String?

    @Environment(\.colorScheme) private var colorScheme
    private var palette: PopoverPalette { PopoverPalette(colorScheme) }

    private var level: LimitSafety.Level {
        max(LimitSafety.level(for: percent), risk ? .warn : .healthy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                Text(win)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.87)
                    .frame(width: wide ? 62 : 24, alignment: .leading)
                    .help(win)

                track

                Text(percent / 100, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(inkColor)
                    .contentTransition(.numericText())
                    .animation(PopoverMotion.numeric, value: Int(percent.rounded()))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.top, 3)

            if reset != nil || verdict != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let reset {
                        Text(reset)
                            .foregroundStyle(palette.inkTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .help(reset)
                    }

                    Spacer(minLength: 0)

                    if let verdict {
                        Text(verdict)
                            .fontWeight(risk ? .medium : .regular)
                            .foregroundStyle(level == .crit && risk ? palette.critInk : (risk ? palette.warnInk : palette.inkTertiary))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .help(detailSummary ?? verdict)
                    }
                }
                .font(.system(size: 10))
                .monospacedDigit()
                .padding(.leading, wide ? 71 : 33)
                .padding(.top, 2.5)
            }
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = min(max(percent, 0), 100) / 100
            let floor: CGFloat = percent > 0 && percent < 3 ? 6 : 0
            Capsule()
                .fill(palette.track)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(fillColor)
                        .overlay {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(colorScheme == .dark ? 0.22 : 0.34), .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                        .frame(width: min(width, max(floor, width * fraction)))
                        .animation(PopoverMotion.meter, value: percent)
                        .animation(PopoverMotion.meter, value: level)
                }
                .overlay(alignment: .topLeading) {
                    if let pacePercent, pacePercent.isFinite {
                        PaceTriangle()
                            .fill(palette.paceTick.opacity(0.78))
                            .frame(width: 6, height: 4)
                            .offset(x: width * min(max(pacePercent, 1), 99) / 100 - 3, y: -6)
                            .animation(PopoverMotion.meter, value: pacePercent)
                    }
                }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var fillColor: Color {
        switch level {
        case .healthy: palette.okFill
        case .warn: palette.warnFill
        case .crit: palette.critFill
        }
    }

    private var inkColor: Color {
        switch level {
        case .healthy: palette.okInk
        case .warn: palette.warnInk
        case .crit: palette.critInk
        }
    }
}

struct PaceTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

extension CapacityFocus.Metric {
    init(providerKind: ProviderKind, label: String, window: UsageWindow, now: Date = .now) {
        self.init(
            providerKind: providerKind, label: label, percentUsed: window.percentUsed, resetsAt: window.resetsAt,
            pacePercent: window.onPacePercent(now: now),
            projectedFinalPercent: window.projectedFinalPercent(now: now),
            projectedExhaustionAt: window.projectedExhaustionDate(now: now)
        )
    }

    var runwayBalance: String? {
        if case .deficit(let percent) = paceBalance {
            return "\(Int(percent.rounded()))% over pace"
        }
        return CapacityPaceText.balanceLabel(for: self)
    }
}
