# MyUsage Roadmap

Near-term direction for the project. Each item links to (or will link to)
a detailed spec under `specs/`. Feature ordering reflects priority, not a
hard timeline.

## Near-term

### 1. Claude data source hardening (disk cache + token-expiry UX)
- **Problem**: The Claude card blanks / shows `Retrying …` whenever the OAuth token expires, Anthropic returns 429/5xx, or the machine is offline. There is no on-disk persistence between app launches.
- **Spec**: [`specs/11-claude-data-sources.md`](specs/11-claude-data-sources.md)
- **Approach**: cache-first refresh. `/api/oauth/usage` responses are persisted to `~/Library/Caches/MyUsage/claude-usage.json` (fingerprinted by the refresh token so switching accounts invalidates automatically). Monthly cost gets a separate mtime-gated cache against `~/.claude/projects/**/*.jsonl`. UI never blanks — stale numbers + `Last refreshed N min ago` label + existing error row.
- **Out of scope for v1**: JSONL-based approximation of 5h/7d utilization (would conflict with Anthropic's exact values), statusLine bridge (deferred to spec 11b), Admin API.

### 2. Usage ledger + multi-device sync
- **Problem**: Monthly cost is currently estimated from *this Mac's* local CLI logs. Users on multiple machines see each device's cost in isolation.
- **Spec**: [`specs/12-usage-ledger.md`](specs/12-usage-ledger.md)
- **Scope**: **only Claude and Codex monthly cost** go through the ledger. Cursor stays on its account-level billing API; Antigravity has no local cost source. Account-level signals (5h / 7d / extra usage) never enter the ledger — they're already unified upstream.
- **Approach**: local SQLite ledger per device (never synced), append-only JSONL per device in `~/Library/Mobile Documents/com~apple~CloudDocs/MyUsage/devices/<device-id>/`, watched via `NSMetadataQuery`. Each device is the sole writer of its own folder, so physical conflicts are impossible. Peer devices merge rows into their own SQLite.
- **UI**: cards show aggregate with a `⊕ N` badge when ≥ 2 devices are synced; clicking the cost row opens a per-device breakdown popover. Settings → Devices lists every contributor.
- **Out of scope for v1**: self-hosted sync server, real-time streaming, retroactive re-pricing (entries store USD at time of recording), iOS companion app, CloudKit (needs entitlements we don't have).

### 3. Multi-account aggregation
- **Problem**: Users may have separate Claude Pro + Claude Team subscriptions, or personal + work Cursor. Today MyUsage assumes one account per provider.
- **Spec**: `specs/13-multi-account.md` (TBD, builds on #2)
- **Approach**: The ledger from #2 already keys entries by `(account_id, device_id, month, model)` from day one (v1 hardcodes `account_id = "default"`). Multi-account becomes a grouping concern in the UI rather than a new data path.
- **Realistic shape**: Each Mac still has one account per provider (CLI tools only store one credential). Multi-account in practice = multi-device × one-account-per-device, aggregated by account.

### 4. Claude statusLine bridge (opt-in fallback)
- **Problem**: Even with disk cache, a user whose token has been expired for > 24h and who hasn't touched the CLI will see increasingly stale numbers. Claude Code CLI v2.1.80+ ships a statusLine hook that pipes fresh rate-limit JSON on every CLI invocation — cheap and first-party.
- **Spec**: `specs/11b-claude-statusline.md` (TBD, builds on #1)
- **Approach**: ship an optional helper script (`MyUsage-statusline`) that the user points `~/.claude/settings.json`'s `statusLine.command` at. The script writes each payload to a known file; `ClaudeProvider` watches it and treats it as a higher-priority source than the OAuth cache when fresh.
- **Gate**: only proceed once spec 11 ships and we have user signal that the base cache isn't enough.

## Non-goals (for now)

- Antigravity cost estimation (no local token data source).
- Self-hosted sync backend.
- Windows / Linux support.
- Historical time-series charts.

## Open questions

- **Account identifier source** (for spec 13): OAuth `sub` claim? account email? user-provided alias? Privacy tradeoffs differ. Blocked until we have the first real multi-account user.
- **statusLine opt-in UX** (spec 11b): patch `~/.claude/settings.json` automatically with user consent, or print instructions for the user to paste? The first is nicer but touches a file the CLI also writes; the second is safer but higher friction.

Resolved in spec 12:
- Ledger format → both (SQLite local, JSONL wire).
- Token counts vs USD → USD only; re-pricing is explicitly not a goal.
- Cross-device conflicts → impossible by construction (one writer per device folder).
- Ledger scope → Claude + Codex cost only; Cursor / Antigravity stay off the ledger.
- Transport → per-device JSONL under iCloud Drive's public `com~apple~CloudDocs/` path (no entitlement, works with ad-hoc signing). CloudKit / CoreData-with-CloudKit explicitly ruled out.

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
