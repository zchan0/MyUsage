# Spec 12a — Sync Folder (any transport)

## Goal

Spec 12 hardcoded the sync path to iCloud Drive's public `com~apple~CloudDocs` folder. In practice, plenty of users can't or don't want to use iCloud — corporate Macs with iCloud disabled, users who self-host with Syncthing / Resilio / Nextcloud, users on Dropbox / OneDrive, users on a mounted NAS share.

This spec removes the iCloud assumption by collapsing the concept to a single **Sync folder** path. MyUsage just reads and writes inside one user-picked directory. What keeps that directory in sync across Macs is the user's choice:

- iCloud Drive (continues to work; becomes the default suggestion)
- Syncthing (recommended for self-hosted, end-to-end encrypted sync)
- Dropbox / OneDrive / Resilio Sync / pCloud / …
- A mounted SMB/NFS share, a shared external drive, rclone bisync, git-annex — anything that makes a folder "look the same" on two Macs

MyUsage's contract is narrow and stable: *"If two Macs write into the same folder, we aggregate correctly."* How that folder stays synced is out of scope.

This follows the Obsidian / Logseq model: one vault/graph, user-owned, the app is agnostic about the transport.

## Scope

### In scope

- A single `Sync folder` setting (URL + security-scoped bookmark) replacing the implicit iCloud path.
- First-run default suggestion: the existing iCloud `com~apple~CloudDocs/MyUsage` folder if iCloud Drive is active, otherwise `~/Documents/MyUsage`.
- A unified change-detection strategy that works for any local path (iCloud Drive folder, Syncthing share, NAS mount, plain disk).
- Graceful handling when the folder is temporarily unreachable (unplugged drive, unmounted share, Syncthing paused).
- Zero-touch migration for existing users on the current iCloud-hardcoded build.

### Non-goals

- **No sync-tool integration.** We do not detect, install, configure, or talk to Syncthing / Dropbox / iCloud. They run independently and we only see their output in the filesystem.
- **No transport picker UI.** There is no `iCloud vs Custom` radio. There is only `Sync folder: <path>`.
- **No built-in sync engine.** MyUsage is not a sync product.
- **No encryption at rest.** JSONL contains device UUIDs and daily USD totals — users who want encryption point the folder at an encrypted disk image, a Syncthing folder with ignore-perms, or a FileVault volume.
- **No multi-folder sharding** (e.g., different folder per account). One folder, one ledger namespace.
- **No cross-platform.** Mac-to-Mac only (iOS companion would be a separate spec).

## Current state (after spec 12)

| Layer | Today |
|---|---|
| `SyncRoot` | Protocol with `UbiquitySyncRoot` (prod) + `LocalSyncRoot` (tests) |
| Path | Hard-coded `~/Library/Mobile Documents/com~apple~CloudDocs/MyUsage/devices/` |
| Availability | `FileManager.default.ubiquityIdentityToken != nil` |
| Change detection | `NSMetadataQuery` scoped to `NSMetadataQueryUbiquitousDocumentsScope` |
| UI | No path/config surface; iCloud either works or sync is silently off |

`LedgerWriter` / `LedgerReader` already take a `SyncRoot` by injection, so the data-plane is transport-agnostic. All iCloud assumptions live in two places: `UbiquitySyncRoot` and `LedgerSync.startMetadataQuery()`.

## Design

### The only concept: a folder

```
Sync folder:  /Users/zheng/Sync/MyUsage     [Choose…]  [Reveal in Finder]
              ↳ File-system events + 30s polling · last change 12s ago
```

Implementation shape:

```swift
struct SyncFolderRoot: SyncRoot {
    let rootURL: URL?            // resolved from a security-scoped bookmark
    var isAvailable: Bool {
        guard let url = rootURL else { return false }
        // folder exists and we can list it. Writability is checked lazily on
        // first write; missing permission degrades to read-only peer mode.
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }
}
```

`UbiquitySyncRoot` and the iCloud-specific `NSMetadataQuery` wiring are deleted. `LocalSyncRoot` stays for tests — same shape.

### Default path selection (first-run)

On the first launch after installing this version, if no bookmark exists yet:

1. If `~/Library/Mobile Documents/com~apple~CloudDocs/MyUsage/devices/` exists and is non-empty → pre-fill the bookmark to that folder. Existing spec-12 users keep working with zero interaction.
2. Else if `ubiquityIdentityToken != nil` → suggest `~/Library/Mobile Documents/com~apple~CloudDocs/MyUsage` in the picker (user still confirms).
3. Else → suggest `~/Documents/MyUsage`.

The user can always re-pick via `Choose…`. The suggestion is a default, not a requirement.

### Change detection (one code path)

```
DispatchSource.makeFileSystemObjectSource
  path: <root>/devices/
  mask:  .write | .extend | .delete | .rename | .link
       → debounce 500ms → LedgerReader.importAllPeers()

+ Timer every 30s → LedgerReader.importAllPeers()     (belt-and-suspenders)
+ NSWorkspace.didWakeNotification → reattach + force refresh
+ Manual Refresh button in Settings → Devices
```

