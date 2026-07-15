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
                staleWarningRow(staleMessage)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                heroSection(snapshot)
                ProviderCardLimits(kind: provider.kind, snapshot: snapshot, cached: false)
                ProviderCardCostRow(kind: provider.kind, snapshot: snapshot)
            }
        }
    }

    /// Big-number stat row shown only on the provider's own tab
    /// (`showsHero`), and only for kinds with rolling windows — Cursor /
    /// Antigravity have no 5h/weekly pair to headline.
    @ViewBuilder
    private func heroSection(_ snapshot: UsageSnapshot) -> some View {
        if showsHero, provider.kind == .claude || provider.kind == .codex,
           snapshot.sessionUsage != nil || snapshot.weeklyUsage != nil {
            HStack(spacing: 8) {
                if let session = snapshot.sessionUsage {
                    HeroStat(title: "5-HOUR", window: session)
                }
                if let weekly = snapshot.weeklyUsage {
                    HeroStat(title: "WEEKLY", window: weekly)
                }
            }
            .padding(.bottom, 1)
        }
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

/// One big-number stat tile in the hero row: tiny tracked-out label,
/// 24pt severity-tinted percentage, reset line underneath. Two of these
/// side by side (5-hour / Weekly) headline a provider's detail tab.
struct HeroStat: View {
    let title: String
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary.opacity(0.75))

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(window.percentUsed.rounded()))")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(level.accent)

            if let reset = window.resetCountdown {
                Text("resets \(reset)")
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    /// Takes the higher of the current-usage band and the projection
    /// band, mirroring `LimitBar.level`, so the hero number and the bar
    /// below it never disagree about severity.
    private var level: LimitSafety.Level {
        let current = LimitSafety.level(for: window.percentUsed)
        guard let projected = window.projectedFinalPercent(), projected > 100 else {
            return current
        }
        return max(current, projected > 150 ? .crit : .warn)
    }
}

// Small badge views (StaleDot, PlanPill, LiveBadge) live in
// ProviderCardBadges.swift.
