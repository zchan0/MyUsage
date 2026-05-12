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
                ProviderCardLimits(kind: provider.kind, snapshot: snapshot)
                ProviderCardCostRow(kind: provider.kind, snapshot: snapshot, account: account)
                staleWarningRow(staleMessage)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ProviderCardLimits(kind: provider.kind, snapshot: snapshot)
                ProviderCardCostRow(kind: provider.kind, snapshot: snapshot, account: account)
            }
        }
    }

    // Limit-bar block lives in ProviderCardLimits.swift — accessed via
    // `ProviderCardLimits(kind: provider.kind, snapshot:)`.

    // MARK: - Cost row

    // Cost row + per-account aggregate scoping live in
    // ProviderCardCostRow.swift — accessed via
    // `ProviderCardCostRow(kind:, snapshot:, account:)`.

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

}

// Small badge views (StaleDot, PlanPill, LiveBadge) live in
// ProviderCardBadges.swift.
