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
- **Spec**: [`specs/11-usage-ledger.md`](specs/11-usage-ledger.md)
- **Approach**: local SQLite ledger on each device, append-only JSONL per device in `~/Library/Mobile Documents/com~apple~CloudDocs/MyUsage/devices/<device-id>/`, watched via `NSMetadataQuery`. Peer devices merge rows into their own SQLite; device-scoped primary keys eliminate write conflicts.
- **Out of scope for v1**: self-hosted sync server, real-time streaming, retroactive re-pricing (entries store USD at time of recording).

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
- Claude OAuth self-refresh removed — MyUsage is now a passive reader that
  defers token rotation to the Claude CLI
  ([`docs/claude-token-rotation-bug.md`](docs/claude-token-rotation-bug.md)).
