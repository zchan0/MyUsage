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
    /// True on the provider's own tab: prepends the hero stat row (big
    /// 5h / weekly numbers) above the limit bars. Overview cards stay
    /// compact.
    var showsHero: Bool = false

    @Environment(UsageManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHead
            bodySection
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.opacity(0.62))
                // Brand-tinted ambient wash from the head corner — ties
                // the card to its provider without shouting. This is
                // where the popover stops being gray-on-gray.
                .overlay(
                    LinearGradient(
                        colors: [provider.kind.brandTileColor.opacity(0.09), .clear],
                        startPoint: .topLeading,
                        endPoint: UnitPoint(x: 0.65, y: 0.85)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            provider.kind.brandTileColor.opacity(0.28),
                            Color.primary.opacity(0.07),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
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
                heroSection(snapshot)
                ProviderCardLimits(kind: provider.kind, snapshot: snapshot, cached: false)
                ProviderCardCostRow(kind: provider.kind, snapshot: snapshot)
                chartSection
                staleWarningRow(staleMessage)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                heroSection(snapshot)
                ProviderCardLimits(kind: provider.kind, snapshot: snapshot, cached: false)
                ProviderCardCostRow(kind: provider.kind, snapshot: snapshot)
                chartSection
            }
        }
    }

    /// Daily-cost chart, detail tab only. Claude/Codex are the ledger
    /// providers; gated on the same `showEstimatedCost` toggle as the
    /// cost row so "no cost UI" means none anywhere.
    @ViewBuilder
    private var chartSection: some View {
        if showsHero,
           manager.showEstimatedCost,
           let series = manager.ledger.dailyCosts[provider.kind],
           !series.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)
                DailyCostChart(series: series)
            }
        }
    }

    /// Stat-tile row shown only on the provider's own tab (`showsHero`).
    /// Deliberately NOT the window percentages — the limit bars below
    /// already show those. These are the numbers the bars don't carry:
    /// today's spend, the projected end-of-window position (CodexBar's
    /// reserve/deficit), and the credit balance when the account has one.
    @ViewBuilder
    private func heroSection(_ snapshot: UsageSnapshot) -> some View {
        if showsHero, provider.kind == .claude || provider.kind == .codex {
            HStack(spacing: 8) {
                HeroTile(
                    title: "TODAY",
                    value: todayCost.map { ProviderCardCostRow.formatCost($0) } ?? "—",
                    caption: "est. cost"
                )

                if let weekly = snapshot.weeklyUsage {
                    let projected = weekly.projectedFinalPercent()
                    HeroTile(
                        title: "PACE",
                        value: projected.map { "→ \(Int($0.rounded()))%" } ?? "—",
                        caption: paceCaption(projected: projected),
                        accent: projected.map(paceAccent(for:))
                    )
                }

                if let credits = snapshot.credits {
                    HeroTile(
                        title: "CREDITS",
                        value: "$" + String(format: "%.2f", credits.amount),
                        caption: "balance"
                    )
                }
            }
            .padding(.bottom, 1)
        }
    }

    /// Today's ledger cost for this provider, all devices. nil when the
    /// ledger has no row for today yet (fresh day / no usage).
    private var todayCost: Double? {
        let today = LedgerCalendar.dayKey(for: .now)
        return manager.ledger.dailyCosts[provider.kind]?
            .first { $0.day == today }?.totalUSD
    }

    /// "at reset" pace framing: reserve (under 100%) vs deficit (over).
    private func paceCaption(projected: Double?) -> String {
        guard let projected else { return "at reset" }
        if projected > 100 {
            return "deficit +\(Int((projected - 100).rounded()))%"
        }
        return "reserve \(Int((100 - projected).rounded()))%"
    }

    private func paceAccent(for projected: Double) -> Color {
        if projected > 150 { return LimitSafety.Level.crit.accent }
        if projected > 100 { return LimitSafety.Level.warn.accent }
        return LimitSafety.Level.healthy.accent
    }

    // Limit-bar block lives in ProviderCardLimits.swift — accessed via
    // `ProviderCardLimits(kind: provider.kind, snapshot:)`.

    // MARK: - Cost row

    // Cost row lives in ProviderCardCostRow.swift — accessed via
    // `ProviderCardCostRow(kind:, snapshot:)`.

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

}

/// One stat tile in the hero row: tiny tracked-out label, a prominent
/// value (severity-tinted when the metric warrants it), caption below.
struct HeroTile: View {
    let title: String
    let value: String
    let caption: String
    var accent: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary.opacity(0.75))

            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent ?? .primary.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(caption)
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

// Small badge views (StaleDot, PlanPill, LiveBadge) live in
// ProviderCardBadges.swift.
