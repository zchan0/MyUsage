import SwiftUI

/// Main popover content shown when clicking the menu bar icon.
///
/// Tabbed layout (CodexBar-lite):
///   · Header: wordmark · "X ago" (mono) · refresh
///   · Tab strip: `Overview` + one brand-tile tab per enabled provider
///   · Overview tab: the full card stack — one ProviderCard per enabled
///     provider, 7pt gap (each card carries its own border)
///   · Provider tab: that provider's card expanded with the hero stat
///     row (big 5h / weekly numbers)
///   · Footer: settings gear, with a single hairline above
struct UsagePopover: View {
    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker

    @State private var selectedTab: PopoverTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            header

            if enabledProviders.isEmpty {
                emptyState
            } else {
                tabBar

                switch effectiveTab {
                case .overview:
                    overviewStack
                case .provider(let kind):
                    detailPage(kind: kind)
                }
            }

            PopoverFooterBar()
        }
        .frame(width: 340)
        // Take the content's ideal height. The hosting panel measures this
        // (via onSizeChange) and resizes its window to match exactly — both
        // growing and shrinking — so there's never a leftover gap. Chrome
        // (rounded material + clear window + shadow) is owned by PopoverPanel.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Text("MyUsage")
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(-0.2)

            Spacer()

            if let lastRefreshed = manager.lastRefreshed {
                RelativeTimestampLabel(date: lastRefreshed)
            }

            PopoverRefreshButton()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var tabBar: some View {
        ProviderTabBar(
            providers: enabledProviders.map(\.kind),
            selection: $selectedTab
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
    }

    // MARK: - Pages

    /// Overview: the full card stack.
    ///
    /// Plain VStack — NO ScrollView. The popover panel sizes itself to
    /// this content's intrinsic height, so a ScrollView would have no
    /// height to fill and collapse to zero (the cards would vanish). A
    /// plain VStack sizes to its cards and renders reliably; there are
    /// only ever a handful of provider cards, so scrolling buys nothing.
    private var overviewStack: some View {
        VStack(spacing: 7) {
            ForEach(enabledProviders, id: \.kind) { provider in
                ProviderCard(provider: provider)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// Provider tab: one card, expanded with the hero stat row.
    @ViewBuilder
    private func detailPage(kind: ProviderKind) -> some View {
        if let provider = enabledProviders.first(where: { $0.kind == kind }) {
            VStack(spacing: 7) {
                ProviderCard(provider: provider, showsHero: true)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No providers detected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Install Claude Code, Codex, Cursor, or Antigravity to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Helpers

    private var enabledProviders: [any UsageProvider] {
        manager.orderedProviders.filter { $0.isEnabled }
    }

    /// Falls back to Overview when the selected provider tab's provider
    /// was disabled while its page was showing (e.g. toggled off in
    /// Settings).
    private var effectiveTab: PopoverTab {
        if case .provider(let kind) = selectedTab,
           !enabledProviders.contains(where: { $0.kind == kind }) {
            return .overview
        }
        return selectedTab
    }
}

#Preview {
    UsagePopover()
        .environment(UsageManager())
        .environment(UpdateChecker())
}
