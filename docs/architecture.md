# Architecture — MyUsage

## System Overview

```
┌─────────────────────────────────────────────────────┐
│                    Menu Bar Icon                     │
│              (NSStatusItem + Popover)                │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│                  UsageManager                        │
│  - Discovers available providers                     │
│  - Manages refresh timer                             │
│  - Publishes combined state for UI                   │
└──┬──────────┬──────────┬──────────┬─────────────────┘
   │          │          │          │
┌──▼───┐  ┌──▼───┐  ┌──▼────┐  ┌──▼──────────┐
│Claude│  │Codex │  │Cursor │  │Antigravity  │
│      │  │      │  │       │  │             │
│Local │  │OAuth │  │SQLite │  │Process Probe│
│ File │  │ API  │  │+ RPC  │  │ + Local RPC │
└──────┘  └──────┘  └───────┘  └─────────────┘
```

## Project Structure

```
MyUsage/
├── MyUsageApp.swift              # @main, NSStatusItem setup
├── Models/
│   ├── ProviderKind.swift        # Enum: .claude, .codex, .cursor, .antigravity
│   └── UsageSnapshot.swift       # Unified usage data model
├── Providers/
│   ├── UsageProvider.swift       # Protocol all providers conform to
│   ├── ClaudeProvider.swift      # Claude Code: local statusline snapshot
│   ├── CodexProvider.swift       # Codex: OAuth API
│   ├── CursorProvider.swift      # Cursor: SQLite + Connect RPC
│   └── AntigravityProvider.swift # Antigravity: process probe + local RPC
├── Services/
│   ├── UsageManager.swift        # Orchestrator: auto-detect, timer, state
│   ├── KeychainHelper.swift      # Security.framework Keychain reader
│   ├── ClaudeStatuslineBridge.swift   # Explicit integration + native collector
│   └── ClaudeStatuslineSnapshot.swift # Private local snapshot storage
├── Views/
│   ├── MenuBarIcon.swift         # NSStatusItem + popover host
│   ├── UsagePopover.swift        # Main popover container
│   ├── ProviderCard.swift        # Individual provider card
│   ├── ProviderDetailView.swift  # Expanded detail view
│   └── SettingsView.swift        # Preferences window
├── Utilities/
│   ├── ProcessHelper.swift       # Shell command wrappers (ps, lsof)
│   └── SQLiteHelper.swift        # C SQLite3 API wrapper
├── Resources/
│   └── Assets.xcassets           # App icon, provider icons
└── Tests/
    └── MyUsageTests/
        ├── ClaudeProviderTests.swift
        ├── CodexProviderTests.swift
        ├── CursorProviderTests.swift
        ├── AntigravityProviderTests.swift
        └── ClaudeStatuslineSnapshotTests.swift
```

## Provider identity and gateways

Runtime identity is `ProviderID`: stable `builtin:<kind>` IDs for installed tools and `gateway:<uuid>` IDs for saved connections. `ProviderSource` carries branding; names, URLs and API keys are not instance identity. The manager migrates legacy order/tracked-provider values to `.v2` keys and reads legacy built-in enabled flags. Existing built-in notification IDs are preserved.

`UsageProvider` exposes identity, availability, state, refresh and a typed `ProviderPayload`. `BuiltinUsageProvider` retains `ProviderKind` and `UsageSnapshot`, so its parsers and ledger queries keep their existing behavior. `GatewayProvider` owns an independent `GatewaySnapshot` with separately refreshed summary/history blocks. `ProviderDeck` dispatches to the built-in or gateway view; shared navigation/settings use instance IDs.

`GatewayConnectionStore` saves a versioned local configuration document in UserDefaults; it stores only a Keychain reference. A credential update stages a fresh Keychain item before swapping that reference. A host change requires a supplied key. Delete removes just that connection and local credential. No gateway configuration or server aggregate is added to `LedgerSync`.

Gateway credential reads distinguish missing items, authorization failures and other Keychain errors. Startup, automatic refresh and history reads remain non-interactive. Manual refresh and the editor's usage check may retry an ACL-blocked read with system authorization, preserving the stored item and reference across ad-hoc build changes. Explicit automation prompt-suppression flags still take precedence.

