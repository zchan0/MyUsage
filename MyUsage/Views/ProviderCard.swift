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
    /// False on the provider's own tab, where the panel header already
    /// names the provider — repeating it inside the card wastes a row.
    var showsHead: Bool = true

    @Environment(UsageManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHead { cardHead }
            bodySection
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        // Premium = restraint: a neutral surface with a crisp hairline.
        // Brand colour lives only in the icon tile; data colour lives
        // only in the bars/severity accents. (The earlier brand-tinted
        // gradient wash read as muddy gray-on-gray.)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

            // Severity verdict, non-Antigravity cards with data. Antigravity
            // keeps its LIVE badge — "IDE running" is that card's state
            // story, and two chips on one head row would fight.
            if provider.kind != .antigravity, let snapshot = provider.snapshot {
                StatusChip(level: LimitSafety.level(for: snapshot.worstUsagePercent))
            }

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
            VStack(alignment: .leading, spacing: 11) {
                heroSection(snapshot)
                ProviderCardLimits(kind: provider.kind, snapshot: snapshot, cached: false)
                ProviderCardCostRow(kind: provider.kind, snapshot: snapshot)
                chartSection
                accountRow(snapshot)
                staleWarningRow(staleMessage)
            }
        } else {
            VStack(alignment: .leading, spacing: 11) {
                heroSection(snapshot)
                ProviderCardLimits(kind: provider.kind, snapshot: snapshot, cached: false)
                ProviderCardCostRow(kind: provider.kind, snapshot: snapshot)
                chartSection
                accountRow(snapshot)
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
                DailyCostChart(kind: provider.kind, series: series)
            }
        }
    }

    /// Stat-tile grid shown only on the provider's own tab (`showsHero`).
    /// Deliberately NOT the window percentages — the limit bars below
    /// already show those. These are the numbers the bars don't carry:
    /// today's spend (with the vs-7-day-average delta), the projected
    /// end-of-window position (CodexBar's reserve/deficit), the credit
    /// balance, and the multi-device split. 2-column grid: tiles are
    /// text-dense enough that three abreast squeezed every caption.
    @ViewBuilder
    private func heroSection(_ snapshot: UsageSnapshot) -> some View {
        if showsHero, provider.kind == .claude || provider.kind == .codex {
            let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                // No ledger row for today means exactly $0 so far — say
                // that, rather than an em-dash that reads as "broken".
                HeroTile(
                    title: "Today",
                    value: ProviderCardCostRow.formatCost(todayCost ?? 0),
                    caption: todayCaption
                )

                if let weekly = snapshot.weeklyUsage {
                    let projected = weekly.projectedFinalPercent()
                    HeroTile(
                        title: "Pace",
                        value: projected.map { "→ \(Int($0.rounded()))%" } ?? "–",
                        caption: paceCaption(projected: projected),
                        accent: projected.map(paceAccent(for:))
                    )
                }

                if let credits = snapshot.credits {
                    HeroTile(
                        title: "Credits",
                        value: "$" + String(format: "%.2f", credits.amount),
                        caption: "balance"
                    )
                }

                if let devices = devicesTile {
                    HeroTile(title: "Devices", value: devices.value, caption: devices.caption)
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

    /// "↑ 38% vs 7d avg" — neutral text, not severity-tinted: spending
    /// more than usual is context, not an alarm (unlike quota pressure).
    /// Falls back to the plain "est. cost" label until the ledger has a
    /// week of history to compare against.
    private var todayCaption: String {
        guard let series = manager.ledger.dailyCosts[provider.kind] else { return "est. cost" }
        return OverviewSummary.deltaCaption(
            today: todayCost ?? 0,
            average: OverviewSummary.trailingDailyAverage(dailyCosts: [provider.kind: series])
        ) ?? "est. cost"
    }

    /// Devices tile: count + the cost split across Macs this month.
    /// nil for single-device accounts — a "1 / this Mac 100%" tile is
    /// dead weight. Surfaces what the ⊕ breakdown popover buries.
    private var devicesTile: (value: String, caption: String)? {
        let monthKey = LedgerCalendar.monthKey(for: .now)
        let contributions = manager.ledger.contributions(provider: provider.kind, monthKey: monthKey)
        guard contributions.count > 1 else { return nil }
        let total = contributions.reduce(0) { $0 + $1.costUSD }
        let caption: String
        if total > 0.005 {
            caption = contributions
                .sorted { $0.costUSD > $1.costUSD }
                .prefix(2)
                .map { "\($0.displayName) \(Int(($0.costUSD / total * 100).rounded()))%" }
                .joined(separator: " · ")
        } else {
            caption = "no cost this month"
        }
        return ("\(contributions.count)", caption)
    }

    /// "at reset" pace framing: reserve (under 100%) vs deficit (over).
    /// No projection yet (burn-rate gate: <20% of the window elapsed)
    /// gets an honest caption instead of a dash with no explanation.
    private func paceCaption(projected: Double?) -> String {
        guard let projected else { return "gathering data" }
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

    // MARK: - Account row

    /// Detail-tab footer inside the card: whose account this data belongs
    /// to. Matters the moment two accounts (or two Macs) are in play —
    /// the rest of the card never says who "you" is.
    @ViewBuilder
    private func accountRow(_ snapshot: UsageSnapshot) -> some View {
        if showsHero, let email = snapshot.email {
            VStack(alignment: .leading, spacing: 9) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(email)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    if let trailing = accountTrailing(snapshot) {
                        Text(trailing)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// "Max · 2 devices" — plan when known, device count when shared.
    private func accountTrailing(_ snapshot: UsageSnapshot) -> String? {
        var parts: [String] = []
        if let plan = snapshot.planName { parts.append(plan) }
        let monthKey = LedgerCalendar.monthKey(for: .now)
        let deviceCount = manager.ledger.contributions(provider: provider.kind, monthKey: monthKey).count
        if deviceCount > 1 { parts.append("\(deviceCount) devices") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Stale warning

    /// Shown beneath limits when the last refresh failed but cached data is
    /// still being displayed. Single line, amber, with no destructive
    /// styling — the data above is still useful.
    private func staleWarningRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9.5))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
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
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
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
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.tertiary)

            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(accent ?? .primary.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(caption)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary.opacity(0.75))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Hairline-only tile — crisper than a gray fill-on-gray-card.
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

// Small badge views (StaleDot, PlanPill, LiveBadge) live in
// ProviderCardBadges.swift.
