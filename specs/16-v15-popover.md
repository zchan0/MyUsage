# Feature 16 — v15 Comparable Popover

## Goal

Turn the menu-bar panel into a compact provider comparison first, then an
account-first detail view, while keeping cost and token scopes truthful.

## Behavior

- The merged popover starts directly with provider tabs; the redundant
  `MyUsage` title row is removed and freshness moves to the footer.
- Overview renders one shared row shape for every provider, ordered by the
  primary metric's pressure score.
- `Needs attention` is reserved for a projected breach or >=90% current use.
  The 75% warning band remains available inside provider Detail.
- Each Overview row owns its provider's cost and labels the scope (`month` for
  Claude/Codex, `cycle` for Cursor). Providers without cost data show no fake
  zero or placeholder.
- Detail starts with account identity (email, account source, plan) rather than
  repeating the selected provider name.
- Limit rails are continuous capsules. Their fill uses a restrained provider
  tint; forecast text still communicates risk.
- Claude/Codex Detail shows a trailing-30-day model-cost chart using one muted
  provider hue with opacity-based model layers.
- Claude/Codex Detail shows trailing-30-day Total/Input/Output/Cache token
  totals aggregated across all ledger accounts and synced devices.

## Ledger Compatibility

- JSONL wire v3 and SQLite schema v3 add optional daily `TokenUsage` buckets.
- v1/v2 JSONL remains readable; migrated SQLite rows keep `token_usage = NULL`.
- Re-scanning a day can add token attribution without changing its cost.
- Claude server-priced rows retain their reported cost while still recording
  the token fields contained in the same log row.

## Manual Verification Checklist

- [x] Four-provider merged Overview is 348pt wide, pressure ordered, and has no
  clipped tab or provider text.
- [x] Overview cost appears only in its provider row with the correct scope.
- [x] One-provider Claude Detail opens directly with account identity and no
  redundant provider/title header.
- [x] Claude Weekly sorts ahead of 5-hour when its projected risk is higher;
  both rails use Claude's restrained brand tint.
- [x] Claude/Codex charts show three date anchors, muted provider colors, and
  readable legends in light and dark appearances.
- [x] Token summary shows Total/Input/Output/Cache and labels the range as
  `30 days · all accounts`.
- [x] Codex reset credits, Cursor billing limits, and Antigravity model quotas
  still render without clipping.
- [x] A v2 SQLite ledger migrates in place and v1/v2 JSONL imports remain valid.
- [x] `xcodebuild test -scheme MyUsage -destination 'platform=macOS'` passes.
- [x] Release build succeeds.