The `GatewayAdapter` protocol defines usage-access checks, summary reads and history reads. Only `LiteLLMAdapter` is registered: self `/key/info`, explicitly scoped `/user/info`, and optional `/user/daily/activity`. It maps amounts to Decimal, distinguishes absent/unlimited/zero budgets and preserves missing counts. User history is UTC month-to-date; key history is unsupported until filtering is verified. Pagination, permissions and partial results belong to the adapter. Shared transport uses an ephemeral session, refuses redirects and caps each host at two requests.

LiteLLM model history maps `breakdown.model_groups` to client-facing aliases and their metrics, including the group's reported request count. Deployment-level `breakdown.models` is ignored because its names and failed-request coverage differ. Missing/null model groups mark the model breakdown incomplete while preserving daily totals; a reported empty group dictionary remains distinct from missing data.

Gateway refresh coalesces duplicate requests and rejects results from cancelled/obsolete configuration revisions. History loads on demand with a five-minute in-memory TTL; manual refresh updates the visible detail. Retry-After suppresses immediate retries. Only usable finite budgets feed pressure/notification calculations. See [gateway design](gateway-provider-design.md) and [validation](gateway-provider-validation.md) for the implementation boundaries and remaining live checks.

## Provider Data Sources

### Claude Code

Claude Code's official statusline input is the only subscription-quota source. See [official rate-limit fields](https://code.claude.com/docs/en/statusline#rate-limit-usage).

```text
Claude Code → statusline wrapper → MyUsage --claude-statusline → local snapshot
                            └──→ original statusline command (unchanged input/output)
UsageManager → ClaudeProvider → local snapshot + existing JSONL cost/token parsers
```

- `ClaudeStatuslineBridge` wraps only an explicitly enabled user-level `statusLine.command`. It retains the original command in a private installation record, preserves other configuration fields, and refuses to overwrite subsequent command edits. Startup and refresh never install it. The native command dispatches before SwiftUI, AppKit, and provider initialization.
- `ClaudeStatuslineSnapshot` allowlists schema version, local receipt time, session ID, Claude Code version, and optional `five_hour` / `seven_day` windows. Percentages are 0–100; reset times are Unix seconds. Invalid or missing windows remain unknown. Other stdin fields are discarded without being written to disk.
- `ClaudeStatuslineStore` uses `Application Support/MyUsage/ClaudeStatusline/snapshots`, outside all sync paths. Directories are user-owned `0700`, files/locks `0600`, with symlink checks. Per-session SHA-256 filenames separate concurrent sessions; `flock` serializes writers and same-directory atomic rename prevents partial reads. Older receipts cannot overwrite newer receipts for the same session. Reads select one latest valid receipt, never sum sessions or merge windows. Damaged files are reported even if another valid receipt remains readable.
- States are not connected, waiting, valid local receipt, stale, and invalid. A 15-minute age policy labels old receipts, without asserting server freshness. Expired windows are omitted at read time. A local transition task updates observation at reset/age boundaries even when automatic polling is disabled. LimitNotifier accepts Claude observations only from a valid, enabled ClaudeProvider; retained old/disconnected/waiting/invalid snapshots do not dispatch new notifications or advance tier state. Manual/automatic refresh only reads local files; no credentials, OAuth usage/profile requests, CLI probes, or delegated refresh exist in this source.
- Statusline events may repeat unchanged quota; local receipt time is not a server sample timestamp. With Claude Code stopped or no new data, only a dated old snapshot can be shown. Window absence after the first API response can also mean an ineligible subscription; it does not mean zero usage.
- Email, plan, per-model subscription caps, and extra-usage billing are not supplied. The UI does not reuse OAuth profile data or derive identity from a session ID. JSONL costs/tokens remain independent. New ledger days use its existing `default` bucket; existing unique daily storage keys are reused solely to prevent duplicate counting, never as current account identity. Ambiguous legacy days remain unchanged with an explicit cost-history notice. No ledger schema, sync format, or other provider changes are needed.
- Legacy credential/usage caches are not read or migrated; existing Keychain items are left untouched. Existing statusline scripts can independently read credentials or call APIs; preserving them does not make those behaviors part of the new collector.

