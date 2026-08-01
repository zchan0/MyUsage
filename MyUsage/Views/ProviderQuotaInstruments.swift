import SwiftUI

/// Limit-bar block for providers that do not use rolling instruments in
/// `ProviderDeck`. Cursor expresses included + on-demand budgets, while
/// Antigravity reports per-model quotas.
struct ProviderQuotaInstruments: View {
    let kind: ProviderKind
    let snapshot: UsageSnapshot

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            switch kind {
            case .claude, .codex:
                EmptyView()
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
