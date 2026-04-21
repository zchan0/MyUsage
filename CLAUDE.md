# CLAUDE.md — MyUsage Development Guide

## Project Overview

**MyUsage** is a native macOS menu bar app (Swift/SwiftUI, macOS 14+) that monitors AI coding tool usage across Claude Code, Codex, Cursor, and Antigravity.

- Repo: https://github.com/zchan0/MyUsage.git
- Language: Swift 6, SwiftUI
- Target: macOS 14+ (Sonoma)
- Dependencies: None (built-in SQLite3, Security.framework, Foundation)

## Version Control — jj Workflow

We use **jj** (Jujutsu) for version control, feature-by-feature development.

### Per-Feature Flow

```bash
# 1. Start a new feature
jj new -m "feat: <feature-name>"

# 2. Develop + test locally
# ... write code, write/run unit tests ...

# 3. When done, squash into a clean commit
jj squash

# 4. Push to GitHub
jj git push --create  # creates remote branch if needed
```

### Branch / Bookmark Naming

- `main` — stable, always buildable
- `feat/<feature-name>` — feature branches (e.g. `feat/claude-provider`)

### Commit Message Convention

```
feat: short description       # new feature
fix: short description        # bug fix
docs: short description       # documentation only
test: short description       # adding/updating tests
refactor: short description   # code restructuring
chore: short description      # build, config, deps
```

### Commit & Push Authority

The agent owns the commit + push lifecycle by default. When a task is done
and verified locally (build + tests green), the agent should, without
asking for per-operation approval:

1. Split the work into coherent commits using `jj describe` + `jj split`.
   Granularity is at the agent's discretion — prefer cohesion over hitting
   an arbitrary commit count, and keep each commit buildable.
2. Create or move the feature bookmark (`feat/<feature-name>`).
3. Push with `jj git push` (use `--create` when the remote bookmark
   doesn't exist yet).

The agent **must** still ask for explicit approval before any of the
following, because they are hard to undo or affect shared history:

- Pushing to or merging into `main` / `master`.
- Force push (`--force`, `--force-with-lease`).
- Creating or moving a release tag (`vX.Y.Z`) or triggering a release workflow.
- Deleting remote bookmarks / branches / tags.
- Changing git config, skipping hooks, or rewriting already-pushed history.

If pre-push tests fail, fix the cause and try again — never bypass the check.

## Testing Strategy

### Unit Tests (XCTest)

All logic that doesn't require network or system state must have unit tests:

- Token/credential file parsing
- API response JSON → model mapping
- OAuth token refresh logic (with mock responses)
- Progress percentage calculations
- Reset time formatting
- Provider availability detection

Run tests:
```bash
xcodebuild test -scheme MyUsage -destination 'platform=macOS'
```

### BDD Manual Tests

Each feature spec (`specs/*.md`) contains a **Manual Verification Checklist**. After implementing a feature:

1. Build and run the app
2. Walk through the checklist items
3. Mark each item ✅ or ❌
4. All items must pass before pushing

### SwiftUI Previews

All views must have `#Preview` blocks with mock data so UI can be verified without live API calls.

## Feature Development Order

| # | Feature | Spec File |
|---|---------|-----------|
| 1 | Project Skeleton | `specs/01-project-skeleton.md` |
| 2 | Claude Code Provider | `specs/02-claude-provider.md` |
| 3 | Codex Provider | `specs/03-codex-provider.md` |
| 4 | Cursor Provider | `specs/04-cursor-provider.md` |
| 5 | Antigravity Provider | `specs/05-antigravity-provider.md` |
| 6 | Settings & Auto-Refresh | `specs/06-settings-refresh.md` |
| 7 | Polish & Launch | `specs/07-polish.md` |

## Code Conventions

- **SwiftUI first**: All UI in SwiftUI, minimal AppKit (only `NSStatusItem`)
- **Async/await**: Use structured concurrency, no Combine
- **@Observable**: Use Observation framework (macOS 14+), not `ObservableObject`
- **No 3rd-party deps**: Everything uses system frameworks
- **Error handling**: Providers never crash; surface errors as UI states
- **File organization**: Group by layer (Models / Providers / Services / Views / Utilities)