**Billing model:** Optional rolling 5h + 7d subscription windows, separate from estimated JSONL cost.

---

### Codex

| Item | Detail |
|------|--------|
| **Credential** | `~/.codex/auth.json` → Keychain `Codex Auth` |
| **Token type** | OAuth JWT (refresh when `last_refresh` > 8 days) |
| **Refresh** | `POST https://auth.openai.com/oauth/token` (form-encoded) |
| **Client ID** | `app_EMoamEEZ73f0CkXaXp7hrann` |
| **Usage API** | `GET https://chatgpt.com/backend-api/wham/usage` |
| **Headers** | `Authorization: Bearer <token>` |

**Response fields:**
- `rate_limit.primary_window.used_percent` — 5h window %
- `rate_limit.secondary_window.used_percent` — 7-day window %
- `credits.balance` — remaining dollars
- `credits.has_credits` / `credits.unlimited`
- `code_review_rate_limit` — separate weekly code review limit
- `plan_type` — "plus", etc.

**Billing model:** Rolling windows (5h + 7d) + optional purchased credits.

---

### Cursor

| Item | Detail |
|------|--------|
| **Credential** | SQLite `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| **Keys** | `cursorAuth/accessToken`, `cursorAuth/refreshToken`, `cursorAuth/cachedEmail`, `cursorAuth/stripeMembershipType` |
| **Token type** | JWT (short-lived, refresh before each request if expired) |
| **Refresh** | `POST https://api2.cursor.sh/oauth/token` |
| **Client ID** | `KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB` |
| **Usage API (primary)** | `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` |
| **Plan API** | `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo` |
| **Headers** | `Authorization: Bearer <token>`, `Connect-Protocol-Version: 1`, `Content-Type: application/json` |
| **Fallback API** | `GET https://cursor.com/api/usage?user=<userId>` with `Cookie: WorkosCursorSessionToken=<token>` |

**Response fields (GetCurrentPeriodUsage):**
- `planUsage.totalPercentUsed`, `autoPercentUsed`, `apiPercentUsed`
- `planUsage.totalSpend` / `limit` / `remaining` (cents)
- `billingCycleStart` / `billingCycleEnd` (unix ms string)
- `spendLimitUsage` — on-demand budget (individual/pooled)

**GetPlanInfo response:**
- `planInfo.planName`, `includedAmountCents`, `price`, `billingCycleEnd`

**Billing model:** Monthly billing cycle with included budget (cents) + on-demand.

---

### Antigravity

| Item | Detail |
|------|--------|
| **Discovery** | `ps -ax` → find `language_server_macos.*antigravity`, extract `--csrf_token` |
| **Port** | `lsof -nP -iTCP -sTCP:LISTEN -p <pid>` → probe each port |
| **Probe** | `POST https://127.0.0.1:<port>/.../GetUnleashData` → first 200 OK |
| **Usage API** | `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUserStatus` |
| **Fallback** | `POST .../GetCommandModelConfigs` |
| **Headers** | `x-codeium-csrf-token: <token>`, `Connect-Protocol-Version: 1` |
| **SQLite fallback** | `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb` → `antigravityAuthStatus` |

**Response fields:**
- `userStatus.planStatus.planInfo.planName` — "Free" / "Pro" / "Teams" / "Ultra"
- `userStatus.cascadeModelConfigData.clientModelConfigs[]`
  - `.label` — "Gemini 3 Pro (High)", "Claude Sonnet 4.5", etc.
  - `.quotaInfo.remainingFraction` — 0.0–1.0
  - `.quotaInfo.resetTime` — ISO 8601

**Billing model:** Per-model quota with 5h rolling window, fraction-based.

## Token Refresh Summary

| Provider | Trigger | Endpoint | Auth |
|----------|---------|----------|------|
| Claude | No credential refresh; local statusline receipt only | None | None |
| Codex | `last_refresh` > 8 days or 401/403 | `auth.openai.com/oauth/token` | `refresh_token` + `client_id` (form-encoded) |
| Cursor | JWT expired or 401 | `api2.cursor.sh/oauth/token` | `refresh_token` + `client_id` |
| Antigravity | N/A (CSRF from process) | N/A | CSRF token from CLI args |
