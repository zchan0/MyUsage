# Spec 04 — Cursor Provider

## Goal

Implement the Cursor provider: read auth from local SQLite DB, refresh JWT, fetch usage via Connect RPC, and render a billing-cycle card.

## Data Source

- **Credential**: SQLite `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
  - Keys: `cursorAuth/accessToken`, `cursorAuth/refreshToken`, `cursorAuth/cachedEmail`, `cursorAuth/stripeMembershipType`
- **Refresh**: `POST https://api2.cursor.sh/oauth/token`
- **Usage (primary)**: `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` (Connect RPC v1)
- **Plan**: `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo`
- **Fallback**: `GET https://cursor.com/api/usage?user=<userId>` with session cookie (existing extension approach)
- See `docs/architecture.md` for full API details.

## Reference

Existing Cursor extension code at `~/Developer/Copilot/CursorUsageMonitor/src/services/` — specifically `auth.ts` (SQLite token read) and `cursorApi.ts` (usage API + data parsing).

## Implementation Notes

> **Fix (2026-04-15): Usage values inaccurate** — `mapToSnapshot` used hardcoded
> budget + derived on-demand calculation. This diverged from
> CursorUsageMonitor's values. Fix:
> 1. Use `planUsage.limit` (API-reported budget) before hardcoded fallback.
> 2. Use `planUsage.includedSpend` (API-reported included spend) when available.
> 3. Use `spendLimitUsage.individualUsed` for on-demand (API-reported).
> 4. Hardcoded `includedBudgetCents` only used as last-resort fallback.

## Deliverables

- [ ] `CursorProvider.swift` — Conforms to `UsageProvider`
  - [ ] Read tokens from `state.vscdb` via SQLite3 C API
  - [ ] Token refresh (JWT check + POST)
  - [ ] Fetch usage (Connect RPC) → populate `UsageSnapshot`
  - [ ] Fallback to cursor.com/api/usage if Connect RPC fails
  - [ ] `isAvailable` based on `state.vscdb` existence
- [ ] `SQLiteHelper.swift` — Lightweight SQLite3 reader
- [ ] Cursor-specific card layout (total %, auto/API split, dollar amounts, cycle countdown)

## Unit Tests

- [ ] Parse `state.vscdb` key-value extraction (mock SQLite data)
- [ ] JWT expiry check
- [ ] Parse `GetCurrentPeriodUsage` response:
  - [ ] `totalPercentUsed` → `totalUsagePercent`
  - [ ] `autoPercentUsed`, `apiPercentUsed` → breakdown
  - [ ] `totalSpend` / `limit` (cents → dollars)
  - [ ] `billingCycleEnd` (unix ms string → Date)
  - [ ] `spendLimitUsage` → on-demand budget
- [ ] Parse `GetPlanInfo` response → plan name + price
- [ ] Fallback API response parsing (legacy format)
- [ ] Session cookie construction: `userId%3A%3A<accessToken>`
- [ ] Billing cycle days remaining calculation

## Manual Verification Checklist

| # | Step | Expected | ✅/❌ |
|---|------|----------|------|
| 1 | Cursor Desktop installed with active subscription | — | |
| 2 | Launch app, open popover | Cursor card appears with blue icon | |
| 3 | Card shows plan badge | "Pro" / "Ultra" / "Team" | |
| 4 | Total usage % displayed | Matches Cursor Settings → Usage | |
| 5 | Auto/API breakdown shown | Plausible split | |
| 6 | Dollar amounts shown | Spent / budget in dollars | |
| 7 | Billing cycle countdown | "X days left" matches reality | |
| 8 | Uninstall Cursor | Card shows "Not configured" or disappears | |
