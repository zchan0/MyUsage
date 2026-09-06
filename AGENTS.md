# MyUsage Development Guide

## Project overview

MyUsage is a native macOS 14+ menu-bar app that aggregates usage from Claude Code, Codex, Cursor, and Antigravity, including user-owned multi-device sync.

- `README.md` is the source of truth for shipped behavior and local usage.
- `docs/architecture.md` describes the current architecture; verify details against code when they differ.
- `specs/` records feature decisions and acceptance criteria. Numbered specs are not an active implementation queue unless the user names one as current.
- The Swift package, implementation, and tests are authoritative for current APIs and file layout.

## Build and verification

Use the same checks as CI, starting with the narrowest relevant tests:

```sh
swift test
xcodebuild build -scheme MyUsage -destination 'platform=macOS' -skipPackagePluginValidation
```

Use `./Scripts/package_app.sh` only when the task needs an app bundle. For user-visible behavior, run the relevant manual checklist from the active spec when one exists. Add or update tests for deterministic parsing, mapping, calculations, refresh behavior, and provider availability; do not make live credentials or network state a unit-test requirement.

## Version control

The repository is colocated `jj + git`; use `jj status`, `jj diff`, and `jj log` for inspection. Work in the existing working-copy change unless the user asks for a new change or bookmark.

- Preserve unrelated working-copy changes.
- Do not create/split/describe commits, move bookmarks, push, tag, or release unless the user explicitly asks.
- Before handoff, show the changed files and verification results so the user can review the diff.
- Never bypass hooks or checks, force-push, or rewrite published history without explicit approval.

## Code conventions

- Prefer SwiftUI and Observation (`@Observable`); use AppKit where menu-bar, window, event-monitoring, keychain, or system integration requires it.
- Use structured concurrency and follow the existing layer boundaries under `Models`, `Providers`, `Services`, `Views`, `MenuBar`, and `Utilities`.
- Keep the package free of third-party dependencies unless the user explicitly approves one.
- Providers must surface missing credentials, unavailable tools, API failures, and stale data as recoverable UI states rather than crashing.
- Never log, commit, or include real credentials, OAuth tokens, local database contents, or user-specific sync data in fixtures.
- Add `#Preview` coverage when it materially helps review a changed view and follow adjacent preview patterns; it is not required for every small helper view.
