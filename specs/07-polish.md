# Spec 07 — Polish & Launch

## Goal

Final polish: error states, animations, app icon, and launch preparation.

## Implementation Notes

> **Fix (2026-04-15): Refresh button has no visual feedback** — Added spinning
> animation (`rotationEffect` + `repeatForever`) on the refresh icon while
> `isRefreshing` is true.

## Deliverables

- [ ] Error states for each provider card
  - [ ] "Not configured" — credential file missing
  - [ ] "Authentication failed" — token refresh fails
  - [ ] "Fetch failed" — API error with retry button
  - [ ] "IDE not running" — Antigravity when process not found
- [ ] Loading states (skeleton cards while fetching)
- [ ] Smooth animations on data updates (progress bar transitions)
- [ ] Dynamic menu bar icon tint (green/yellow/red based on worst provider)
- [ ] App icon design (`Assets.xcassets`)
- [ ] "About" section in Settings (version, GitHub link)
- [ ] `.gitignore` for Xcode artifacts
- [ ] README.md with screenshots and setup instructions

## Unit Tests

- [ ] Menu bar icon color logic: all green, any yellow, any red

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
