import SwiftUI

/// Comparable, pressure-ordered provider overview. Every provider uses the
/// same reading axis: identity, primary constraint, brand rail, reset/context,
/// and (when available) that provider's own cost scope.
struct FocusOverview: View {
    let providers: [any UsageProvider]
    @Binding var selection: PopoverTab

    @Environment(UsageManager.self) private var manager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSummary

            ForEach(orderedProviders, id: \.kind) { provider in
                Button {
                    selection = .provider(provider.kind)
                } label: {
                    providerRow(provider)
                }
                .buttonStyle(OverviewProviderRowStyle())
                .help("Open \(provider.kind.displayName)")
            }
        }
    }

    private var statusSummary: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(attentionCount > 0 ? LimitBar.warnAccent : LimitSafety.Level.healthy.accent)
                .frame(width: 5, height: 5)

            Text(attentionCount == 1 ? "1 needs attention" : "\(attentionCount) need attention")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text("\(onTrackCount) on track")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .overlay(alignment: .bottom) { divider }
    }

    private func providerRow(_ provider: any UsageProvider) -> some View {
        let metric = primaryMetric(for: provider)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ProviderIconTile(kind: provider.kind, size: 25, glyph: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.kind.shortName)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(metric.map(statusLabel) ?? unavailableLabel(provider))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let metric {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(metric.percentUsed.rounded()))%")
                            .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(requiresAttention(metric)
                                ? AnyShapeStyle(LimitBar.warnAccent)
                                : AnyShapeStyle(.primary))
                        Text("used")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let metric {
                ProgressTrack(
                    percent: metric.percentUsed,
                    pacePercent: metric.pacePercent,
                    level: LimitSafety.level(for: metric.percentUsed),
                    height: 4,
                    tint: provider.kind.usageTint(for: colorScheme)
                )
                .padding(.top, 9)

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(resetCaption(metric.resetsAt))
                        .font(.system(size: 9, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    switch metric.paceStatus {
                    case .projectedOvershoot(let projected):
                        Text("\(Int(projected.rounded()))% projected")
                            .font(.system(size: 9, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(LimitBar.warnAccent)
                            .lineLimit(1)
                            .fixedSize()
                    case .aheadOfPace(let multiplier):
                        Text("\(multiplier.formatted(.number.precision(.fractionLength(1))))× pace")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(LimitBar.warnAccent)
                            .lineLimit(1)
                            .fixedSize()
                    case .onTrack:
                        if let secondary = secondaryCaption(provider, excluding: metric) {
                            Text(secondary)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    if let extra = extraSpendCaption(provider) {
                        Text("Extra \(extra)")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }

                    Spacer(minLength: 4)

                    if let spend = spendCaption(provider) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(spend.amount)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(spend.scope)
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                        }
                        .fixedSize()
                    }
                }
                .padding(.top, 7)
            } else {
                Text(provider.error == nil ? "Waiting for usage data" : "Usage unavailable")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            if metric.map(requiresAttention) == true {
                LinearGradient(
                    colors: [provider.kind.usageTint(for: colorScheme).opacity(0.07), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .overlay(alignment: .bottom) { divider }
        .contentShape(Rectangle())
    }

    // MARK: - Ordering and labels

    private var orderedProviders: [any UsageProvider] {
        providers.sorted { pressure(of: $0) > pressure(of: $1) }
    }

    private var attentionCount: Int {
        providers.compactMap(primaryMetric).filter(requiresAttention).count
    }

    private var onTrackCount: Int {
        providers.compactMap(primaryMetric).filter { !requiresAttention($0) }.count
    }

    private func primaryMetric(for provider: any UsageProvider) -> CapacityFocus.Metric? {
        guard let snapshot = provider.snapshot else { return nil }
        return CapacityFocus.metrics(providerKind: provider.kind, snapshot: snapshot)
            .max { lhs, rhs in
                if lhs.riskScore != rhs.riskScore { return lhs.riskScore < rhs.riskScore }
                return lhs.percentUsed < rhs.percentUsed
            }
    }

    private func pressure(of provider: any UsageProvider) -> Double {
        primaryMetric(for: provider)?.riskScore ?? -1
    }

    /// Overview reserves "needs attention" for an imminent or predicted
    /// breach. The 75% warning band remains visible inside provider Detail,
    /// but does not make a long billing cycle look urgent by percentage alone.
    private func requiresAttention(_ metric: CapacityFocus.Metric) -> Bool {
        metric.requiresOverviewAttention
    }

    private func statusLabel(_ metric: CapacityFocus.Metric) -> String {
        switch metric.label {
        case "Weekly": "Weekly limit"
        case "5-hour": "5-hour limit"
        case "Included": "Included usage"
        case "On-demand": "On-demand usage"
        default: "\(metric.label) quota"
        }
    }

    private func unavailableLabel(_ provider: any UsageProvider) -> String {
        provider.snapshot?.planName ?? "Not reported"
    }

    private func resetCaption(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "Reset not reported" }
        return "Resets in \(OverviewSummary.shortCountdown(until: resetsAt))"
    }

    private func secondaryCaption(
        _ provider: any UsageProvider,
        excluding primary: CapacityFocus.Metric
    ) -> String? {
        guard let snapshot = provider.snapshot else { return nil }
        var pieces: [String] = []
        if let secondary = CapacityFocus.metrics(providerKind: provider.kind, snapshot: snapshot)
            .filter({ $0.id != primary.id })
            .max(by: { $0.riskScore < $1.riskScore }) {
            pieces.append("\(secondary.label) \(Int(secondary.percentUsed.rounded()))%")
        }
        if let credits = snapshot.resetCredits?.reportedAvailableCount {
            pieces.append("\(credits) credit\(credits == 1 ? "" : "s")")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    private func extraSpendCaption(_ provider: any UsageProvider) -> String? {
        guard provider.kind == .claude,
              let extra = provider.snapshot?.onDemandSpend
        else { return nil }
        return ProviderCardCostRow.formatCost(extra.amount, estimated: false)
    }

    private struct SpendCaption {
        let amount: String
        let scope: String
    }

    private func spendCaption(_ provider: any UsageProvider) -> SpendCaption? {
        guard manager.showEstimatedCost, let snapshot = provider.snapshot else { return nil }

        switch provider.kind {
        case .claude, .codex:
            let monthKey = LedgerCalendar.monthKey(for: .now)
            let aggregate = manager.ledger.monthlyTotals[monthKey]?[provider.kind] ?? 0
            let displayed = aggregate > 0 ? aggregate : (snapshot.monthlyEstimatedCost ?? 0)
            guard displayed > 0 else { return nil }
            return SpendCaption(
                amount: ProviderCardCostRow.formatCost(displayed),
                scope: "month"
            )
        case .cursor:
            let cycle = (snapshot.spentAmount?.amount ?? 0) + (snapshot.onDemandSpend?.amount ?? 0)
            let displayed = cycle > 0 ? cycle : (snapshot.monthlyEstimatedCost ?? 0)
            guard displayed > 0 else { return nil }
            return SpendCaption(
                amount: ProviderCardCostRow.formatCost(displayed, estimated: false),
                scope: "cycle"
            )
        case .antigravity:
            return nil
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
    }
}

private struct OverviewProviderRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Rectangle()
                    .fill(Color.primary.opacity(
                        configuration.isPressed ? 0.09 : (hovering ? 0.045 : 0)
                    ))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

#if DEBUG
#Preview("Comparable Overview") {
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
