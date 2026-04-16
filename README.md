# MyUsage

Native macOS menu bar app that monitors AI coding tool usage across **Claude Code**, **Codex**, **Cursor**, and **Antigravity** — all in one place.

![MyUsage Screenshot](docs/screenshot.png)

## Features

- **One glance** — All your AI tool usage in a single popover.
- **Menu bar usage** — Optionally show live usage value (e.g. `$125` for Cursor, `57%` for Claude).
- **Auto-refresh** — Configurable intervals (1m / 2m / 5m / 15m / manual).
- **Brand icons** — Each provider displays its recognizable brand icon.
- **Per-model quotas** — Antigravity shows individual model limits (Claude, Gemini, etc.).
- **On-demand tracking** — Cursor shows included budget + on-demand spend separately.
- **Custom ordering** — Drag to reorder providers in Settings.
- **Launch at Login** — Set-and-forget via macOS Login Items.
- **Zero dependencies** — Built entirely with system frameworks (SwiftUI, SQLite3, Security).

## Supported Providers

| Provider | Data Source | What's Shown |
|----------|-----------|--------------|
| **Claude Code** | OAuth API (`~/.claude/.credentials.json` / Keychain) | 5h session + 7d weekly usage, extra usage credits |
| **Codex** | OAuth API (`~/.codex/auth.json` / Keychain) | 5h session + 7d weekly usage, credits balance |
| **Cursor** | SQLite + Connect RPC (`state.vscdb`) | Included budget, on-demand spend, billing cycle |
| **Antigravity** | Local language server process probe | Per-model quota (remaining fraction + reset time) |

## Requirements

- macOS 14+ (Sonoma)
- At least one supported AI tool installed and authenticated

## Build & Run

```bash
# Build
swift build -c release

# Package as .app bundle
./Scripts/package_app.sh

# Open
open MyUsage.app
```

Or open in Xcode via the SwiftPM workspace:

```bash
open .swiftpm/xcode/package.xcworkspace
```

## Project Structure

```
MyUsage/
├── MyUsageApp.swift              # @main, MenuBarExtra setup
├── Models/                       # ProviderKind, UsageSnapshot
├── Providers/                    # Claude, Codex, Cursor, Antigravity
├── Services/                     # UsageManager, KeychainHelper
├── Views/                        # MenuBarIcon, UsagePopover, ProviderCard, SettingsView
└── Utilities/                    # ProcessHelper, SQLiteHelper, Logger
```

## How It Works

Each provider reads local credentials (files, Keychain, or SQLite), calls the respective usage API, and maps the response into a unified `UsageSnapshot`. The `UsageManager` orchestrates refresh timing and publishes state to the SwiftUI views.

- **Claude / Codex** — OAuth token refresh + REST API
- **Cursor** — SQLite token read + Connect RPC (protobuf-over-HTTP)
- **Antigravity** — Process discovery via `ps` → port probe via `lsof` → Connect RPC to local language server

## Settings

Open Settings from the gear icon in the popover footer:

- **General** — Refresh interval, menu bar usage display, Launch at Login
- **Providers** — Enable/disable and drag-to-reorder providers
- **About** — Version info, GitHub link

## License

MIT
