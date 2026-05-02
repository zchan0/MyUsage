import SwiftUI

/// One provider's card inside the popover. Data wiring is unchanged from
/// the previous implementation — this view only reshapes the visual layer
/// to match `docs/ui-mockups/popover-glassy-v7.html`:
///
///   ┌────────────────────────────────────────┐
///   │ [tile] Claude Code  Max                │  ← head
///   │                                        │
///   │ 5-hour            47%  resets 2h 14m   │  ← LimitBar
///   │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━    │
///   │ Weekly            62%  resets Sun      │
///   │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━    │
///   │ ─────────────────────────────────────  │  ← hairline
///   │ This month     $112.40   ⊕ 2 devices   │  ← cost row
///   └────────────────────────────────────────┘
struct ProviderCard: View {
    let provider: any UsageProvider
    @Environment(UsageManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHead
            bodySection
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.background.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 1.5, x: 0, y: 1)
        .opacity(isDimmed ? 0.7 : 1.0)
    }

    // MARK: - Head

    private var cardHead: some View {
        HStack(spacing: 9) {
            ProviderIconTile(kind: provider.kind)
                .saturation(isDimmed ? 0.55 : 1.0)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(provider.kind.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)

                if let plan = planLabel {
                    PlanPill(text: plan)
                }

                if isStale {
                    StaleDot()
                }
            }

            Spacer(minLength: 6)

            if provider.kind == .antigravity, isAntigravityLive {
                LiveBadge()
            }

            if provider.kind == .antigravity, !isAntigravityLive {
                Button { Task { await provider.refresh() } } label: {
                    Text("Open")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    }

    // MARK: - Body — limits / state / loading / error

    @ViewBuilder
    private var bodySection: some View {
        if provider.isLoading && provider.snapshot == nil {
            loadingView
        } else if let error = provider.error, provider.snapshot == nil {
            errorView(error)
        } else if let snapshot = provider.snapshot {
            snapshotBody(snapshot)
        } else {
            notConfiguredView
        }
    }

    @ViewBuilder
    private func snapshotBody(_ snapshot: UsageSnapshot) -> some View {
        // Antigravity off: head already carries the "IDE off" plan label
        // and the Open button. Don't render a state row beneath — the
        // head says everything we need (no historical timestamp).
        if provider.kind == .antigravity, !isAntigravityLive {
            EmptyView()
        } else if let staleMessage = provider.error {
            VStack(alignment: .leading, spacing: 9) {
                limits(snapshot)
                costRowIfAny(snapshot)
                staleWarningRow(staleMessage)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                limits(snapshot)
                costRowIfAny(snapshot)
            }
        }
    }

    @ViewBuilder
    private func limits(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            switch provider.kind {
            case .claude, .codex:
                if let session = snapshot.sessionUsage {
                    LimitBar(
                        name: "5-hour",
                        percent: session.percentUsed,
                        reset: session.resetCountdown.map { "resets \($0)" },
                        projectedPercent: session.projectedFinalPercent()
                    )
                }
                if let weekly = snapshot.weeklyUsage {
                    LimitBar(
                        name: "Weekly",
                        percent: weekly.percentUsed,
                        reset: weekly.resetCountdown.map { "resets \($0)" },
                        projectedPercent: weekly.projectedFinalPercent()
                    )
                    weeklyByModelRows(snapshot.weeklyByModel)
                }
            case .cursor:
                cursorLimits(snapshot)
            case .antigravity:
                ForEach(snapshot.modelQuotas) { quota in
                    LimitBar(
                        name: quota.label,
                        percent: quota.percentUsed,
                        monoName: true
                    )
                }
            }
        }
    }

    /// Per-model breakdown rows shown directly under Claude's weekly bar.
    /// Indented mono name + right-aligned mono percent, column-aligned
    /// with the parent LimitBar's name + percent slots so the eye reads
    /// straight down. No bar — the weekly bar above already shows the
    /// total; here we only need the per-model contribution numbers.
    @ViewBuilder
    private func weeklyByModelRows(_ rows: [WeeklyModelUsage]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label)
                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.75))
                        Spacer(minLength: 8)
                        Text("\(Int(row.percent.rounded()))%")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary.opacity(0.85))
                    }
                }
            }
            .padding(.leading, 12)   // indent so child relationship reads
            .padding(.top, 2)
        }
    }

    /// Cursor splits into Included (capped quota, healthy bar) and
    /// On-demand (capped budget, "+$X of $Y" overflow). Both use the
    /// `LimitBar` shape — they ARE both bounded limits, just billed
    /// differently.
    @ViewBuilder
    private func cursorLimits(_ snapshot: UsageSnapshot) -> some View {
        if let spent = snapshot.spentAmount {
            LimitBar(
                name: "Included",
                percent: snapshot.totalUsagePercent ?? 0,
                reset: spent.formatted
            )
        }
        if let onDemand = snapshot.onDemandSpend {
            if let limit = onDemand.limit, limit > 0 {
                let pct = onDemand.amount / limit * 100
                LimitBar(
                    name: "On-demand",
                    percent: pct,
                    reset: "+\(onDemand.formatted)"
                )
            } else {
                // No on-demand cap reported — show the spend as a single
                // metered row with no bar. Reuses the LimitBar header
                // shape so it visually rhymes with capped rows.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("On-demand")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.95))
                    Spacer(minLength: 8)
                    Text("+" + onDemand.formatted)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.92))
                }
            }
        }
    }

    // MARK: - Cost row

    /// Hairline divider + cost row at the bottom of each card. Mirrors v7:
    /// claude/codex use the aggregate (multi-device) row with the ⊕ devices
    /// pill; cursor uses a local cycle-spend row; antigravity has no cost.
    @ViewBuilder
    private func costRowIfAny(_ snapshot: UsageSnapshot) -> some View {
        if shouldShowCost(snapshot) {
            VStack(alignment: .leading, spacing: 9) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)

                costRow(snapshot)
            }
        }
    }

    private func shouldShowCost(_ snapshot: UsageSnapshot) -> Bool {
        guard manager.showEstimatedCost else { return false }
        switch provider.kind {
        case .claude, .codex:
            return true // aggregate row decides whether to render
        case .cursor:
            return snapshot.monthlyEstimatedCost != nil || snapshot.spentAmount != nil
        case .antigravity:
            return false
        }
    }

    @ViewBuilder
    private func costRow(_ snapshot: UsageSnapshot) -> some View {
        switch provider.kind {
        case .claude, .codex:
            aggregateMonthlyCostRow(fallbackLocal: snapshot.monthlyEstimatedCost)
        case .cursor:
            cursorCycleRow(snapshot)
        case .antigravity:
            EmptyView()
        }
    }

    @ViewBuilder
    private func aggregateMonthlyCostRow(fallbackLocal: Double?) -> some View {
        let monthKey = LedgerCalendar.monthKey(for: .now)
        let contributions = manager.ledger.contributions(
            provider: provider.kind,
            monthKey: monthKey
        )
        let aggregate = manager.ledger.monthlyTotals[monthKey]?[provider.kind] ?? 0
        let hasPeers = contributions.contains { !$0.isSelf }
        let displayed: Double = aggregate > 0 ? aggregate : (fallbackLocal ?? 0)

        if displayed == 0 && !hasPeers {
            EmptyView()
        } else {
            AggregateMonthlyCostRow(
                providerKind: provider.kind,
                displayed: displayed,
                peerCount: max(0, contributions.count - 1),
                contributions: contributions
            )
        }
    }

    private func cursorCycleRow(_ snapshot: UsageSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("This cycle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            Text(cursorCycleAmount(snapshot))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.95))

            if let cycleEnd = snapshot.billingCycleEnd {
                let days = max(0, Calendar.current.dateComponents([.day], from: .now, to: cycleEnd).day ?? 0)
                Text("· \(days)d left")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
    }

    private func cursorCycleAmount(_ snapshot: UsageSnapshot) -> String {
        let total = (snapshot.spentAmount?.amount ?? 0) + (snapshot.onDemandSpend?.amount ?? 0)
        return Self.formatCost(total, estimated: false)
    }

    // MARK: - Stale warning

    /// Shown beneath limits when the last refresh failed but cached data is
    /// still being displayed. Single line, amber, with no destructive
    /// styling — the data above is still useful.
    private func staleWarningRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9.5))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button { Task { await provider.refresh() } } label: {
                Text("Retry")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    // MARK: - Empty / loading / error states

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text("Loading…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button { Task { await provider.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var notConfiguredView: some View {
        Text("Not configured")
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
    }

    // MARK: - State helpers

    /// Plan label rendered to the right of the provider name. For
    /// Antigravity the label communicates IDE state ("IDE off" /
    /// "IDE running") instead of a paid-plan tier — Antigravity has none.
    private var planLabel: String? {
        if provider.kind == .antigravity {
            return isAntigravityLive ? nil : "IDE off"
        }
        return provider.snapshot?.planName
    }

    private var isStale: Bool {
        provider.snapshot != nil && provider.error != nil
    }

    private var isAntigravityLive: Bool {
        guard provider.kind == .antigravity else { return false }
        return provider.snapshot != nil && provider.error == nil
    }

    private var isDimmed: Bool {
        // Antigravity-off: head + Open button only, no body — dim the
        // whole card so the eye skips it on glance.
        if provider.kind == .antigravity, !isAntigravityLive { return true }
        return false
    }

    static func formatCost(_ amount: Double, estimated: Bool = true) -> String {
        let prefix = estimated ? "~$" : "$"
        return prefix + String(format: "%.2f", amount)
    }

    static let aggregateTooltip = """
    Sum of estimated costs across all Macs sharing the same Sync folder.
    Click the ⊕ badge to see the per-device breakdown.
    """
}

// MARK: - Small badges

/// Amber dot beside a provider name when the snapshot is stale.
struct StaleDot: View {
    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .overlay(
                Circle().stroke(Color.orange.opacity(0.18), lineWidth: 2)
            )
            .help("Last refresh failed — showing cached data")
    }
}

/// Small monospaced pill for the plan label ("Pro" / "Max" / "Plus" / "IDE off").
/// Same shape as the ⊕ devices pill so the card head stays visually rhyming.
struct PlanPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary.opacity(0.78))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Color.primary.opacity(0.06),
                in: Capsule()
            )
    }
}

/// Periwinkle "LIVE" badge for Antigravity when the IDE is running.
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ProviderKind.antigravity.brandTileColor)
                .frame(width: 5, height: 5)
            Text("LIVE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.4)
        }
        .foregroundStyle(ProviderKind.antigravity.brandTileColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            ProviderKind.antigravity.brandTileColor.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
    }
}
