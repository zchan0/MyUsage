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
            intro

            if let focusMetric {
                focusInstrument(focusMetric)
                    .padding(.horizontal, 18)
            } else {
                Text("Waiting for usage data")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
            }

            if !watchProviders.isEmpty {
                watchlist
            }

            if manager.showEstimatedCost {
                costDock
            }
        }
    }

    private var intro: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(focusMetric?.needsAttention == true ? "CAPACITY PRESSURE" : "NEXT CONSTRAINT")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(focusMetric?.needsAttention == true ? "Worth attention" : "Capacity looks steady")
                    .font(.system(size: 19, weight: .semibold))
            }

            Spacer(minLength: 8)

            Text(introCaption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.78))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 142, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 15)
    }

    private var introCaption: String {
        guard let metric = focusMetric else { return "No provider has reported a limit yet." }
        if let projected = metric.projectedFinalPercent, projected > 100 {
            return "Current pace projects past this limit."
        }
        if metric.percentUsed >= 75 {
            return "This is the most constrained active window."
        }
        return "The next reset is surfaced before cost and history."
    }

    private func focusInstrument(_ metric: CapacityFocus.Metric) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ProviderIconTile(kind: metric.providerKind, size: 22, glyph: 13)
                Text(metric.providerKind.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(metric.label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(verdict(for: metric))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(metric.needsAttention ? LimitBar.warnAccent : LimitSafety.Level.healthy.accent)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Text("\(Int(metric.percentUsed.rounded()))%")
                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                Text("used")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                Spacer(minLength: 8)
                if let reset = metric.resetsAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("RESETS IN")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(OverviewSummary.shortCountdown(until: reset))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(.top, 13)

            ProgressTrack(
                percent: metric.percentUsed,
                pacePercent: metric.pacePercent,
                level: LimitSafety.level(for: metric.percentUsed),
                height: 7
            )
            .padding(.top, 11)

            HStack(alignment: .firstTextBaseline) {
                if let pace = metric.pacePercent {
                    Text("pace \(Int(pace.rounded()))%")
                } else {
                    Text("pace unavailable")
                }
                Spacer()
                if let projected = metric.projectedFinalPercent {
                    Text("projected \(Int(projected.rounded()))% at reset")
                }
            }
            .font(.system(size: 8.5, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .padding(.top, 8)

            let siblings = allMetrics.filter {
                $0.providerKind == metric.providerKind && $0.id != metric.id
            }
            if !siblings.isEmpty {
                HStack(spacing: 10) {
                    Text("ALSO")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    ForEach(siblings) { sibling in
                        Text("\(sibling.label) \(Int(sibling.percentUsed.rounded()))%")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary.opacity(0.78))
                    }
                }
                .padding(.top, 9)
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
        .padding(.vertical, 16)
        .overlay(alignment: .top) { divider }
        .overlay(alignment: .bottom) { divider }
        .contentShape(Rectangle())
        .onTapGesture { selection = .provider(metric.providerKind) }
        .help("Open \(metric.providerKind.displayName)")
    }

    private var watchlist: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("WATCHLIST")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                Spacer()
                Text("ORDERED BY PRESSURE")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.58))
            }
            .foregroundStyle(.secondary.opacity(0.82))
            .padding(.bottom, 7)

            ForEach(watchProviders, id: \.kind) { provider in
                Button {
                    selection = .provider(provider.kind)
                } label: {
                    watchRow(provider)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
    }

    private func watchRow(_ provider: any UsageProvider) -> some View {
        let metrics = provider.snapshot.map {
            Array(CapacityFocus.metrics(providerKind: provider.kind, snapshot: $0).prefix(2))
        } ?? []

        return HStack(spacing: 12) {
            HStack(spacing: 7) {
                ProviderIconTile(kind: provider.kind, size: 20, glyph: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.kind.shortName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                    Text(watchCaption(provider))
                        .font(.system(size: 8))
                        .foregroundStyle(
                            provider.snapshot?.resetCredits == nil
                                ? AnyShapeStyle(.tertiary)
                                : AnyShapeStyle(Color.accentColor.opacity(0.82))
                        )
                        .lineLimit(1)
                }
            }
            .frame(width: 102, alignment: .leading)

            if metrics.isEmpty {
                Text(provider.error == nil ? "Waiting for data" : "Unavailable")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(metrics) { metric in
                    WatchMetric(metric: metric)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if metrics.count == 1 { Spacer().frame(maxWidth: .infinity) }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 58)
        .overlay(alignment: .top) { divider }
        .contentShape(Rectangle())
    }

    private var costDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("ESTIMATED COST")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.78))
                Spacer()
                if let delta = OverviewSummary.deltaCaption(
                    today: todayCost,
                    average: OverviewSummary.trailingDailyAverage(dailyCosts: manager.ledger.dailyCosts)
                ) {
                    Text(delta)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .bottom, spacing: 15) {
                if let series = OverviewSummary.trailingDailySeries(dailyCosts: manager.ledger.dailyCosts) {
                    CostSparkline(values: series, width: 122, height: 34)
                } else {
                    Rectangle()
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 122, height: 1)
                }
                Spacer(minLength: 0)
                CostDockStat(label: "TODAY", value: ProviderCardCostRow.formatCost(todayCost))
                CostDockStat(label: "THIS MONTH", value: ProviderCardCostRow.formatCost(monthCost))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
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

    private func verdict(for metric: CapacityFocus.Metric) -> String {
        if let projected = metric.projectedFinalPercent, projected > 100 { return "OVER PACE" }
        if metric.percentUsed >= 95 { return "NEAR LIMIT" }
        if metric.percentUsed >= 75 { return "WATCH" }
        if let pace = metric.pacePercent, metric.percentUsed > pace + 10 { return "AHEAD OF PACE" }
        return "ON TRACK"
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
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                Text(metric.label)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            ProgressTrack(
                percent: metric.percentUsed,
                pacePercent: metric.pacePercent,
                level: LimitSafety.level(for: metric.percentUsed),
                height: 4
            )
            if let reset = metric.resetsAt {
                Text("\(OverviewSummary.shortCountdown(until: reset)) to reset")
                    .font(.system(size: 7.5, design: .monospaced))
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
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 83, alignment: .leading)
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
                .frame(width: 400)
        }
    }
    return Host()
}
#endif
