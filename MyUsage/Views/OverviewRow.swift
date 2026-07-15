import SwiftUI

/// Compact one-line summary of a provider on the Overview page. Tapping
/// the row pushes the provider's detail page (the full `ProviderCard`).
///
///   ┌──────────────────────────────────────────────┐
///   │ [tile] Claude Code  Max ·   5h 42% · wk 61% ›│
///   └──────────────────────────────────────────────┘
///
/// The right-hand metric summary is intentionally terse — percentages and
/// cost only. Anything richer (reset countdowns, per-model bars, device
/// breakdowns) lives on the detail page.
struct OverviewRow: View {
    let provider: any UsageProvider
    let onTap: () -> Void

    @Environment(UsageManager.self) private var manager

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                ProviderIconTile(kind: provider.kind, size: 20, glyph: 12)
                    .saturation(isDimmed ? 0.55 : 1.0)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(provider.kind.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    if let plan = planLabel {
                        PlanPill(text: plan)
                    }

                    if isStale {
                        StaleDot()
                    }
                }

                Spacer(minLength: 8)

                summary

                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.background.opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isDimmed ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Metric summary

    @ViewBuilder
    private var summary: some View {
        if provider.isLoading && provider.snapshot == nil {
            ProgressView().scaleEffect(0.5)
        } else if provider.error != nil, provider.snapshot == nil {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else if let snapshot = provider.snapshot {
            Text(summaryText(snapshot))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("Not configured")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func summaryText(_ snapshot: UsageSnapshot) -> String {
        var parts: [String] = []
        switch provider.kind {
        case .claude, .codex:
            if let session = snapshot.sessionUsage {
                parts.append("5h \(Int(session.percentUsed))%")
            }
            if let weekly = snapshot.weeklyUsage {
                parts.append("wk \(Int(weekly.percentUsed))%")
            }
            if let cost = monthlyCost, cost > 0 {
                parts.append(ProviderCardCostRow.formatCost(cost))
            }
        case .cursor:
            if let pct = snapshot.totalUsagePercent {
                parts.append("inc \(Int(pct))%")
            }
            if let onDemand = snapshot.onDemandSpend {
                parts.append("+" + onDemand.formatted)
            }
        case .antigravity:
            if isAntigravityLive, let peak = snapshot.modelQuotas.map(\.percentUsed).max() {
                parts.append("peak \(Int(peak))%")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Same source as the detail page's cost row: ledger aggregate when
    /// present, single-device snapshot estimate otherwise. Respects the
    /// user's `showEstimatedCost` toggle.
    private var monthlyCost: Double? {
        guard manager.showEstimatedCost else { return nil }
        let monthKey = LedgerCalendar.monthKey(for: .now)
        let aggregate = manager.ledger.monthlyTotals[monthKey]?[provider.kind] ?? 0
        if aggregate > 0 { return aggregate }
        return provider.snapshot?.monthlyEstimatedCost
    }

    // MARK: - State helpers (mirrors ProviderCard)

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
        if provider.kind == .antigravity, !isAntigravityLive { return true }
        return false
    }
}

#Preview {
    let manager = UsageManager()
    return VStack(spacing: 6) {
        ForEach(manager.orderedProviders, id: \.kind) { provider in
            OverviewRow(provider: provider) {}
        }
    }
    .padding(12)
    .frame(width: 340)
    .environment(manager)
}
