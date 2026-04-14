# UI Design — MyUsage

## Design Principles

1. **Native macOS feel** — Follow Apple HIG, use system backgrounds and vibrancy
2. **Restraint** — Minimal color usage; only accent colors on progress bars and provider icons
3. **Information density** — Show the most important info at a glance, details on expand
4. **Dark mode first** — Works with both light/dark, optimized for dark

## App Behavior

- **Menu Bar only** — No Dock icon, no main window
- **Popover** — Appears on click, dismisses on click outside
- **Width**: ~340pt fixed, adaptive height
- **No arrow**: Use `.popover` anchored to status item

## Component Hierarchy

```
UsagePopover
├── Header
│   ├── "MyUsage" title (left)
│   ├── "Updated Xs ago" (center, secondary text)
│   └── Refresh button (right)
├── Provider Cards (VStack, scrollable if needed)
│   ├── ProviderCard (Claude Code)
│   ├── ProviderCard (Codex)
│   ├── ProviderCard (Cursor)
│   └── ProviderCard (Antigravity)
└── Footer
    └── Settings gear icon (right)
```

## Provider Card Layout

### Standard Card (Claude / Codex)

```
┌──────────────────────────────────────┐
│ 🟣 Claude Code              Pro     │
│                                      │
│  ╭──────╮  Session (5h)       35%   │
│  │ 35%  │  ━━━━━━━━━░░░░░░░░░░░░   │
│  ╰──────╯  Weekly (7d)        18%   │
│            ━━━░░░░░░░░░░░░░░░░░░░   │
│                                      │
│  Resets in 2h 15m    user@email.com  │
└──────────────────────────────────────┘
```

- Left: circular progress ring (session %)
- Right: two labeled linear bars (session + weekly)
- Bottom: reset countdown + email

### Cursor Card

```
┌──────────────────────────────────────┐
│ 🔵 Cursor                   Ultra   │
│                                      │
│  Total Usage                  46%   │
│  ━━━━━━━━━━━━━━━░░░░░░░░░░░░░░░░   │
│  Auto: 12%  ·  API: 34%            │
│                                      │
│  $232.22 / $400.00                   │
│  Cycle: 15 days left                 │
└──────────────────────────────────────┘
```

- Single primary bar (total usage %)
- Breakdown text (auto / API splits)
- Dollar spent / budget
- Billing cycle countdown

### Antigravity Card

```
┌──────────────────────────────────────┐
│ 🟢 Antigravity               Pro    │
│                                      │
│  Claude Sonnet     ━━━━━━━━░░  82%  │
│  Gemini Pro        ━━━━░░░░░░  45%  │
│  Gemini Flash      ━░░░░░░░░░  12%  │
│                                      │
│  Resets in ~2h                       │
└──────────────────────────────────────┘
```

- Multiple mini horizontal bars, one per model
- Each shows model name + remaining % + bar
- Shared reset time (all models use same 5h window)

## Color System

| Element | Color |
|---------|-------|
| Background | System `.background` with vibrancy (`NSVisualEffectView` `.popover` material) |
| Card background | `.quaternarySystemFill` (subtle lift) |
| Primary text | `.primary` |
| Secondary text | `.secondary` |
| Progress — safe | System green (`Color.green`) |
| Progress — warning | System yellow (`Color.yellow`), used > 60% |
| Progress — danger | System red (`Color.red`), used > 85% |
| Claude accent | `#a78bfa` (purple) — icon only |
| Codex accent | `#4ade80` (green) — icon only |
| Cursor accent | `#60a5fa` (blue) — icon only |
| Antigravity accent | `#2dd4bf` (teal) — icon only |

Accent colors are used **only** on provider icons, not as broad tints.

## Provider Icons

Each provider card has a small (20×20) icon on the left:

- **Claude Code**: Custom purple mark (Anthropic logo style) or SF Symbol `brain.head.profile`
- **Codex**: Custom green mark (OpenAI logo style) or SF Symbol `terminal`
- **Cursor**: Custom blue mark or SF Symbol `cursorarrow.click.2`
- **Antigravity**: Custom teal mark (Google style) or SF Symbol `sparkles`

Prefer bundled small PNG/SVG icons for brand recognition. Fall back to SF Symbols if icon licensing is unclear.

## Menu Bar Icon

- SF Symbol: `gauge.with.dots.needle.33percent` (or similar gauge icon)
- Dynamic: icon tint changes based on worst-case remaining %
  - Green: all providers > 40% remaining
  - Yellow: any provider 15–40% remaining
  - Red: any provider < 15% remaining
- Template rendering for native macOS appearance

## Settings Window

Standard macOS Settings window (`Settings` scene in SwiftUI):

```
┌─ General ─────────────────────────────┐
│                                       │
│  Refresh Interval  [5 minutes  ▾]    │
│  Launch at Login   [Toggle     ]     │
│                                       │
├─ Providers ───────────────────────────┤
│                                       │
│  🟣 Claude Code   [Toggle] Detected  │
│  🟢 Codex         [Toggle] Detected  │
│  🔵 Cursor        [Toggle] Detected  │
│  🟢 Antigravity   [Toggle] Not found │
│                                       │
└───────────────────────────────────────┘
```

## UI Mockup Reference

See `docs/mockup.png` for the initial prototype mockup.
