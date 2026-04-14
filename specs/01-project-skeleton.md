# Spec 01 — Project Skeleton

## Goal

Set up the Xcode project, menu bar infrastructure, and empty popover. This is the foundation all other features build on.

## Deliverables

- [x] Xcode project: `MyUsage.xcodeproj`, Swift 6, macOS 14+
- [ ] `MyUsageApp.swift` — `@main` entry, `MenuBarExtra` or `NSStatusItem`
- [ ] `MenuBarIcon.swift` — Status item with gauge SF Symbol
- [ ] `UsagePopover.swift` — Empty popover with header ("MyUsage" + refresh button) and footer (settings gear)
- [ ] `SettingsView.swift` — Placeholder settings window
- [ ] `UsageManager.swift` — Empty manager, publishes empty provider list
- [ ] `UsageProvider.swift` — Protocol definition
- [ ] `UsageSnapshot.swift` — Data model
- [ ] `ProviderKind.swift` — Enum
- [ ] App has no Dock icon (`LSUIElement = true`)
- [ ] App builds and runs without errors

## Unit Tests

- [ ] `ProviderKind` enum: `allCases`, `displayName`, `accentColor`
- [ ] `UsageSnapshot` default values

## Manual Verification Checklist

| # | Step | Expected | ✅/❌ |
|---|------|----------|------|
| 1 | Build and run the app | No errors, no Dock icon | |
| 2 | Look at menu bar | Gauge icon appears | |
| 3 | Click menu bar icon | Popover opens with "MyUsage" header | |
| 4 | Click outside popover | Popover dismisses | |
| 5 | Click gear icon in footer | Settings window opens | |
| 6 | Check settings window | Shows placeholder content | |
