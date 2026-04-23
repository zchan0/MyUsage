# Spec 12a — Sync Transports (iCloud Drive + Custom Folder)

## Goal

Spec 12 shipped with a single sync transport: iCloud Drive at the public `com~apple~CloudDocs` path. That works, but forces users to:

- trust Apple's iCloud with their usage-cost data, and
- keep iCloud Drive enabled on every Mac they want to aggregate.

Some users already run **Syncthing**, **Dropbox**, **Resilio Sync**, **OneDrive**, or even a mounted NAS share, and would rather keep the ledger in a folder *they* control. This spec adds a second transport: **Custom Folder**, a user-picked directory that any file-sync tool can operate on.

The ledger data model, per-device single-writer rule, JSONL wire format, and SQLite schema from spec 12 stay unchanged. Only the transport layer (where files live + how we detect peer changes) is extended.

## Scope

### In scope

- User setting: choose between **iCloud Drive (default)** and **Custom Folder**.
- New `CustomFolderSyncRoot` implementation of the existing `SyncRoot` protocol.
- Change-detection fallback for non-iCloud paths (iCloud uses `NSMetadataQuery`; custom folders need a different mechanism).
- Graceful switchover: changing transport does not lose or duplicate local data.

### Non-goals

- **No Syncthing-specific integration.** We do not read Syncthing's config, we do not install or start any daemon. We only write to a folder; Syncthing (or anything else) is responsible for moving bytes between machines.
- **No built-in sync engine.** MyUsage is not a sync product.
- **No cloud storage provider accounts.** Dropbox / Drive / OneDrive only work if the user has their sync client already installed and the target folder is inside that client's synced root.
- **No per-provider transport.** One transport applies to the whole ledger.
- **No encryption at rest v1.** Data is already readable as JSONL in the user's own folder today — same threat model.

## Current state (after spec 12)

| Layer | Today |
|---|---|
| Sync root abstraction | `SyncRoot` protocol with `UbiquitySyncRoot` (prod) + `LocalSyncRoot` (tests) |
| Sync path | Hard-coded: `~/Library/Mobile Documents/com~apple~CloudDocs/MyUsage/devices/` |
| Change detection | `NSMetadataQuery` on `NSMetadataQueryUbiquitousDocumentsScope` |
| Availability gate | `FileManager.default.ubiquityIdentityToken != nil` |
| UI | No transport picker; Settings → Devices silently disables sync if iCloud is off |

`LedgerWriter` and `LedgerReader` already take a `SyncRoot` by dependency injection. Extending transports is therefore local to `SyncRoot` + `LedgerSync`'s watcher, plus a Settings picker.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Settings.syncTransport : .icloud | .customFolder             │
└──────────────────────────────────────────────────────────────┘
                │
                ▼
      ┌─────────────────────┐
      │  SyncRoot (protocol)│  (unchanged)
      └─────────┬───────────┘
                │
     ┌──────────┼──────────────────────┐
     ▼          ▼                      ▼
UbiquitySync  CustomFolderSync      LocalSync (tests)
 Root          Root
  │              │                     │
  ▼              ▼                     ▼
iCloud Drive   User-picked folder    tmp/
  (MyUsage/    (MyUsage/devices/)
   devices/)
  │              │
  ▼              ▼
NSMetadataQuery  DispatchSource file watcher
                + debounced refresh
                + polling fallback
```

Everything downstream of `SyncRoot` keeps working without change:

- `LedgerWriter` writes `devices/<selfID>/ledger.jsonl` + `manifest.json`
- `LedgerReader` imports peers' `ledger.jsonl` with byte-offset checkpoints
- Single-writer-per-device rule prevents cross-device file conflicts regardless of transport

## Settings UI

New row under **General** (not under Devices, because this governs *how* sync works, not *which* devices):

```
Sync
  ○ iCloud Drive                      (default)
  ● Custom folder                     ~/Sync/MyUsage  [Choose…]
  Change detection: file system events · polling every 30s
