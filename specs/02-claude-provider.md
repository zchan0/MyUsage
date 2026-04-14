# Spec 02 — Claude Code Provider

## Goal

Implement the Claude Code provider: read local credentials, refresh OAuth tokens, fetch usage data, and render a provider card.

## Data Source

- **Credential**: `~/.claude/.credentials.json` → Keychain `Claude Code-credentials`
- **Refresh**: `POST https://platform.claude.com/v1/oauth/token`
- **Usage**: `GET https://api.anthropic.com/api/oauth/usage`
- See `docs/architecture.md` for full API details.

## Deliverables

- [ ] `ClaudeProvider.swift` — Conforms to `UsageProvider`
  - [ ] Read credentials from file, fallback to Keychain
  - [ ] Token expiry check + auto-refresh
  - [ ] Fetch usage API → populate `UsageSnapshot`
  - [ ] `isAvailable` based on credential file existence
- [ ] `KeychainHelper.swift` — Read Keychain items by service name
- [ ] `TokenRefresher.swift` — Claude-specific token refresh
- [ ] `ProviderCard.swift` — Render Claude card (circular ring + linear bar)
- [ ] Wire Claude into `UsageManager`

## Unit Tests

- [ ] Parse `credentials.json` → extract `accessToken`, `refreshToken`, `expiresAt`
- [ ] Token expiry detection: expired / not-expired / about-to-expire (5min buffer)
- [ ] Parse usage API response → `UsageSnapshot` mapping
  - [ ] `five_hour.utilization` → `sessionUsage.percentUsed`
  - [ ] `seven_day.utilization` → `weeklyUsage.percentUsed`
  - [ ] `extra_usage` → `credits` (cents → dollars)
  - [ ] Missing `extra_usage` → `credits` is nil
  - [ ] Missing `seven_day_opus` → no opus data
- [ ] Reset time string → `Date` parsing (ISO 8601)
- [ ] Progress color: <60% green, 60-85% yellow, >85% red
- [ ] Mock refresh response → token update logic

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
| 8 | Remove `~/.claude/.credentials.json` | Card shows "Not configured" or disappears | |
| 9 | Wait for token to expire | App auto-refreshes without error | |
