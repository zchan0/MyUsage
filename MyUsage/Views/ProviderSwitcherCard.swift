import SwiftUI

/// Multi-account container around `ProviderCard`. Renders one card at a
/// time; user flips through accounts via arrow buttons (and a dot strip
/// for orientation). Used when ≥ 2 accounts have been observed for a
/// provider — see spec 15 + the v3 mockup.
///
/// The active account always anchors at index 0 (it's the most-recently-
/// seen by `lastSeenAt` desc). Inactive accounts trail behind in the same
/// order. Selecting one shows that account's cached snapshot under a
/// `StaleSnapshotBanner` with a saturate(0.65) wash so the eye doesn't
/// confuse it with live data.
struct ProviderSwitcherCard: View {
    let provider: any UsageProvider
    let accounts: [AccountStore.AccountRecord]

    @Environment(UsageManager.self) private var manager
    @State private var selectedIndex: Int = 0

    var body: some View {
        // Defensive: `accounts` can transiently shrink to empty during a
        // SwiftUI update — e.g. when Mock multi-account is disabled and a
        // provider's demo-only account set drops to zero before the
        // parent swaps this view back to a plain ProviderCard. Indexing
        // an empty array would trap and take the whole app down (this was
        // the "all providers disappeared" crash). Render nothing until
        // the parent re-resolves the slot.
        if let activeIdx = Self.safeIndex(selected: selectedIndex, count: accounts.count) {
            VStack(spacing: 7) {
                // Render EVERY account card in a ZStack and reveal the
                // selected one via opacity. The ZStack is always as tall
                // as the tallest card, so switching accounts changes only
                // which card is visible — never the layout height. That
                // keeps the popover (and the MenuBarExtra window) at a
                // stable height across switches; otherwise each switch
                // resizes the window and the bottom flickers transparent/
                // white during the resize. The card heights within one
                // provider are close (same bars), so the reserved height
                // is barely larger than any single card.
                ZStack(alignment: .top) {
                    ForEach(Array(accounts.enumerated()), id: \.element.accountID) { index, account in
                        ProviderCard(
                            provider: provider,
                            account: account,
                            isActive: account.accountID == manager.accountStore.activeAccountID(for: provider.kind)
                        )
                        .opacity(index == activeIdx ? 1 : 0)
                        .allowsHitTesting(index == activeIdx)
                        .accessibilityHidden(index != activeIdx)
                    }
                }
                if accounts.count >= 2 {
                    switcher
                }
            }
            // Re-anchor whenever the account set changes (sign-in, refresh,
            // forget) — clamp the selection into range so we never point
            // past the end after the array shrinks.
            .onChange(of: accounts.map(\.accountID).joined(separator: "|")) { _, _ in
                selectedIndex = min(max(selectedIndex, 0), max(accounts.count - 1, 0))
            }
        }
    }

    /// Clamp a selection index into `0..<count`, or nil when `count == 0`.
    /// Extracted + `nonisolated static` so the "shrinking accounts array
    /// shouldn't trap" invariant is unit-testable from a plain synchronous
    /// (non-MainActor) test context — it's pure math with no view state.
    nonisolated static func safeIndex(selected: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(selected, 0), count - 1)
    }

    /// Arrow / dot strip below the card. Tap arrows to step through;
    /// dot strip widens the active dot so the user can read position
    /// without counting.
    private var switcher: some View {
        HStack(spacing: 14) {
            switcherArrow(systemName: "chevron.left", enabled: selectedIndex > 0) {
                selectedIndex = max(0, selectedIndex - 1)
            }
            dotStrip
            switcherArrow(systemName: "chevron.right", enabled: selectedIndex < accounts.count - 1) {
                selectedIndex = min(accounts.count - 1, selectedIndex + 1)
            }
        }
        .padding(.top, 1)
    }

    private func switcherArrow(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(enabled ? 1.0 : 0.25)
        .disabled(!enabled)
    }

    private var dotStrip: some View {
        HStack(spacing: 5) {
            ForEach(Array(accounts.enumerated()), id: \.element.accountID) { (index, _) in
                Capsule()
                    .fill(Color.primary.opacity(index == selectedIndex ? 0.55 : 0.22))
                    .frame(width: index == selectedIndex ? 14 : 5, height: 5)
                    .animation(.easeInOut(duration: 0.18), value: selectedIndex)
                    .onTapGesture { selectedIndex = index }
            }
        }
    }
}
