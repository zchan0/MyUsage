import SwiftUI

/// Main popover content shown when clicking the menu bar icon.
///
/// The merged menu-bar popover. Width is stable at 348pt while height remains
/// content-driven. A single enabled provider opens directly into its Deck;
/// Overview and navigation exist only when they add value (2+ providers).
struct UsagePopover: View {
    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker

    @State private var selectedTab: PopoverTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            if enabledProviders.isEmpty {
                emptyState
            } else if enabledProviders.count == 1, let provider = enabledProviders.first {
                ProviderDeck(provider: provider)
            } else {
                tabBar

                switch effectiveTab {
                case .overview:
                    FocusOverview(providers: enabledProviders, selection: $selectedTab)
                case .provider(let kind):
                    detailPage(kind: kind)
                }
            }

            PopoverFooterBar()
        }
        .frame(width: PopoverLayout.width)
        .background { PopoverGlassSurface() }
        // Take the content's ideal height. The hosting panel measures this
        // (via onSizeChange) and resizes its window to match exactly — both
        // growing and shrinking — so there's never a leftover gap. Chrome
        // (rounded material + clear window + shadow) is owned by PopoverPanel.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Subviews

    private var tabBar: some View {
        ProviderTabBar(
            items: enabledProviders.map { provider in
                .init(kind: provider.kind)
            },
            selection: $selectedTab
        )
    }

    /// Provider tab: one card, expanded with the hero stat row.
    @ViewBuilder
    private func detailPage(kind: ProviderKind) -> some View {
        if let provider = enabledProviders.first(where: { $0.kind == kind }) {
            ProviderDeck(provider: provider)
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

#if DEBUG
#Preview("Focus · 2 providers") {
    let manager = PreviewFixtures.manager(providerCount: 2)
    UsagePopover()
        .environment(manager)
        .environment(UpdateChecker())
}

#Preview("Deck · 1 provider") {
    let manager = PreviewFixtures.manager(providerCount: 1)
    UsagePopover()
        .environment(manager)
        .environment(UpdateChecker())
}
#endif
