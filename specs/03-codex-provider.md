# Spec 03 — Codex Provider

## Goal

Implement the Codex provider: read OAuth tokens from `auth.json`, refresh tokens, fetch usage data, and render a provider card.

## Data Source

- **Credential**: `~/.codex/auth.json` → `$CODEX_HOME/auth.json` → Keychain `Codex Auth`
- **Refresh**: `POST https://auth.openai.com/oauth/token` (form-encoded)
- **Usage**: `GET https://chatgpt.com/backend-api/wham/usage`
- See `docs/architecture.md` for full API details.

## Deliverables

- [x] `CodexProvider.swift` — Conforms to `UsageProvider`
  - [x] Read `auth.json` with multi-path lookup (`CODEX_HOME`, `~/.config/codex/`, `~/.codex/`)
  - [x] Token refresh (form-encoded POST)
  - [x] Fetch usage API → populate `UsageSnapshot`
  - [x] `isAvailable` based on auth file existence
- [x] Token refresh logic (inline in CodexProvider)
- [x] Provider card rendering (reuse `ProviderCard` with Codex styling)

## Implementation Notes

> **Fix (2026-04-15):** `credits.balance` field — OpenAI API may return this as
> either a JSON number (`5.39`) or a string (`"150.0"`). `CodexCredits` uses a
> custom `init(from:)` to decode both types. Ref: CodexBar handles the same
> inconsistency.

## Unit Tests

- [x] Parse `auth.json` → extract `access_token`, `refresh_token`, `account_id`, `last_refresh`
- [x] `last_refresh` > 8 days → needs refresh
- [x] Parse usage response:
  - [x] `primary_window.used_percent` → `sessionUsage.percentUsed`
  - [x] `secondary_window.used_percent` → `weeklyUsage.percentUsed`
  - [x] `credits.balance` → `credits.balance` (Double or String)
  - [x] `credits.has_credits = false` → credits nil
  - [x] `plan_type` → `planName`
- [x] **`balance` as String** → decoded to Double correctly
- [x] Reset timestamps (unix seconds → `Date`)
- [ ] Auth file lookup order priority (deferred: logic exists, no dedicated test)

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
