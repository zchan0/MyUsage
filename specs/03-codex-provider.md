# Spec 03 — Codex Provider

## Goal

Implement the Codex provider: read OAuth tokens from `auth.json`, refresh tokens, fetch usage data, and render a provider card.

## Data Source

- **Credential**: `~/.codex/auth.json` → `$CODEX_HOME/auth.json` → Keychain `Codex Auth`
- **Refresh**: `POST https://auth.openai.com/oauth/token` (form-encoded)
- **Usage**: `GET https://chatgpt.com/backend-api/wham/usage`
- See `docs/architecture.md` for full API details.

## Deliverables

- [ ] `CodexProvider.swift` — Conforms to `UsageProvider`
  - [ ] Read `auth.json` with multi-path lookup (`CODEX_HOME`, `~/.config/codex/`, `~/.codex/`)
  - [ ] Token refresh (form-encoded POST)
  - [ ] Fetch usage API → populate `UsageSnapshot`
  - [ ] `isAvailable` based on auth file existence
- [ ] Token refresh in `TokenRefresher.swift` (Codex path)
- [ ] Provider card rendering (reuse `ProviderCard` with Codex styling)

## Implementation Notes

> **Fix (2026-04-15):** `credits.balance` field — OpenAI API may return this as
> either a JSON number (`5.39`) or a string (`"150.0"`). `CodexCredits` uses a
> custom `init(from:)` to decode both types. Ref: CodexBar handles the same
> inconsistency.

## Unit Tests

- [ ] Parse `auth.json` → extract `access_token`, `refresh_token`, `account_id`, `last_refresh`
- [ ] `last_refresh` > 8 days → needs refresh
- [ ] Parse usage response:
  - [ ] `primary_window.used_percent` → `sessionUsage.percentUsed`
  - [ ] `secondary_window.used_percent` → `weeklyUsage.percentUsed`
  - [ ] `credits.balance` → `credits.balance` (Double or String)
  - [ ] `credits.has_credits = false` → credits nil
  - [ ] `plan_type` → `planName`
- [ ] **`balance` as String** → decoded to Double correctly
- [ ] Reset timestamps (unix seconds → `Date`)
- [ ] Auth file lookup order priority

## Manual Verification Checklist

| # | Step | Expected | ✅/❌ |
|---|------|----------|------|
| 1 | Have `~/.codex/auth.json` present | — | |
| 2 | Launch app, open popover | Codex card appears with green icon | |
| 3 | Card shows plan badge | "Plus" / etc. | |
| 4 | Session ring shows percentage | Matches `codex /status` output | |
| 5 | Weekly bar shows percentage | Matches `codex /status` output | |
| 6 | Credits displayed (if applicable) | Shows dollar balance | |
| 7 | Reset countdown is shown | Plausible time | |
| 8 | Remove auth file | Card shows "Not configured" or disappears | |
