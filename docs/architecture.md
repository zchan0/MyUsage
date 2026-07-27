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
│OAuth │  │OAuth │  │SQLite │  │Process Probe│
│ API  │  │ API  │  │+ RPC  │  │ + Local RPC │
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
│   ├── ClaudeProvider.swift      # Claude Code: OAuth API
│   ├── CodexProvider.swift       # Codex: OAuth API
│   ├── CursorProvider.swift      # Cursor: SQLite + Connect RPC
│   └── AntigravityProvider.swift # Antigravity: process probe + local RPC
├── Services/
│   ├── UsageManager.swift        # Orchestrator: auto-detect, timer, state
│   ├── KeychainHelper.swift      # Security.framework Keychain reader
│   └── TokenRefresher.swift      # Shared OAuth refresh logic
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
        └── TokenRefresherTests.swift
```

## Provider Data Sources

### Claude Code

| Item | Detail |
|------|--------|
| **Credential** | `~/.claude/.credentials.json` → Keychain `Claude Code-credentials` |
| **Token type** | OAuth JWT (short-lived, auto-refresh) |
| **Refresh** | `POST https://platform.claude.com/v1/oauth/token` |
| **Client ID** | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| **Usage API** | `GET https://api.anthropic.com/api/oauth/usage` |
| **Headers** | `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20` |

**Response fields:**
- `five_hour.utilization` — % used in 5h rolling window
- `five_hour.resets_at` — ISO 8601
- `seven_day.utilization` — % used in 7-day window
- `limits[]` entries with `kind = weekly_scoped` — dynamic model-specific
  weekly limits such as Fable (optional)
- `seven_day_opus` / `seven_day_sonnet` — legacy model-specific weekly
  limits (optional)
- `seven_day_routines` and legacy aliases including `seven_day_cowork` —
  Daily Routines weekly limit (optional; a reported `null` remains a visible
  0% allowance)
- `extra_usage` — monthly overage credits in cents (optional)

**Billing model:** Rolling windows (5h + 7d simultaneous), hitting either throttles.

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
| Claude | 5m before expiry or 401/403 | `platform.claude.com/v1/oauth/token` | `refresh_token` + `client_id` |
| Codex | `last_refresh` > 8 days or 401/403 | `auth.openai.com/oauth/token` | `refresh_token` + `client_id` (form-encoded) |
| Cursor | JWT expired or 401 | `api2.cursor.sh/oauth/token` | `refresh_token` + `client_id` |
| Antigravity | N/A (CSRF from process) | N/A | CSRF token from CLI args |
