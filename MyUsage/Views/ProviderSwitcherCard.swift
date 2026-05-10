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
        VStack(spacing: 7) {
            ProviderCard(
                provider: provider,
                account: currentAccount,
                isActive: isCurrentActive
            )
            switcher
        }
        // Re-anchor on the active account whenever the active pointer
        // moves (e.g. user signed in as a different account, refresh
        // updated the registry). Without this, a user mid-browse of the
        // inactive cards would jump back unexpectedly — but on first
        // appearance after a sign-in we *do* want to land on the live one.
        .onChange(of: accounts.map(\.accountID).joined(separator: "|")) { _, _ in
            selectedIndex = min(selectedIndex, max(accounts.count - 1, 0))
        }
    }

    private var currentAccount: AccountStore.AccountRecord {
        accounts[min(selectedIndex, accounts.count - 1)]
    }

    private var isCurrentActive: Bool {
        currentAccount.accountID == manager.accountStore.activeAccountID(for: provider.kind)
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
