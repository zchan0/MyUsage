# Spec 01 — Project Skeleton

## Goal

Set up the Xcode project, menu bar infrastructure, and empty popover. This is the foundation all other features build on.

## Deliverables

- [x] Xcode project: `MyUsage.xcodeproj`, Swift 6, macOS 14+
- [x] `MyUsageApp.swift` — `@main` entry, `MenuBarExtra`
- [x] `MenuBarIcon.swift` — Status item with dynamic tint
- [x] `UsagePopover.swift` — Popover with header, cards, footer
- [x] `SettingsView.swift` — Full settings (General/Providers/About tabs)
- [x] `UsageManager.swift` — Orchestrator with timer + auto-detect
- [x] `UsageProvider.swift` — Protocol definition
- [x] `UsageSnapshot.swift` — Data model
- [x] `ProviderKind.swift` — Enum
- [x] App has no Dock icon (`LSUIElement = true`)
- [x] App builds and runs without errors

## Unit Tests

- [x] `ProviderKind` enum: `allCases`, `displayName`
- [x] `UsageSnapshot` default values, worst usage, model quotas

## Manual Verification Checklist

| # | Step | Expected | ✅/❌ |
|---|------|----------|------|
| 1 | Build and run the app | No errors, no Dock icon | |
| 2 | Look at menu bar | Gauge icon appears | |
| 3 | Click menu bar icon | Popover opens with "MyUsage" header | |
| 4 | Click outside popover | Popover dismisses | |
| 5 | Click gear icon in footer | Settings window opens | |
| 6 | Check settings window | Shows placeholder content | |
