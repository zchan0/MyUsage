import SwiftUI

/// Limit-bar block in a ProviderCard. Encapsulates the per-kind switch
/// over how a provider expresses limits (rolling windows for Claude /
/// Codex, included + on-demand budgets for Cursor, per-model quotas for
/// Antigravity) so the parent card stays an orchestrator instead of
/// branching on every detail.
struct ProviderCardLimits: View {
    let kind: ProviderKind
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch kind {
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
                    WeeklyByModelRows(rows: snapshot.weeklyByModel)
                }
            case .cursor:
                CursorLimits(snapshot: snapshot)
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
}

/// Per-model breakdown rows shown directly under Claude's weekly bar.
/// Indented mono name + right-aligned mono percent, column-aligned with
/// the parent LimitBar's name + percent slots so the eye reads straight
/// down. No bar — the weekly bar above already shows the total.
struct WeeklyByModelRows: View {
    let rows: [WeeklyModelUsage]

    var body: some View {
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
            .padding(.leading, 12) // indent so child relationship reads
            .padding(.top, 2)
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

    var body: some View {
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
