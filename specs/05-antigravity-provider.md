# Spec 05 — Antigravity Provider

## Goal

Implement the Antigravity provider: discover local language server process, extract CSRF token, probe ports, fetch per-model quotas, and render a multi-bar card.

## Data Source

- **Discovery**: `ps -ax` → find `language_server_macos.*antigravity` → extract `--csrf_token` and PID
- **Port**: `lsof -nP -iTCP -sTCP:LISTEN -p <pid>` → probe ports
- **Probe**: `POST http(s)://127.0.0.1:<port>/.../GetUnleashData` → first 200 OK
- **Usage**: `POST http(s)://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUserStatus`
- **Fallback**: `POST .../GetCommandModelConfigs` (no plan info)
- **SQLite fallback auth**: `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb` → `antigravityAuthStatus`
- See `docs/architecture.md` for full API details.

## Implementation Notes

> **Fix (2026-04-15): Port probing hang** — Original implementation tried HTTPS
> then HTTP on every listening port sequentially (3s timeout each). With many
> ports this could block 60s+, causing the UI to show "Loading…" indefinitely.
>
> Fix applied:
> 1. **Prioritize `extension_server_port`** from process args — probe it first.
> 2. **HTTP before HTTPS** — localhost servers typically use plain HTTP.
> 3. **15s overall timeout** on full port scan with `Task.cancel()` guard.
> 4. Fall back to `extension_server_port` if scan finds nothing.
>
> **Fix (2026-04-15): Pipe buffer deadlock** — `ProcessHelper.run()` called
> `waitUntilExit()` before `readDataToEndOfFile()`. `ps -axww` outputs ~116KB,
> exceeding the 64KB pipe buffer. Subprocess blocked on write, parent blocked on
> exit → deadlock. Fix: read pipe data first, then wait.
>
> **Fix (2026-04-15): Scheme mismatch** — `makeRequest` tried HTTP first and
> short-circuited on `ProviderError` (400), never reaching HTTPS. The probe had
> found HTTPS works. Fix: remember the working scheme from probe; `makeRequest`
> uses it directly. Also removed the `ProviderError` short-circuit so both
> schemes are tried when scheme is unknown.

## Deliverables

- [ ] `AntigravityProvider.swift` — Conforms to `UsageProvider`
  - [ ] Process discovery via `ps` + regex
  - [ ] CSRF token extraction from CLI args
  - [ ] Port discovery via `lsof`
  - [ ] Port probing (GetUnleashData) — with overall timeout guard
  - [ ] Usage fetch (GetUserStatus → GetCommandModelConfigs fallback)
  - [ ] Parse per-model quotas → `UsageSnapshot.modelQuotas`
  - [ ] `isAvailable` based on running process detection
- [ ] `ProcessHelper.swift` — Shell command wrappers for `ps` and `lsof`
- [ ] Antigravity-specific card layout (multi-bar per model)

## Unit Tests

- [ ] Parse `ps` output → PID + CSRF token + extension_server_port
  - [ ] Match `--app_data_dir antigravity`
  - [ ] Match path containing `/antigravity/`
  - [ ] No match → nil
- [ ] Parse `lsof` output → list of listening ports
- [ ] Parse `GetUserStatus` response:
  - [ ] `planName` → "Pro", "Free", etc.
  - [ ] `clientModelConfigs` → list of `ModelQuota`
  - [ ] `remainingFraction` 1.0 → 0% used, 0.0 → 100% used
  - [ ] `resetTime` ISO 8601 → `Date`
  - [ ] Dynamic model list (not hardcoded)
- [ ] Parse `GetCommandModelConfigs` fallback response
- [ ] Process not running → `isAvailable = false`

## Manual Verification Checklist

| # | Step | Expected | ✅/❌ |
|---|------|----------|------|
| 1 | Antigravity IDE is running | — | |
| 2 | Launch app, open popover | Antigravity card appears with teal icon | |
| 3 | Card shows plan badge | "Pro" / "Free" / etc. | |
| 4 | Multiple model bars shown | Claude Sonnet, Gemini Pro, etc. | |
| 5 | Each bar shows remaining % | Plausible percentages | |
| 6 | Reset time shown | Same for all models (~5h window) | |
| 7 | Close Antigravity IDE | Card shows "IDE not running" or disappears | |
| 8 | Reopen Antigravity IDE, click refresh | Card reappears with data | |
