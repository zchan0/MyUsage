import SwiftUI

struct ProviderUsageInstrument: View {
    private enum Scope: String, CaseIterable {
        case today = "Today"
        case thirtyDays = "30d"
    }

    let report: LocalUsageReport
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var scopeNamespace
    @State private var scope: Scope = .thirtyDays
    @State private var hoveredIndex: Int?
    @State private var hoveredScope: Scope?

    private var palette: PopoverPalette { PopoverPalette(colorScheme) }

    var body: some View {
        let summary = scope == .today ? report.summaryToday : report.summary30d
        let slots = scope == .today ? report.hours : report.days
        let hoveredSlot = hoveredIndex.flatMap { slots.indices.contains($0) ? slots[$0] : nil }
        let tokens = hoveredSlot?.totalTokens ?? summary.totalTokens

        GlassSheet {
            VStack(alignment: .leading, spacing: 0) {
                header(summary: summary, hoveredSlot: hoveredSlot, tokens: tokens)
                sparkbars(slots)
                    .padding(.top, 11)
                axis(slots)
                    .padding(.top, 4)

                if !report.orderedModelNames.isEmpty {
                    PopoverHairline()
                        .padding(.top, 11)
                    let rows = hoveredSlot.map { report.modelRows(for: $0) } ?? report.modelRows(for: summary)
                    VStack(spacing: 6.5) {
                        ForEach(rows) { row in modelRow(row, totalTokens: tokens) }
                    }
                    .padding(.top, 9)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
        }
    }

    private func header(
        summary: LocalUsageReport.ScopeSummary,
        hoveredSlot: LocalUsageReport.Bucket?,
        tokens: Int
    ) -> some View {
        let cost = hoveredSlot?.reportedCostUSD ?? summary.reportedCostUSD
        let hit = hoveredSlot.map(\.cacheHitRate) ?? summary.cacheHitRate
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(TokenCountFormatter.string(tokens))
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.475)
                        .monospacedDigit()
                        .foregroundStyle(palette.inkPrimary)
                    Text("tokens")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.inkTertiary)
                }
                .accessibilityElement(children: .combine)
                subtitle(label: hoveredSlot?.label, tokens: tokens, hit: hit, cost: cost)
            }
            Spacer(minLength: 0)
            scopePill
        }
    }

    private func subtitle(label: String?, tokens: Int, hit: Double?, cost: Double) -> some View {
        let cache = hit.flatMap { rate in rate > 0 ? String(format: "%.1f%% cache", rate) : nil }
        let showsCost = report.hasReportedCost && cost > 0
        let hasActivityDetail = cache != nil || showsCost || tokens == 0

        return HStack(spacing: 4) {
            if let label {
                Text(label)
                    .fontWeight(.medium)
                    .foregroundStyle(palette.inkPrimary)
                if hasActivityDetail { separator }
            }

            if let cache {
                Text(cache)
                if showsCost { separator }
            }

            if showsCost {
                let amount = costText(cost)
                Text(label != nil && tokens == 0 ? "\(amount) settled" : amount)
                    .fontWeight(.medium)
                    .foregroundStyle(palette.inkPrimary)
            } else if tokens == 0 {
                Text("No activity recorded")
            }
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(palette.inkSecondary)
        .lineLimit(1)
        .frame(minHeight: 13, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var separator: some View {
        Text("·").foregroundStyle(palette.inkQuaternary).accessibilityHidden(true)
    }

    private var scopePill: some View {
        HStack(spacing: 0) {
            ForEach(Scope.allCases, id: \.self) { option in
                let selected = option == scope
                Button {
                    withAnimation(PopoverMotion.selection) {
                        scope = option
                        hoveredIndex = nil
                    }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected || hoveredScope == option ? palette.inkPrimary : palette.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background {
                            if selected {
                                PopoverLens(shape: Capsule())
                                    .matchedGeometryEffect(id: "scopeLens", in: scopeNamespace)
                                    .transition(.identity)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hoveredScope = option }
                    else if hoveredScope == option { hoveredScope = nil }
                }
                .animation(PopoverMotion.hover, value: hoveredScope)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(width: 92)
        .background { PopoverWell(shape: Capsule()) }
    }

    private func sparkbars(_ slots: [LocalUsageReport.Bucket]) -> some View {
        let counts = slots.map(\.totalTokens)
        let maxTokens = max(1, counts.max() ?? 0)
        let currentIndex: Int? = switch scope {
        case .thirtyDays:
            counts.indices.last
        case .today:
            Calendar.current.component(.hour, from: .now)
        }
        let gap: CGFloat = 3

        return GeometryReader { geometry in
            let slotCount = counts.count
            let width = max(0, (geometry.size.width - gap * CGFloat(max(0, slotCount - 1))) / CGFloat(max(1, slotCount)))
            let stride = width + gap
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(counts.indices, id: \.self) { index in
                    let tokens = counts[index]
                    let focused = hoveredIndex == index
                    let dimmed = hoveredIndex != nil && !focused
                    let isCurrent = index == currentIndex && tokens > 0
                    let height = tokens > 0 ? max(0.11, sqrt(Double(tokens) / Double(maxTokens))) : 0.04
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(barColor(tokens: tokens, focused: focused, isCurrent: isCurrent))
                        .opacity(dimmed ? 0.38 : (isCurrent && !focused ? 0.85 : 1))
                        .animation(PopoverMotion.hover, value: hoveredIndex)
                        .frame(width: width, height: max(2, geometry.size.height * height))
                        .animation(PopoverMotion.meter, value: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .overlay {
                if let hoveredIndex, counts.indices.contains(hoveredIndex) {
                    Rectangle()
                        .fill(palette.inkTertiary.opacity(0.35))
                        .frame(width: 1, height: geometry.size.height)
                        .position(x: CGFloat(hoveredIndex) * stride + width / 2, y: geometry.size.height / 2)
                        .animation(PopoverMotion.hover, value: hoveredIndex)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(PopoverMotion.hover, value: hoveredIndex == nil)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard slotCount > 0, stride > 0 else { return }
                    let rawIndex = Int((max(0, location.x) + gap / 2) / stride)
                    hoveredIndex = max(0, min(rawIndex, slotCount - 1))
                case .ended:
                    hoveredIndex = nil
                }
            }
        }
        .frame(height: 50)
        .accessibilityHidden(true)
    }

    private func barColor(tokens: Int, focused: Bool, isCurrent: Bool) -> Color {
        if focused { return palette.sparkFocus }
        if tokens == 0 { return palette.sparkEmpty }
        return isCurrent ? palette.sparkToday : palette.sparkIdle
    }

    private func axis(_ slots: [LocalUsageReport.Bucket]) -> some View {
        HStack {
            Text(slots.first?.label ?? "")
            Spacer()
            Text(slots.last?.label ?? "")
        }
        .overlay {
            Text(scope == .today ? "Today hourly" : "30-day trend")
        }
        .font(.system(size: 9.5))
        .monospacedDigit()
        .foregroundStyle(palette.inkTertiary)
    }

    private func modelRow(_ row: LocalUsageReport.ModelSummary, totalTokens: Int) -> some View {
        let share = row.tokens > 0 ? max(0.08, Double(row.tokens) / Double(max(1, totalTokens))) : 0
        let dimmed = row.tokens == 0 && row.reportedCostUSD <= 0
        return HStack(spacing: 8) {
            Capsule()
                .fill(palette.track)
                .frame(width: 28, height: 3.5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(palette.inkSecondary.opacity(0.62))
                        .frame(width: 28 * min(1, share))
                        .animation(PopoverMotion.meter, value: share)
                }
                .accessibilityHidden(true)

            Text(row.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.inkPrimary)
                .lineLimit(1)
                .help(row.name)

            Spacer(minLength: 0)

            if row.tokens > 0, let hit = row.cacheHitRate, hit > 0 {
                Text("\(Int(hit.rounded()))%")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.inkTertiary)
                    .accessibilityLabel("\(Int(hit.rounded())) percent cache hit")
            }

            Text(TokenCountFormatter.string(row.tokens))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)
                .frame(minWidth: 44, alignment: .trailing)
                .accessibilityLabel("\(row.tokens) tokens")

            if report.hasReportedCost {
                Text(row.reportedCostUSD > 0 ? costText(row.reportedCostUSD) : "—")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.inkSecondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .monospacedDigit()
        .opacity(dimmed ? 0.36 : 1)
        .animation(PopoverMotion.hover, value: dimmed)
        .accessibilityElement(children: .combine)
    }

    private func costText(_ cost: Double) -> String {
        String(format: "$%.2f", cost)
    }
}

#if DEBUG
#Preview("Local usage · Claude · Light") {
    ProviderUsageInstrument(report: PreviewFixtures.localUsage(for: .claude))
        .padding(11)
        .frame(width: PopoverLayout.width)
        .background { PopoverGlassSurface() }
        .preferredColorScheme(.light)
}

#Preview("Local usage · Claude · Dark") {
    ProviderUsageInstrument(report: PreviewFixtures.localUsage(for: .claude))
        .padding(11)
        .frame(width: PopoverLayout.width)
        .background { PopoverGlassSurface() }
        .preferredColorScheme(.dark)
}

#Preview("Local usage · Codex") {
    ProviderUsageInstrument(report: PreviewFixtures.localUsage(for: .codex))
        .padding(11)
        .frame(width: PopoverLayout.width)
        .background { PopoverGlassSurface() }
}
#endif
