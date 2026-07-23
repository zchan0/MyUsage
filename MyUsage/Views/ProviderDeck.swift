import SwiftUI

/// Provider detail follows one stable axis: account identity, provider limits,
/// provider-specific inventory, then cost/model history and token totals.
struct ProviderDeck: View {
    let provider: any UsageProvider

    @Environment(UsageManager.self) private var manager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if provider.isLoading && provider.snapshot == nil {
            stateRow(icon: nil, text: "Loading…", loading: true)
        } else if let error = provider.error, provider.snapshot == nil {
            stateRow(icon: "exclamationmark.triangle", text: error)
        } else if let snapshot = provider.snapshot {
            snapshotContent(snapshot)
        } else {
            stateRow(icon: "questionmark.circle", text: "Not configured")
        }
    }

    private func snapshotContent(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            accountHeader(snapshot)

            if provider.kind == .claude || provider.kind == .codex {
                rollingInstruments(snapshot)
            } else {
                ProviderQuotaInstruments(kind: provider.kind, snapshot: snapshot)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .overlay(alignment: .bottom) { sectionDivider }
            }

            if provider.kind == .claude, let extra = snapshot.onDemandSpend {
                ExtraUsageInstrument(
                    spend: extra,
                    tint: provider.kind.usageTint(for: colorScheme)
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 17)
                .overlay(alignment: .bottom) { sectionDivider }
            }

            if provider.kind == .codex {
                resetCredits(snapshot)
            }

            history(snapshot)

            if let error = provider.error {
                errorRow(error)
            }
        }
    }

    // MARK: - Account identity

    private func accountHeader(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 9) {
            AccountAvatar(kind: provider.kind, email: snapshot.email)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.email ?? provider.kind.shortName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(accountCaption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if let plan = snapshot.planName {
                PlanPill(text: plan)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .overlay(alignment: .bottom) { sectionDivider }
    }

    private var accountCaption: String {
        switch provider.kind {
        case .claude, .codex: "\(provider.kind.shortName) · OAuth account"
        case .cursor: "Cursor account · billing cycle"
        case .antigravity: "Antigravity · Google account"
        }
    }

    // MARK: - Limits

    @ViewBuilder
    private func rollingInstruments(_ snapshot: UsageSnapshot) -> some View {
        let metrics = CapacityFocus.metrics(providerKind: provider.kind, snapshot: snapshot)
            .sorted { $0.riskScore > $1.riskScore }
        if metrics.isEmpty {
            Text("No rolling limits reported")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { sectionDivider }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(metrics) { metric in
                    DeckLimitInstrument(metric: metric)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 17)
                        .overlay(alignment: .bottom) { sectionDivider }
                }
            }
        }
    }

    private func resetCredits(_ snapshot: UsageSnapshot) -> some View {
        Group {
            if let inventory = snapshot.resetCredits {
                ResetCreditsSection(inventory: inventory)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Reset credits")
                        .font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    Text("Unavailable")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .help("Codex did not return reset-credit inventory. No count is assumed.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) { sectionDivider }
    }

    // MARK: - Cost and tokens

    @ViewBuilder
    private func history(_ snapshot: UsageSnapshot) -> some View {
        let series = manager.ledger.dailyCosts[provider.kind] ?? []
        let tokens = manager.ledger.tokenUsage30Days[provider.kind]
        let showCost = manager.showEstimatedCost && hasCost(snapshot, series: series)

        if showCost || tokens != nil {
            VStack(alignment: .leading, spacing: 0) {
                if showCost {
                    ProviderCardCostRow(
                        kind: provider.kind,
                        snapshot: snapshot,
                        showsDivider: false
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if !series.isEmpty {
                        sectionDivider
                        DailyCostChart(kind: provider.kind, series: series)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                }

                if let tokens {
                    sectionDivider
                    TokenUsageSummary(usage: tokens)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                }
            }
            .overlay(alignment: .bottom) { sectionDivider }
        }
    }

    private func hasCost(_ snapshot: UsageSnapshot, series: [LedgerStore.DailyCost]) -> Bool {
        if !series.isEmpty { return true }
        switch provider.kind {
        case .claude, .codex:
            let monthKey = LedgerCalendar.monthKey(for: .now)
            return (manager.ledger.monthlyTotals[monthKey]?[provider.kind] ?? 0) > 0
                || snapshot.monthlyEstimatedCost != nil
        case .cursor:
            return snapshot.monthlyEstimatedCost != nil || snapshot.spentAmount != nil
        case .antigravity:
            return false
        }
    }

    // MARK: - States

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(error)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Retry") {
                Task { await provider.refresh(trigger: .manual) }
            }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { sectionDivider }
    }

    private func stateRow(icon: String?, text: String, loading: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if loading {
                ProgressView().scaleEffect(0.7)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !loading {
                Button {
                    Task { await provider.refresh(trigger: .manual) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var sectionDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
    }
}

private struct AccountAvatar: View {
    let kind: ProviderKind
    let email: String?

    var body: some View {
        if initials.isEmpty {
            ProviderIconTile(kind: kind, size: 27, glyph: 15)
        } else {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.secondary.opacity(0.82), Color.secondary.opacity(0.58)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Text(initials)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 27, height: 27)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
        }
    }

    private var initials: String {
        guard let local = email?.split(separator: "@").first else { return "" }
        return String(local.prefix(2)).uppercased()
    }
}

private struct DeckLimitInstrument: View {
    let metric: CapacityFocus.Metric

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metric.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(Int(metric.percentUsed.rounded()))%")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(metric.needsAttention
                        ? AnyShapeStyle(LimitBar.warnAccent)
                        : AnyShapeStyle(.primary))
                Text("used")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            ProgressTrack(
                percent: metric.percentUsed,
                pacePercent: metric.pacePercent,
                level: LimitSafety.level(for: metric.percentUsed),
                height: 6,
                tint: metric.providerKind.usageTint(for: colorScheme)
            )
            .padding(.top, 10)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(resetCaption)
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if let summary = CapacityPaceText.detailSummary(for: metric) {
                    Text(summary)
                        .font(.system(
                            size: 9.5,
                            weight: metric.hasCapacityRisk ? .medium : .regular,
                            design: .monospaced
                        ))
                        .monospacedDigit()
                        .foregroundStyle(metric.hasCapacityRisk
                            ? AnyShapeStyle(LimitBar.warnAccent)
                            : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
            .padding(.top, 8)
        }
    }

    private var resetCaption: String {
        guard let resetsAt = metric.resetsAt else { return "Reset not reported" }
        return "Resets in \(OverviewSummary.shortCountdown(until: resetsAt))"
    }
}

struct TokenUsageSummary: View {
    let usage: TokenUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Token usage")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("30 days · all accounts")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 0) {
                tokenStat("Total", usage.total)
                tokenStat("Input", usage.input)
                tokenStat("Output", usage.output)
                tokenStat("Cache", usage.cache)
            }
        }
    }

    private func tokenStat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TokenCountFormatter.string(value))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, label == "Total" ? 0 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if label != "Total" {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
            }
        }
    }
}

enum TokenCountFormatter {
    static func string(_ value: Int) -> String {
        let count = Double(max(0, value))
        switch count {
        case 1_000_000_000...: return compact(count / 1_000_000_000, suffix: "B")
        case 1_000_000...: return compact(count / 1_000_000, suffix: "M")
        case 1_000...: return compact(count / 1_000, suffix: "K")
        default: return String(Int(count))
        }
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let digits = value >= 100 ? 0 : 1
        return String(format: "%.*f%@", digits, value, suffix)
    }
}

#if DEBUG
#Preview("Claude Detail") {
    let manager = PreviewFixtures.manager(providerCount: 4)
    ProviderDeck(provider: manager.orderedProviders.first { $0.kind == .claude }!)
        .environment(manager)
        .frame(width: PopoverLayout.width)
}

#Preview("Codex Detail") {
    let manager = PreviewFixtures.manager(providerCount: 4)
    ProviderDeck(provider: manager.orderedProviders.first { $0.kind == .codex }!)
        .environment(manager)
        .frame(width: PopoverLayout.width)
}
#endif
