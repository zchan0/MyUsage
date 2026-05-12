import SwiftUI

/// Bottom-of-card cost row + the hairline above it. Encapsulates three
/// distinct strategies:
///
/// - Claude / Codex: aggregate (multi-device, current month) sum, with
///   the ⊕ devices pill and per-account scoping when bound to an
///   account.
/// - Cursor: this billing cycle's spend (Included + On-demand) plus the
///   "N days left" countdown.
/// - Antigravity: nothing — there's no per-account billing.
///
/// Reads the manager from the environment to pick up the user's
/// `showEstimatedCost` toggle and to query the ledger.
struct ProviderCardCostRow: View {
    let kind: ProviderKind
    let snapshot: UsageSnapshot
    /// Non-nil when the parent card is bound to a specific account; the
    /// aggregate row will be scoped to that account's cross-device sum.
    let account: AccountStore.AccountRecord?

    @Environment(UsageManager.self) private var manager

    var body: some View {
        if shouldShow {
            VStack(alignment: .leading, spacing: 9) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)

                bodyRow
            }
        }
    }

    private var shouldShow: Bool {
        guard manager.showEstimatedCost else { return false }
        switch kind {
        case .claude, .codex:
            return true // aggregate row decides whether to render
        case .cursor:
            return snapshot.monthlyEstimatedCost != nil || snapshot.spentAmount != nil
        case .antigravity:
            return false
        }
    }

    @ViewBuilder
    private var bodyRow: some View {
        switch kind {
        case .claude, .codex:
            aggregateRow
        case .cursor:
            cursorCycleRow
        case .antigravity:
            EmptyView()
        }
    }

    @ViewBuilder
    private var aggregateRow: some View {
        let monthKey = LedgerCalendar.monthKey(for: .now)
        let contributions = manager.ledger.contributions(provider: kind, monthKey: monthKey)
        let aggregate = scopedMonthlyAggregate(monthKey: monthKey)
        let hasPeers = contributions.contains { !$0.isSelf }
        let displayed: Double = aggregate > 0 ? aggregate : (snapshot.monthlyEstimatedCost ?? 0)

        if displayed == 0 && !hasPeers {
            EmptyView()
        } else {
            AggregateMonthlyCostRow(
                providerKind: kind,
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
                provider: kind,
                monthKey: monthKey,
                accountID: account.accountID
            )
        }
        return manager.ledger.monthlyTotals[monthKey]?[kind] ?? 0
    }

    private var cursorCycleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("This cycle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            Text(cursorCycleAmount)
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

    private var cursorCycleAmount: String {
        let total = (snapshot.spentAmount?.amount ?? 0) + (snapshot.onDemandSpend?.amount ?? 0)
        return ProviderCardCostRow.formatCost(total, estimated: false)
    }

    /// Shared by every cost-row caller: `~$543.57` for ledger-derived
    /// estimates, `$543.57` for billed-dollar amounts (Cursor cycle).
    static func formatCost(_ amount: Double, estimated: Bool = true) -> String {
        let prefix = estimated ? "~$" : "$"
        return prefix + String(format: "%.2f", amount)
    }

    static let aggregateTooltip = """
    Sum of estimated costs across all Macs sharing the same Sync folder.
    Click the ⊕ badge to see the per-device breakdown.
    """
}