```

Wording rules:

- The row is `Sync`, not `Transport`. User-facing.
- When **iCloud Drive** is selected and `ubiquityIdentityToken` is nil, we show an inline caption: _"iCloud Drive is not signed in on this Mac."_ The radio stays selectable; we just don't sync until it recovers.
- When **Custom folder** is selected and the path is unreachable (unmounted NAS, unreadable permissions), the caption reads _"Folder unavailable. Check that it exists and is readable."_ — do not lose the stored path; user may be off Wi-Fi.
- **Choose…** opens `NSOpenPanel(canChooseDirectories: true, canChooseFiles: false, allowsMultipleSelection: false)`. We store the resulting URL as a security-scoped bookmark (forward-compat for a future sandboxed build; today's ad-hoc signed build does not require it, but resolving the bookmark works either way).

## Data model additions

### UserDefaults

| Key | Type | Notes |
|---|---|---|
| `MyUsage.syncTransport` | `String` | `"icloud"` (default) \| `"customFolder"` |
| `MyUsage.syncCustomFolderBookmark` | `Data?` | security-scoped bookmark for the picked URL |
| `MyUsage.syncCustomFolderPathHint` | `String?` | human-readable path, for Settings display when the bookmark cannot resolve (e.g. NAS offline) |

### No SQLite changes

The ledger DB, `LedgerEntry`, and `manifest.json` are unchanged. `deviceId` is still random per install; two different Macs on the same custom folder show up as two `deviceId`s just like under iCloud.

## Switching transport

Transport change is **not** a migration. Semantics:

- Local SQLite stays as-is — it's the source of truth.
- Old transport's `devices/<selfID>/*` files are left in place (user can delete them manually if they like).
- On the new transport, `LedgerWriter` writes our JSONL + manifest fresh from SQLite on the next successful refresh.
- Peers on the new transport are discovered in the usual way; peers on the old transport just stop appearing.

UI note: after switching, Settings → Devices may show an empty peer list for a few seconds until the new transport reports peer folders. We show `Last sync: just now` once the first peer is imported.

## Change detection

Two implementations, selected by `SyncRoot` identity, not by transport name — so tests keep using `LocalSyncRoot` with its own strategy without branching.

### iCloud Drive (unchanged)

`NSMetadataQuery` scoped to `NSMetadataQueryUbiquitousDocumentsScope`, predicate matching `MyUsage/devices/*/ledger.jsonl` and `manifest.json`. Notifications: `didFinishGathering`, `didUpdate`. Cheap, event-driven, battery-friendly.

### Custom Folder

`NSMetadataQuery` cannot watch non-ubiquitous paths, so we use a **layered fallback**:

1. **`DispatchSource.makeFileSystemObjectSource`** on the `devices/` folder (event mask `.write | .extend | .delete | .rename`). Most file-sync tools emit a real write when they drop a new peer folder or update a JSONL, so this covers the hot path.
2. **Debounce** the event stream to 500ms — sync clients often touch many files in quick succession.
3. **Polling fallback** every 30s, configurable via `MyUsage.syncCustomFolderPollInterval` (30s default; 5s minimum; 0 to disable). This exists because some sync clients use `rename` + atomic replace patterns that don't always fire `DISPATCH_VNODE_WRITE` on the containing directory. 30s matches the typical Claude/Codex refresh cadence so we don't burn battery.
4. **Manual refresh**: the Refresh button in Settings → Devices calls `LedgerSync.refresh()` regardless of watchers.

The watcher re-attaches itself on every transport change, on wake-from-sleep, and when the path first becomes available after being unreachable.

## Availability rules

| Transport | `isAvailable` true when |
|---|---|
| iCloud Drive | `FileManager.default.ubiquityIdentityToken != nil` (today's behavior) |
| Custom folder | bookmark resolves **and** folder is readable **and** we can create `devices/` inside it |

`LedgerWriter` / `LedgerReader` already no-op when `isAvailable == false`. No new error states are introduced.

## Error handling

| Condition | Behavior |
|---|---|
| Custom folder picked on Mac A, never created on Mac B | Mac B never sees Mac A — correct. No error. |
| Bookmark resolves but path is on an unmounted volume | `isAvailable == false`, caption shows "Folder unavailable." Local SQLite still works. |
| Permission error mid-write | Log once at `.error`, skip the JSONL append, surface "Sync paused" in Settings. Next successful attempt clears the flag. |
| User picks a parent of another app's folder | We only read/write under `devices/`. We never touch siblings. Picking `~/` is legal but discouraged; we don't validate semantics. |
| Sync client mid-flight partial file | Same tolerance as spec 12: readers drop corrupt trailing lines and retry from the last good byte. |

## Phased implementation

| Phase | Deliverable | Independently shippable? |
|---|---|---|
| **12a.1** | `CustomFolderSyncRoot` + `UserDefaults` keys + Settings picker UI. `LedgerSync` accepts the transport and re-mounts on change. **No watcher yet** — only manual refresh + next periodic tick see new data. | Yes — correct but laggy. |
| **12a.2** | `DispatchSource` watcher + 500ms debounce + polling fallback (30s). | Yes — makes custom folder feel native. |
| **12a.3** | Security-scoped bookmark resolution path, wake-from-sleep reattach, "Folder unavailable" caption. | Yes — polish. |

Each phase leaves the iCloud path untouched.

## Unit tests

- `CustomFolderSyncRoot.isAvailable` is `false` when the folder is missing, `true` when it exists, `false` again after it's deleted.
- `SyncTransport` round-trip through `UserDefaults`: setting `.customFolder(url:)` survives a relaunch simulation.
- `LedgerWriter` + `LedgerReader` driven by `CustomFolderSyncRoot(url: tmp)` produce the same JSONL layout as `LocalSyncRoot`.
- Transport switchover: two writers sharing one local SQLite, first pointed at folder A then folder B, produce independent `devices/<selfID>/` trees on each and neither corrupts SQLite.
- `DispatchSource` watcher: dropping a new peer JSONL into `devices/` triggers `LedgerSync.refresh()` within 1s.
- Polling fallback: even with watcher disabled, a 1s poll interval imports new peer rows within 2 ticks.
- Bookmark resolution: encode → store → relaunch (simulated) → decode resolves to the same URL.

## Manual verification

- [ ] On Mac A: set Sync to **Custom folder** and point at `~/Sync/MyUsage`. Confirm `devices/<uuid>/ledger.jsonl` appears after the next refresh.
- [ ] Install Syncthing on Mac A and Mac B, share `~/Sync/MyUsage` both ways. On Mac B, set Sync to **Custom folder** at the synced path. Within 60s, Mac B's Claude / Codex cards show `⊕ 2` and Mac A's rows appear in the popover.
- [ ] Repeat with Dropbox / iCloud Drive (as a folder, not ubiquity — rare but supported) / a mounted SMB share.
- [ ] While syncing, unmount the NAS share → Settings caption reads "Folder unavailable", no crash, local SQLite still drives the cards.
- [ ] Switch back to **iCloud Drive**: previous aggregates drop off, iCloud peers reappear, no duplicate rows in local SQLite.
- [ ] Pick a read-only folder → Settings shows "Folder unavailable", writer fails silently (once per session in logs).
- [ ] Set `MyUsage.syncCustomFolderPollInterval = 5` via `defaults write`, drop a new JSONL into the folder by hand → peer appears within ~5s.
- [ ] Disable iCloud Drive entirely, keep transport on **iCloud Drive** → caption reads "iCloud Drive is not signed in on this Mac."; Settings still lets user switch to **Custom folder** without restart.

## Acceptance

- A user on two Macs running Syncthing (no iCloud) can aggregate Claude + Codex monthly spend across both, with end-to-end propagation under 60s on LAN.
- Toggling between iCloud and Custom folder does not corrupt SQLite, does not duplicate rows, and does not delete files from either transport.
- With Custom folder selected and the path temporarily offline, the app continues to function in single-device mode and recovers automatically when the path comes back.

## Open decisions

1. **Poll interval default.** 30s (current lean) vs 15s. 30s is easier on battery but 15s feels more responsive for Syncthing users on LAN. _Lean: 30s, user-configurable via `defaults`._
2. **Expose polling toggle in UI?** Current plan: hidden `defaults` key only — avoids a settings row most users won't use. Reconsider if support volume says otherwise.
3. **Warn when user picks an iCloud-Drive folder as a custom folder?** It works, but defeats the point of the transport separation. _Lean: no warning, silent._
4. **Migration prompt on first launch after upgrade.** Should we nudge existing iCloud users to try Custom folder? _Lean: no — iCloud is the default and keeps working._

## Implementation notes

- **Protocol stays minimal.** Keep `SyncRoot` as today. Add a second protocol `SyncChangeObserver` only if the watcher wiring forces it; otherwise put the `DispatchSource` watcher inside `LedgerSync` keyed by transport identity.
- **Wake-from-sleep.** Re-resolve the bookmark on `NSWorkspace.didWakeNotification` — volumes may have reappeared with new `fileReference` IDs.
- **Security-scoped bookmark.** Wrap `startAccessingSecurityScopedResource()` around any read/write; pair with `stopAccessing…` on scope exit. Ad-hoc signed builds tolerate the missing sandbox; this is forward-compat only.
- **Sanitizing custom paths in logs.** Log folder paths with `.private` on the full URL and `.public` only on the last path component; the full path can leak `/Users/<name>/…`.
- **Default folder suggestion.** When the user clicks **Choose…** with no prior bookmark, pre-fill at `~/Documents/MyUsage` (not `~/Sync/…`, since that assumes Syncthing) — cheap, clearly user-owned.
