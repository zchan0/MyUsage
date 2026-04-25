# Spec 07 — Polish & Launch

## Goal

Final polish: error states, animations, app icon, and launch preparation.

## Implementation Notes

> **Fix (2026-04-15): Refresh button has no visual feedback** — Added spinning
> animation (`rotationEffect` + `repeatForever`) on the refresh icon while
> `isRefreshing` is true.

## Deliverables

- [x] Error states for each provider card
  - [x] "Not configured" — credential file missing
  - [x] "Token refresh failed" — token refresh fails
  - [x] API error with retry button
  - [x] "IDE not running" — Antigravity when process not found
- [x] Loading states (spinner + "Loading…" while fetching)
- [x] Smooth animations on data updates (progress bar/ring transitions)
- [x] Dynamic menu bar icon tint (green/yellow/red based on worst provider)
- [x] App icon design (`Resources/AppIcon.appiconset/`) — squircle with a 4-bar gradient (green → cyan → blue → purple) on a soft-blue background
- [x] "About" section in Settings (version, GitHub link)
- [x] `.gitignore` for Xcode artifacts
- [x] README.md

## Unit Tests

- [ ] Menu bar icon color logic (deferred: logic in view, no unit test)

## Manual Verification Checklist

| # | Step | Expected | ✅/❌ |
|---|------|----------|------|
| 1 | All providers > 40% remaining | Menu bar icon is green | |
| 2 | One provider at 30% | Icon turns yellow | |
| 3 | One provider at 10% | Icon turns red | |
| 4 | Disconnect network, click refresh | "Fetch failed" with retry | |
| 5 | Remove Claude credentials | Claude card shows "Not configured" | |
| 6 | Close Antigravity IDE | Card shows "IDE not running" | |
| 7 | First launch (no data yet) | Loading skeleton shown briefly | |
| 8 | Popover opens with animation | Smooth, no flicker | |
| 9 | Data updates | Progress bars animate smoothly | |
| 10 | Check About in Settings | Version number and GitHub link shown | |
