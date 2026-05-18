#if DEBUG
import Foundation

/// Debug helper: inject two demo accounts per multi-account-capable
/// provider so the popover renders the swipeable account switcher
/// without the user actually setting up multiple Claude / Codex /
/// Cursor accounts. Lets early users / the maintainer eyeball the
/// multi-account UX in seconds.
///
/// Demo accounts use the reserved `myusage-demo.local` domain — they
/// look like normal emails in the popover (so the demo is convincing)
/// but are unambiguous to detect for cleanup. Disable wipes them via
/// the same `forgetAccount` path real users would use.
@MainActor
enum MockMultiAccount {

    /// Reserved domain — anything `*@myusage-demo.local` is fake demo
    /// data we own and may delete on disable. RFC 6761 reserves
    /// `.local` for mDNS; using a sub-host inside it keeps us safely
    /// off any registrable namespace.
    static let demoDomain = "myusage-demo.local"

    /// Providers we inject demo accounts for. Antigravity has no
    /// per-account billing, so demo accounts there would be noise.
    private static let providers: [ProviderKind] = [.claude, .codex, .cursor]

    /// Per-provider demo accounts. Two each so the count flips into
    /// multi-account mode (the real signed-in account is the third —
    /// switcher renders 3 cards).
    private static func demoAccounts(for kind: ProviderKind) -> [DemoAccount] {
        [
            DemoAccount(
                id: "demo-work@\(demoDomain)",
                planLabel: planLabel(for: kind),
                sessionPercent: 47,
                weeklyPercent: 62,
                monthlyCost: 321.00
            ),
            DemoAccount(
                id: "demo-personal@\(demoDomain)",
                planLabel: planLabel(for: kind),
                sessionPercent: 12,
                weeklyPercent: 28,
                monthlyCost: 43.10
            )
        ]
    }

    private static func planLabel(for kind: ProviderKind) -> String {
        switch kind {
        case .claude: "Max"
        case .codex: "Plus"
        case .cursor: "Pro"
        case .antigravity: ""
        }
    }

    private struct DemoAccount {
        let id: String
        let planLabel: String
        let sessionPercent: Double
        let weeklyPercent: Double
        let monthlyCost: Double
    }

    // MARK: - Enable / disable

    /// Inject demo accounts + sample ledger rows. Idempotent — calling
    /// twice doesn't double up (recordObservation is upsert-style and
    /// ledger rows are keyed by source_hash, so duplicates collapse).
    static func enable(manager: UsageManager) async {
        let monthKey = LedgerCalendar.monthKey(for: .now)
        for kind in providers {
            // Remember the real active account so we can restore it
            // after recordObservation flips active to the last-injected
            // demo one.
            let realActive = manager.accountStore.activeAccountID(for: kind)

            for demo in demoAccounts(for: kind) {
                let identity = AccountIdentity(
                    id: demo.id,
                    email: demo.id,
                    displayName: demo.id
                )
                let snapshot = makeSnapshot(for: kind, demo: demo)
                manager.accountStore.recordObservation(
                    provider: kind,
                    identity: identity,
                    snapshot: snapshot
                )
                // Sprinkle a few daily ledger rows across this month so
                // the per-account cost row + cross-device math have
                // something to render. Goes through the debug-only
                // `injectLocalRowsForDebug` so demo data NEVER hits the
                // user's iCloud / Dropbox sync folder (where it would
                // propagate to every peer Mac and contaminate real
                // aggregates). Days are seeded deterministically off
                // the demo ID so reruns produce the same numbers.
                manager.ledger.injectLocalRowsForDebug(
                    provider: kind,
                    accountID: demo.id,
                    byDay: makeMonthlyByDay(monthlyCost: demo.monthlyCost, monthKey: monthKey)
                )
            }

            // Restore the real active pointer so live data still drives
            // the active card. If there was no real account observed
            // yet, leave active wherever recordObservation last set it
            // — the real refresh will reset it on the next cycle.
            if let realActive {
                manager.accountStore.activate(provider: kind, accountID: realActive)
            }
        }
    }

    /// Remove every account whose ID lives in the demo domain, plus its
    /// ledger rows on this device. Calls the same underlying primitives
    /// as the real Settings → Forget action — just inline-awaits them so
    /// the cleanup is deterministic (the production `forgetAccount`
    /// fires a Task per call to avoid blocking the UI; for test +
    /// orchestration we want serial completion).
    static func disable(manager: UsageManager) async {
        for kind in providers {
            let demoIDs = manager.accountStore.accounts(for: kind)
                .map(\.accountID)
                .filter { $0.hasSuffix("@\(demoDomain)") }
            for id in demoIDs {
                await manager.ledger.forgetAccountRows(provider: kind, accountID: id)
                manager.accountStore.forget(provider: kind, accountID: id)
            }
        }
    }

    // MARK: - Snapshot + ledger row construction

    private static func makeSnapshot(
        for kind: ProviderKind,
        demo: DemoAccount,
        now: Date = .now
    ) -> UsageSnapshot {
        var s = UsageSnapshot()
        s.planName = demo.planLabel
        s.email = demo.id
        s.lastRefreshed = now
        s.monthlyEstimatedCost = demo.monthlyCost

        switch kind {
        case .claude, .codex:
            s.sessionUsage = UsageWindow(
                percentUsed: demo.sessionPercent,
                resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60),
                windowDuration: 5 * 3600
            )
            s.weeklyUsage = UsageWindow(
                percentUsed: demo.weeklyPercent,
                resetsAt: now.addingTimeInterval(5 * 86_400 + 12 * 3600),
                windowDuration: 7 * 86_400
            )
            if kind == .claude {
                let split = demo.weeklyPercent
                s.weeklyByModel = [
                    WeeklyModelUsage(label: "Sonnet", percent: split * 0.62),
                    WeeklyModelUsage(label: "Opus", percent: split * 0.38)
                ]
            }
        case .cursor:
            s.totalUsagePercent = demo.weeklyPercent
            s.spentAmount = CreditInfo(
                amount: demo.monthlyCost * 0.6,
                limit: 60,
                currency: "USD"
            )
            s.onDemandSpend = CreditInfo(
                amount: demo.monthlyCost * 0.4,
                limit: nil,
                currency: "USD"
            )
            s.billingCycleEnd = now.addingTimeInterval(14 * 86_400)
        case .antigravity:
            break
        }
        return s
    }

    /// Spread a monthly cost across 5 days of the current month so
    /// `monthlyTotalsByAccount` has multi-day data to roll up. Days are
    /// chosen deterministically (1, 5, 10, 15, 20) so re-enabling demo
    /// doesn't churn.
    private static func makeMonthlyByDay(
        monthlyCost: Double,
        monthKey: String
    ) -> [String: Double] {
        let perDay = monthlyCost / 5.0
        return [1, 5, 10, 15, 20].reduce(into: [:]) { dict, day in
            dict["\(monthKey)-\(String(format: "%02d", day))"] = perDay
        }
    }
}
#endif
