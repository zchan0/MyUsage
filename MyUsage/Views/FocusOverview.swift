import SwiftUI

/// Priority-led overview for two or more enabled providers. One window gets
/// the visual emphasis; every other provider remains one-click reachable in a
/// compact watchlist. Cost is deliberately last because it is context, not a
/// capacity alarm.
struct FocusOverview: View {
    let providers: [any UsageProvider]
    @Binding var selection: PopoverTab

    @Environment(UsageManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let focusMetric {
                focusInstrument(focusMetric)
                    .padding(.horizontal, 16)
            } else {
                Text("Waiting for usage data")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            }

            if !watchProviders.isEmpty {
                watchlist
            }

            if manager.showEstimatedCost {
                costDock
            }
        }
    }

    private func focusInstrument(_ metric: CapacityFocus.Metric) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                ProviderIconTile(kind: metric.providerKind, size: 23, glyph: 13.5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.providerKind.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(metric.label)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.72))
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(Int(metric.percentUsed.rounded()))%")
                            .font(.system(size: 18.5, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(LimitSafety.level(for: metric.percentUsed).accent)
                        Text("used")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.72))
                    }

                    if let pace = metric.pacePercent {
                        PaceReadout(percentUsed: metric.percentUsed, pacePercent: pace)
                    }

                    if let projected = metric.projectedFinalPercent, projected > 100 {
                        Text("Projected \(Int(projected.rounded()))% at reset")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(LimitBar.warnAccent)
                    }
                }
            }

            ProgressTrack(
                percent: metric.percentUsed,
                pacePercent: metric.pacePercent,
                level: LimitSafety.level(for: metric.percentUsed),
                height: 6
            )
            .padding(.top, 12)

            ResetCountdownReadout(resetsAt: metric.resetsAt)
                .padding(.top, 12)

            let siblings = allMetrics.filter {
                $0.providerKind == metric.providerKind && $0.id != metric.id
            }
            if !siblings.isEmpty {
                ForEach(Array(siblings.prefix(2))) { sibling in
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 0.5)
                        .padding(.top, 14)

                    secondaryInstrument(sibling)
                        .padding(.top, 14)
                }
            }

            if let inventory = resetInventory(for: metric.providerKind) {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
                    .padding(.top, 12)
                ResetCreditsInlineSummary(inventory: inventory)
                    .padding(.top, 10)
            } else if metric.providerKind == .codex {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
                    .padding(.top, 12)
                HStack {
                    Text("Reset credits")
                    Spacer()
                    Text("Unavailable")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
            }
        }
        .padding(.vertical, 20)
        .overlay(alignment: .top) { divider }
        .overlay(alignment: .bottom) { divider }
        .contentShape(Rectangle())
        .onTapGesture { selection = .provider(metric.providerKind) }
        .help("Open \(metric.providerKind.displayName)")
    }

    private func secondaryInstrument(_ metric: CapacityFocus.Metric) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(metric.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.92))
                    .padding(.top, 2)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(Int(metric.percentUsed.rounded()))%")
                            .font(.system(size: 15.5, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(LimitSafety.level(for: metric.percentUsed).accent)
                        Text("used")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.72))
                    }

                    if let pace = metric.pacePercent {
                        PaceReadout(percentUsed: metric.percentUsed, pacePercent: pace)
                    }
                }
            }

            ProgressTrack(
                percent: metric.percentUsed,
                pacePercent: metric.pacePercent,
                level: LimitSafety.level(for: metric.percentUsed),
                height: 5
            )
            .padding(.top, 10)

            ResetCountdownReadout(resetsAt: metric.resetsAt)
                .padding(.top, 10)
        }
    }

    private var watchlist: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("WATCHLIST")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                Spacer()
                Text("ORDERED BY PRESSURE")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.58))
            }
            .foregroundStyle(.secondary.opacity(0.82))
            .padding(.bottom, 9)

            ForEach(watchProviders, id: \.kind) { provider in
                Button {
                    selection = .provider(provider.kind)
                } label: {
                    watchRow(provider)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private func watchRow(_ provider: any UsageProvider) -> some View {
        let metrics = provider.snapshot.map {
            Array(CapacityFocus.metrics(providerKind: provider.kind, snapshot: $0).prefix(2))
        } ?? []

        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ProviderIconTile(kind: provider.kind, size: 24, glyph: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.kind.shortName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(watchCaption(provider))
                        .font(.system(size: 10))
                        .foregroundStyle(
                            provider.snapshot?.resetCredits == nil
                                ? AnyShapeStyle(.tertiary)
                                : AnyShapeStyle(Color.accentColor.opacity(0.82))
                        )
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            if metrics.isEmpty {
                Text(provider.error == nil ? "Waiting for data" : "Unavailable")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(metrics) { metric in
                        WatchMetric(metric: metric)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { divider }
        .contentShape(Rectangle())
    }

    private var costDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("ESTIMATED COST")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.78))
                Spacer()
                if let delta = OverviewSummary.deltaCaption(
                    today: todayCost,
                    average: OverviewSummary.trailingDailyAverage(dailyCosts: manager.ledger.dailyCosts)
                ) {
                    Text(delta)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                if let series = OverviewSummary.trailingDailySeries(dailyCosts: manager.ledger.dailyCosts) {
                    CostSparkline(values: series, width: 106, height: 36)
                } else {
                    Rectangle()
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 106, height: 1)
                }
                Spacer(minLength: 0)
                CostDockStat(label: "TODAY", value: ProviderCardCostRow.formatCost(todayCost))
                CostDockStat(label: "THIS MONTH", value: ProviderCardCostRow.formatCost(monthCost))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .overlay(alignment: .top) { divider }
    }

    private var allMetrics: [CapacityFocus.Metric] {
        providers.flatMap { provider in
            provider.snapshot.map {
                CapacityFocus.metrics(providerKind: provider.kind, snapshot: $0)
            } ?? []
        }
    }

    private var focusMetric: CapacityFocus.Metric? {
        CapacityFocus.select(from: allMetrics)
    }

    private var watchProviders: [any UsageProvider] {
        providers
            .filter { $0.kind != focusMetric?.providerKind }
            .sorted { pressure(of: $0) > pressure(of: $1) }
    }

    private func pressure(of provider: any UsageProvider) -> Double {
        guard let snapshot = provider.snapshot else { return -1 }
        return CapacityFocus.metrics(providerKind: provider.kind, snapshot: snapshot)
            .map(\.riskScore).max() ?? -1
    }

    private func resetInventory(for kind: ProviderKind) -> ResetCreditInventory? {
        providers.first { $0.kind == kind }?.snapshot?.resetCredits
    }

    private func watchCaption(_ provider: any UsageProvider) -> String {
        if let count = provider.snapshot?.resetCredits?.reportedAvailableCount {
            return "\(count) reset credit\(count == 1 ? "" : "s")"
        }
        return provider.snapshot?.planName ?? ""
    }

    private var todayCost: Double {
        OverviewSummary.todayTotal(dailyCosts: manager.ledger.dailyCosts)
    }

    private var monthCost: Double {
        let monthKey = LedgerCalendar.monthKey(for: .now)
        if let ledgerTotal = OverviewSummary.monthTotal(
            monthlyTotals: manager.ledger.monthlyTotals,
            monthKey: monthKey
        ) {
            return ledgerTotal
        }
        return providers.compactMap { $0.snapshot?.monthlyEstimatedCost }.reduce(0, +)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
    }
}

private struct WatchMetric: View {
    let metric: CapacityFocus.Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(metric.percentUsed.rounded()))%")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                Text(metric.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            ProgressTrack(
                percent: metric.percentUsed,
                pacePercent: metric.pacePercent,
                level: LimitSafety.level(for: metric.percentUsed),
                height: 5
            )
            if let reset = metric.resetsAt {
                Text("\(OverviewSummary.shortCountdown(until: reset)) to reset")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

private struct CostDockStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 15.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 76, alignment: .leading)
    }
}

#if DEBUG
#Preview("Focus Overview") {
    struct Host: View {
        let manager = PreviewFixtures.manager(providerCount: 4)
        @State var selection = PopoverTab.overview

        var body: some View {
            FocusOverview(providers: manager.orderedProviders, selection: $selection)
                .environment(manager)
                .frame(width: PopoverLayout.width)
        }
    }
    return Host()
}
#endif
