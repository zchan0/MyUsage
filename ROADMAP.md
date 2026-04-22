# MyUsage Roadmap

Near-term direction for the project. Each item links to (or will link to)
a detailed spec under `specs/`. Feature ordering reflects priority, not a
hard timeline.

## Near-term

### 1. Fix Claude Code provider — shows `API error (429)`
- **Symptom**: Claude card intermittently surfaces `API error (429)` and stops updating.
- **Spec**: [`specs/10-fix-claude-429.md`](specs/10-fix-claude-429.md)
- **Scope**: network hardening only (User-Agent, Retry-After, stale-snapshot retention, jittered refresh). No new UI features.

### 2. Usage ledger + multi-device sync
- **Problem**: Monthly cost is currently estimated from *this Mac's* local CLI logs. Users on multiple machines see each device's cost in isolation.
- **Spec**: `specs/11-usage-ledger.md` (TBD, starts after #1 lands)
- **Approach (phased)**
  - **Phase 1** — Manual export/import. Each device can export a JSON ledger file to a user-chosen folder; import merges ledgers from other devices in the same folder.
  - **Phase 2** — iCloud Drive watched folder. Drop ledger into a shared folder, aggregation is automatic.
- **Out of scope for v1**: self-hosted sync server, real-time streaming.

### 3. Multi-account aggregation
- **Problem**: Users may have separate Claude Pro + Claude Team subscriptions, or personal + work Cursor. Today MyUsage assumes one account per provider.
- **Spec**: `specs/12-multi-account.md` (TBD, builds on #2)
- **Approach**: The ledger from #2 should key entries by `(account_id, device_id, month, model)` from day one. Multi-account becomes a grouping concern in the UI rather than a new data path.
- **Realistic shape**: Each Mac still has one account per provider (CLI tools only store one credential). Multi-account in practice = multi-device × one-account-per-device, aggregated by account.

## Non-goals (for now)

- Antigravity cost estimation (no local token data source).
- Self-hosted sync backend.
- Windows / Linux support.
- Historical time-series charts.

## Open questions

- Ledger storage format: append-only JSONL vs SQLite? (leaning JSONL for diff-friendly sync)
- Account identifier source: OAuth `sub` claim? account email? user-provided alias? Privacy tradeoffs differ.
- Should the ledger store raw token counts or only aggregated USD cost? Tokens give us flexibility to re-price retroactively if rates change, but doubles storage.
- When ledgers from two devices disagree for the same hour/session, what wins? (unlikely but needs a rule)

## Completed

- `v0.2.0` — Monthly cost estimation (Claude / Codex / Cursor, single device) + automated GitHub Releases.
- `v0.1.x` — Core providers, settings, polish (specs 01–08).

## Fixes

- Claude card stuck on "Not configured" for Keychain-only users
  ([`docs/claude-not-configured-bug.md`](docs/claude-not-configured-bug.md)).
- Claude 429 rate-limit hardening ([`specs/10-fix-claude-429.md`](specs/10-fix-claude-429.md)).
