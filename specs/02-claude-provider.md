# Spec 02 — Claude Code Provider

## Goal

Implement the Claude Code provider: read local credentials, refresh OAuth tokens, fetch usage data, and render a provider card.

## Data Source

- **Credential**: `~/.claude/.credentials.json` → Keychain `Claude Code-credentials`
- **Refresh**: `POST https://platform.claude.com/v1/oauth/token`
- **Usage**: `GET https://api.anthropic.com/api/oauth/usage`
- See `docs/architecture.md` for full API details.

## Deliverables

- [x] `ClaudeProvider.swift` — Conforms to `UsageProvider`
  - [x] Read credentials from file, fallback to Keychain
  - [x] Token expiry check + auto-refresh
  - [x] Fetch usage API → populate `UsageSnapshot`
  - [x] `isAvailable` based on credential file existence
    - ⚠️ Later found too narrow: modern Claude Code CLI is Keychain-only.
      Fixed to detect both sources. See
      [`docs/claude-not-configured-bug.md`](../docs/claude-not-configured-bug.md).
- [x] `KeychainHelper.swift` — Read Keychain items by service name
- [x] Token refresh logic (inline in ClaudeProvider, not separate file)
- [x] `ProviderCard.swift` — Render Claude card (circular ring + linear bar)
- [x] Wire Claude into `UsageManager`

## Unit Tests

- [x] Parse `credentials.json` → extract `accessToken`, `refreshToken`, `expiresAt`
- [x] Token expiry detection: expired / not-expired / about-to-expire (5min buffer)
- [x] Parse usage API response → `UsageSnapshot` mapping
  - [x] `five_hour.utilization` → `sessionUsage.percentUsed`
  - [x] `seven_day.utilization` → `weeklyUsage.percentUsed`
  - [x] `extra_usage` → `onDemandSpend`
  - [x] Missing `extra_usage` → no on-demand data
  - [ ] Missing `seven_day_opus` → no opus data (deferred: field not commonly used)
- [x] Reset time string → `Date` parsing (ISO 8601)
- [ ] Progress color thresholds (covered in view code, no unit test)
- [ ] Mock refresh response → token update logic (deferred: requires HTTP mocking)

## Manual Verification Checklist

| # | Step | Expected | ✅/❌ |
|---|------|----------|------|
| 1 | Have `~/.claude/.credentials.json` present | — | |
| 2 | Launch app, open popover | Claude Code card appears with purple icon | |
| 3 | Card shows plan badge | "Pro" / "Max" / etc. | |
| 4 | Session ring shows percentage | Matches `claude /usage` output | |
| 5 | Weekly bar shows percentage | Matches `claude /usage` output | |
| 6 | Reset countdown is shown | Plausible time (e.g. "2h 15m") | |
| 7 | Email displayed | Your account email in subtle text | |
| 8 | Remove `~/.claude/.credentials.json` *and* the Keychain item `Claude Code-credentials` | Card shows "Not configured" (if only the file is removed, Keychain is used) | |
| 9 | Wait for token to expire | App auto-refreshes without error | |
