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
    /// When non-nil, render the email pill in the card head + (if !isActive)
    /// surface the cached snapshot under a stale banner. nil = today's UX,
    /// no account chrome — used for the single-account case.
    var account: AccountStore.AccountRecord? = nil
    /// Whether `account` is the one the credentials file currently points
    /// at. `true` shows live data + filled sage dot; `false` shows the
    /// cached snapshot + hollow ring + saturate(0.65) wash.
    var isActive: Bool = true

    @Environment(UsageManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHead
            if showStaleBanner, let captured = account?.snapshot?.capturedAt {
                StaleSnapshotBanner(capturedAt: captured)
            }
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
        .saturation(showStaleBanner ? 0.65 : 1.0)
    }

    /// Snapshot driving every renderable bar / number in this card. For
    /// the active account (or single-account default) this is the live
    /// `provider.snapshot`; for an inactive account it's the cached
    /// `AccountSnapshot` reconstituted as a `UsageSnapshot`.
    private var effectiveSnapshot: UsageSnapshot? {
        if !isActive, let cached = account?.snapshot {
            return cached.asUsageSnapshot
        }
        return provider.snapshot
    }

    private var showStaleBanner: Bool {
        !isActive && account?.snapshot != nil
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

                if let account {
                    AccountEmailPill(
                        displayName: account.displayName,
                        isActive: isActive,
                        isOpaque: account.isOpaque
                    )
                    .layoutPriority(-1)
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
        if provider.isLoading && effectiveSnapshot == nil {
            loadingView
        } else if let error = provider.error, effectiveSnapshot == nil, isActive {
            errorView(error)
        } else if let snapshot = effectiveSnapshot {
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
        } else if isActive, let staleMessage = provider.error {
            // Live error rows belong to the active account only — the
            // cached snapshot view already explains its own staleness via
            // the StaleSnapshotBanner above.
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
    ///
    /// When neither bar has data (Free plans return no included budget
    /// and no on-demand spend), the card body would otherwise be visually
    /// empty — the head shows "Free" and then nothing. Surface a small
    /// dim caption so the absence is intentional, not a render bug.
    @ViewBuilder
    private func cursorLimits(_ snapshot: UsageSnapshot) -> some View {
        let hasIncluded = snapshot.spentAmount != nil
        let hasOnDemand = snapshot.onDemandSpend != nil

        if hasIncluded || hasOnDemand {
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
        } else {
            // Free / no-quota plan: explicit empty state so the card
            // doesn't look broken.
            Text("No usage limits on this plan")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary.opacity(0.7))
                .italic()
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
        let aggregate = scopedMonthlyAggregate(monthKey: monthKey)
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

    /// When this card is bound to a specific account, scope the displayed
    /// total to that account's cross-device sum so the cost row reflects
    /// what *this* account spent — not the provider's grand total across
    /// all accounts.
    private func scopedMonthlyAggregate(monthKey: String) -> Double {
        if let account {
            return manager.ledger.monthlyTotal(
                provider: provider.kind,
                monthKey: monthKey,
                accountID: account.accountID
            )
        }
        return manager.ledger.monthlyTotals[monthKey]?[provider.kind] ?? 0
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
        return effectiveSnapshot?.planName
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