Rationale for ditching `NSMetadataQuery`:

- It only works under `NSMetadataQueryUbiquitousDocumentsScope` — useless for Syncthing / NAS / generic paths.
- For our files (small JSONL + manifest) we don't need evicted-item awareness; they'll be materialized on disk by the sync client before we care.
- `DispatchSource` is a kernel event, strictly cheaper on battery than the metadata indexer.
- Having one implementation across transports is worth more than a marginal iCloud-only optimization.

### Availability + resilience

| Condition | Behavior |
|---|---|
| Bookmark resolves, folder readable | Everything normal. |
| Bookmark resolves, folder missing (unmounted volume, deleted) | `isAvailable = false`. Settings caption: "Sync folder unavailable." Local SQLite still drives the UI. Retry on every refresh + on wake. |
| Bookmark fails to resolve (deleted, OS lost the reference) | Caption: "Sync folder not found. Pick it again." Writer is a no-op. Reader is a no-op. |
| Folder read-only | First write fails → log at `.error`, mark `syncStatus = .readOnly`. Aggregation still works for incoming peer data; we just can't publish our own. |
| Folder is inside iCloud Drive and iCloud is offline | iCloud handles it — we just see unchanged bytes. No special case. |
| Two Macs pick different folders | Silent no-op: they simply don't see each other. Documented; not an error. |

### Migration

