import SwiftUI

/// Limit-bar block in a ProviderCard. Encapsulates the per-kind switch
/// over how a provider expresses limits (rolling windows for Claude /
/// Codex, included + on-demand budgets for Cursor, per-model quotas for
/// Antigravity) so the parent card stays an orchestrator instead of
/// branching on every detail.
struct ProviderCardLimits: View {
    let kind: ProviderKind
    let snapshot: UsageSnapshot
    /// True when `snapshot` is an inactive account's cached snapshot
    /// (not live data). Drives the "window reset since snapshot" handling:
    /// a cached window whose `resetsAt` is in the past no longer reflects
    /// reality, and we can't fetch the live value (no token for a non-
    /// active account), so we render an empty muted rail + a refresh hint
    /// instead of a stale percentage.
    var cached: Bool = false

    @Environment(UsageManager.self) private var manager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            switch kind {
            case .claude, .codex:
                if let session = snapshot.sessionUsage {
                    LimitBar(
                        name: "5-hour",
                        percent: session.percentUsed,
                        reset: cached ? nil : session.resetCountdown.map { "resets \($0)" },
                        projectedPercent: session.projectedFinalPercent(),
                        pacePercent: cached ? nil : session.onPacePercent(),
                        expired: isExpired(session),
                        tint: kind.usageTint(for: colorScheme)
                    )
                }
                if let weekly = snapshot.weeklyUsage {
                    LimitBar(
                        name: "Weekly",
                        percent: weekly.percentUsed,
                        reset: cached ? nil : weekly.resetCountdown.map { "resets \($0)" },
                        projectedPercent: weekly.projectedFinalPercent(),
                        pacePercent: cached ? nil : weekly.onPacePercent(),
                        expired: isExpired(weekly),
                        tint: kind.usageTint(for: colorScheme)
                    )
                    // Per-bucket caps render as peers of the Weekly bar,
                    // not as sub-rows under it. Each row is one model's
                    // separate weekly cap — Anthropic tracks them
                    // independently, so the visual treatment matches 5h /
                    // Weekly exactly. Hidden when the weekly window has
                    // reset on a cached card — the breakdown is just as
                    // stale as the parent.
                    if manager.showPerModelBars, !isExpired(weekly) {
                        ForEach(snapshot.weeklyByModel) { row in
                            LimitBar(
                                name: row.label,
                                percent: row.percent,
                                tint: kind.usageTint(for: colorScheme)
                            )
                        }
                    }
                }
                if kind == .claude, let extra = snapshot.onDemandSpend {
                    ExtraUsageInstrument(
                        spend: extra,
                        tint: kind.usageTint(for: colorScheme)
                    )
                }
                if anyWindowExpired {
                    refreshHint
                }
            case .cursor:
                CursorLimits(snapshot: snapshot)
            case .antigravity:
                ForEach(snapshot.modelQuotas) { quota in
                    LimitBar(
                        name: quota.label,
                        percent: quota.percentUsed,
                        monoName: true,
                        tint: kind.usageTint(for: colorScheme)
                    )
                }
            }
        }
    }

    /// A cached window is "expired" when its reset time has already
    /// passed — the window rolled over since we captured the snapshot,
    /// so the cached percentage is meaningless. Live (non-cached) cards
    /// never treat a window as expired; their data is current and a
    /// past reset just means a refresh is imminent.
    private func isExpired(_ window: UsageWindow) -> Bool {
        guard cached, let resetsAt = window.resetsAt else { return false }
        return resetsAt < .now
    }

    private var anyWindowExpired: Bool {
        guard cached else { return false }
        if let s = snapshot.sessionUsage, isExpired(s) { return true }
        if let w = snapshot.weeklyUsage, isExpired(w) { return true }
        return false
    }

    private var refreshHint: some View {
        Text("Sign in to this account to refresh")
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundStyle(.secondary.opacity(0.7))
    }
}

/// Cursor splits into Included (capped quota, healthy bar) and On-demand
/// (capped budget, "+$X of $Y" overflow). Both use the `LimitBar` shape —
/// they ARE both bounded limits, just billed differently.
///
/// When neither bar has data (Free plans return no included budget and
/// no on-demand spend), the card body would otherwise be visually empty —
/// the head shows "Free" and then nothing. Surface a small dim caption
/// so the absence is intentional, not a render bug.
struct CursorLimits: View {
    let snapshot: UsageSnapshot

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let hasIncluded = snapshot.spentAmount != nil
        let hasOnDemand = snapshot.onDemandSpend != nil

        if hasIncluded || hasOnDemand {
            if let spent = snapshot.spentAmount {
                LimitBar(
                    name: "Included",
                    percent: snapshot.totalUsagePercent ?? 0,
                    reset: spent.formatted,
                    tint: ProviderKind.cursor.usageTint(for: colorScheme)
                )
            }
            if let onDemand = snapshot.onDemandSpend {
                if let limit = onDemand.limit, limit > 0 {
                    let pct = onDemand.amount / limit * 100
                    LimitBar(
                        name: "On-demand",
                        percent: pct,
                        reset: "+\(onDemand.formatted)",
                        tint: ProviderKind.cursor.usageTint(for: colorScheme)
                    )
                } else {
                    // No on-demand cap reported — show the spend as a
                    // single metered row with no bar. Reuses the LimitBar
                    // header shape so it visually rhymes with capped rows.
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
}

/// Claude's API reports Extra usage separately from estimated token cost.
/// A configured monthly limit behaves like a normal bounded instrument;
/// accounts without a reported cap still get an explicit metered amount.
struct ExtraUsageInstrument: View {
    let spend: CreditInfo
    let tint: Color

    @ViewBuilder
    var body: some View {
        if let limit = spend.limit, limit > 0 {
            LimitBar(
                name: "Extra usage",
                percent: spend.amount / limit * 100,
                reset: spend.formatted,
                tint: tint
            )
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Extra usage")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.95))
                Spacer(minLength: 8)
                Text(ProviderCardCostRow.formatCost(spend.amount, estimated: false))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.92))
            }
        }
    }
}
