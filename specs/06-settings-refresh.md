# Spec 06 — Settings & Auto-Refresh

## Goal

Build the Settings window and implement automatic periodic refresh with configurable intervals.

## Implementation Notes

> **Fix (2026-04-15): Settings button unresponsive** — Footer used
> `NSApp.sendAction(Selector(("showSettingsWindow:")))`, a private AppKit
> selector that doesn't work reliably inside `MenuBarExtra` popover. Replaced
> with SwiftUI-native `SettingsLink` (macOS 14+).
>
> **Fix (2026-04-15): Refresh only fires once** — `.task {}` in popover body
> only runs once per SwiftUI view lifetime, so subsequent popover opens didn't
> trigger refresh. Split into:
> - `.onAppear` → `refreshAll()` (fires every popover open)
> - `.task(id: "init")` → `startTimer()` (fires once)

## Deliverables

- [x] `SettingsView.swift` — Full settings implementation
  - [x] General tab: refresh interval picker, launch at login toggle
  - [x] Providers tab: per-provider enable/disable toggles with detection status
  - [x] About tab: version, GitHub link
- [x] `UsageManager.swift` — Timer-based auto-refresh
  - [x] Configurable intervals: 1m, 2m, 5m, 15m, manual
  - [x] Timer restarts when interval changes
  - [x] Manual refresh button in popover triggers immediate refresh
- [x] Auto-detect providers on launch (check credential existence)
- [x] Persist settings via `UserDefaults`
- [x] Launch at Login via `SMAppService` (macOS 14+)

## Unit Tests

- [x] Refresh interval enum: raw values, display names, seconds
- [ ] Provider auto-detection round-trip (deferred: requires mock filesystem)
- [ ] Settings persistence round-trip (deferred: requires app lifecycle test)

## Manual Verification Checklist

| # | Step | Expected | ✅/❌ |
|---|------|----------|------|
| 1 | Open Settings → General | Refresh interval picker shown, default 5m | |
| 2 | Change to 1 minute | Popover updates every ~1 minute | |
| 3 | Change to manual | No auto-refresh, only manual button works | |
| 4 | Toggle Launch at Login on | App appears in System Settings → Login Items | |
| 5 | Open Settings → Providers | All detected providers shown with toggles | |
| 6 | Disable a provider | Its card disappears from popover | |
| 7 | Re-enable provider | Card reappears and data refreshes | |
| 8 | Quit and reopen app | Settings are preserved | |