- **Spec 12 iCloud users**: auto-detected by the first-run logic above. No prompt, no data loss. Their existing `devices/<uuid>/` folder keeps being the sync folder.
- **Users who want to switch** (e.g., iCloud → Syncthing): change `Sync folder` to the new path. Local SQLite is untouched (it's the source of truth). A fresh `devices/<selfID>/ledger.jsonl` is written into the new folder on the next refresh. The old iCloud folder is left alone — user can delete it manually.
- **No in-app "move files" button** for v1. Power users can `rsync -a old/ new/` themselves.

## Data model impact

None. The ledger SQLite schema, `LedgerEntry`, JSONL wire format, and `manifest.json` are all unchanged. Only where the files physically live changes.

New `UserDefaults` keys:

| Key | Type | Notes |
|---|---|---|
| `MyUsage.syncFolderBookmark` | `Data?` | Security-scoped bookmark for the picked URL. |
| `MyUsage.syncFolderPathHint` | `String?` | Human-readable path for Settings when the bookmark cannot resolve (e.g., volume offline). |
| `MyUsage.syncPollInterval` | `Int` (seconds) | Hidden; `defaults write` only. Default 30, min 5, 0 disables the poll. |

Removed: any `syncTransport` enum / key from the earlier draft of spec 12a (the two-transport version). We never shipped that implementation — this spec supersedes that draft.

## UI

Settings → **General** (not Devices — Devices stays about who's syncing, not how):

```
Sync folder
  /Users/zheng/Sync/MyUsage                          [Choose…]
  ↳ File-system events + 30s polling · last change 12s ago
  ↳ Reveal in Finder
```

States:

- `—` + `[Choose…]` when no bookmark yet (fresh install, not upgraded from spec 12).
- `<path>` + green dot when folder reachable and at least one peer write has happened in the last 24h.
- `<path>` + yellow dot + "Unavailable" when the bookmark resolves but the folder is gone right now.
- `<path>` + red dot + "Not found. Pick it again." when the bookmark itself is broken.

Help tooltip: one line — *"MyUsage writes one JSONL file per Mac into this folder. Use iCloud Drive, Syncthing, Dropbox, or any other sync tool to keep the folder consistent across your Macs."* Link to docs for anyone who wants the long version.

Settings → **Devices** stays as shipped in spec 12 — per-device Claude/Codex columns, Forget button, last-sync timestamp.

## Phased implementation

| Phase | Deliverable | Ships alone? |
|---|---|---|
| **12a.1** | `SyncFolderRoot` + bookmark helpers + first-run auto-migration from iCloud path. `LedgerSync` reads the bookmark and drops `NSMetadataQuery`. Default change detection = 30s timer only. | Yes — identical UX for spec-12 users, opens up any folder for new users via `defaults write`. |
| **12a.2** | `DispatchSource` folder watcher + 500ms debounce + wake-from-sleep reattach. | Yes — latency improves from ~30s to ~1s. |
| **12a.3** | Settings UI: `Choose…` picker, path display, status dot, "Reveal in Finder", help tooltip. | Yes — user-facing surface. |
| **12a.4** | Polish: read-only folder detection + status caption, sanitized log output, docs page linking recommended sync tools. | Yes — quality-of-life. |

Each phase leaves the spec-12 shipped features working.

## Unit tests

- `SyncFolderRoot.isAvailable` is `false` for missing paths, `true` for existing writable folders, `false` again after deletion.
- Bookmark round-trip: `create → store in UserDefaults → relaunch simulation → resolve → same URL`.
- First-run auto-migration: given a pre-existing iCloud `devices/<uuid>/` tree, first launch picks it as the sync folder without user interaction.
- `LedgerWriter` + `LedgerReader` driven by `SyncFolderRoot(url: tmp)` produce the same artifacts as `LocalSyncRoot` in spec 12 tests. (Existing tests re-run unchanged against the renamed root.)
- Folder-change detection: dropping a new peer JSONL into `devices/` triggers `LedgerSync.refresh()` within 1s (watcher) and within `pollInterval + 1s` (poll-only mode).
- Switch folder: pointing `SyncFolderRoot` at folder A, then folder B, writes a fresh `devices/<selfID>/` into B without corrupting A and without creating duplicate SQLite rows.
- Missing-folder recovery: mark folder missing → refresh is a no-op → restore folder → next refresh imports normally.

## Manual verification

- [ ] Upgrade from spec-12 build on an iCloud-synced Mac → `Sync folder` silently points at the old iCloud path. Aggregation continues. No prompts.
- [ ] Fresh install on a Mac with no iCloud → first-run opens Settings prompt with `~/Documents/MyUsage` suggested. Pick it; Devices tab shows only this Mac.
- [ ] Two Macs with **Syncthing** sharing `~/Sync/MyUsage`. Both set that as `Sync folder`. Within 60s, each Claude / Codex card shows `⊕ 2`, and the popover lists both devices.
- [ ] Same test with **Dropbox** instead of Syncthing.
- [ ] Same test with a mounted **SMB share**.
- [ ] While aggregating, unplug an external drive that hosts the folder → caption reads "Sync folder unavailable", no crash. Plug back in → recovers within one poll tick.
- [ ] Change `Sync folder` to a different path mid-session → previous peer data fades from aggregates (still in SQLite; can be forgotten via Settings → Devices), new `devices/<selfID>/` appears in the new folder.
- [ ] `defaults write com.myusage MyUsage.syncPollInterval -int 5` → dropped JSONL is picked up in ≤5s even without watcher events.
- [ ] Pick a read-only folder → red dot + "Sync folder unavailable (read-only)"; incoming peer JSONLs still render in aggregates.

## Acceptance

- Existing spec-12 iCloud users see **zero behavior change** — no new prompts, no regressed aggregation, no duplicate rows.
- A user on two Macs **without iCloud** can aggregate Claude + Codex monthly spend by pointing both at the same Syncthing / Dropbox / NAS folder, end-to-end within ~60s.
- No code path depends on `ubiquityIdentityToken`.
- No new entitlements. Ad-hoc signed builds keep working.
- The term "iCloud" appears in the codebase only as: (a) default-path suggestion logic, (b) user-facing docs as a recommended sync tool.

## Open decisions

1. **Auto-detect common sync tools?** Could look for `~/Syncthing`, `~/Dropbox`, iCloud Drive root, etc., when suggesting the default path. *Lean: no for v1 — just suggest `~/Documents/MyUsage` and let the user pick the right folder. One less "magic" to explain.*
2. **Poll interval default.** 30s vs 15s. 30s is gentler on battery; 15s feels more responsive for Syncthing users on LAN. *Lean: 30s, hidden `defaults` override for power users.*
3. **In-app "Move files" button** for transport switches. *Lean: defer. `rsync` is one command; doing it wrong once is recoverable because SQLite is authoritative.*
4. **Warn when folder is not actually synced** (e.g., user picks `~/Desktop`). *Lean: no heuristic — can't reliably detect sync status across tools, and false positives are worse than the current silence.*
5. **Rename the internal `SyncRoot` protocol to `SyncFolder`?** More honest naming. *Lean: yes, small rename in 12a.1.*

## Implementation notes

- **Security-scoped bookmark** is stored even though the app isn't sandboxed today. It's free forward-compat for a future Mac App Store or Developer ID-notarized build. Wrap each read/write in `startAccessingSecurityScopedResource` / `stopAccessing…`.
- **Wake-from-sleep**: observe `NSWorkspace.didWakeNotification`. Re-resolve bookmark (volume might have reappeared with a new inode) + trigger one `importAllPeers()`.
- **Log hygiene**: never log the full folder path at `.public`. Use `.private` on the URL and `.public` only on the last path component (`MyUsage`). Paths can contain real names.
- **`NSFileCoordinator`**: keep using it for reads and writes. iCloud Drive still benefits; Syncthing and Dropbox are no-ops for it; cost is negligible.
- **Remove old iCloud plumbing** in one commit so we don't straddle two implementations: delete `UbiquitySyncRoot`, delete `startMetadataQuery`, delete any `@Observable` state that was iCloud-specific.
- **Migration one-liner** in `LedgerSync.start()`:
  ```swift
  if bookmark == nil {
      if let legacy = legacyICloudFolderIfPopulated() {
          saveBookmark(for: legacy)
      }
  }
  ```
