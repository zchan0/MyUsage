---
title: Multi-device sync
description: How MyUsage aggregates AI usage across multiple Macs through a user-chosen sync folder, with no MyUsage backend. Device identity, conflict handling, and forgetting peers.
order: 1
---

# Multi-device sync

The reason MyUsage exists in the first place is that the official UIs for Claude Code, Codex, Cursor, and Antigravity each only know about the device they're running on. If you use AI coding tools across two or three Macs (work laptop, personal desktop, and a backup machine, say), each one's "X% of your weekly limit remaining" is **wrong by some amount you can't see**. You hit a weekly cap on Friday afternoon because your laptop has been burning through tokens all morning while your desktop was telling you everything's fine.

MyUsage solves this by giving every Mac a small "diary" that it writes into a folder you already sync. The popover then reads every diary in that folder and shows the totals.

## The shape of it

Pick a folder that's already kept in sync across your Macs. Most people use **iCloud Drive's `Mobile Documents/com~apple~CloudDocs/...`** — it's free, requires zero setup, and is already there. Anything else that keeps a folder in sync works equally well: **Syncthing**, **Dropbox**, **Google Drive**, **OneDrive**, an **NFS** mount, even a `git pull` cron job if you're feeling weird.

Inside that folder, MyUsage builds a tree like this:

```
<your-sync-folder>/
└── devices/
    ├── 7f3c...8a/                 ← deviceID (32-char hex)
    │   ├── manifest.json
    │   └── ledger.jsonl
    ├── 4e91...3b/
    │   ├── manifest.json
    │   └── ledger.jsonl
    └── ...
```

Each Mac owns exactly one subfolder under `devices/`, named by its derived device ID. It writes its own snapshot in there and reads everyone else's. There is no central server, no MyUsage-operated cloud — the file system is the entire sync transport.

### `manifest.json`

A small structured summary written every refresh cycle:

```json
{
  "deviceId": "7f3c...8a",
  "deviceName": "Zheng's MacBook Air",
  "updatedAt": "2026-05-04T09:14:55Z",
  "rowCount": 4128,
  "lastEntryAt": "2026-05-04T09:13:12Z",
  "monthlyTotals": {
    "claude": { "2026-04": 112.34, "2026-05": 47.01 },
    "codex":  { "2026-04": 58.20,  "2026-05": 12.55 },
    "cursor": { "2026-04": 32.18,  "2026-05": 8.71  }
  }
}
```

The popover's monthly cost row reads the manifests from every peer and sums them. The full ledger isn't needed for the aggregate — that's why the manifest exists separately, so a freshly-installed Mac doesn't have to download every peer's full history just to show "this month: $X across all your Macs".

### `ledger.jsonl`

The raw daily-cost log, one JSON object per line:

```jsonl
{"deviceId":"7f3c...","provider":"claude","day":"2026-05-04","costUSD":4.23,"recordedAt":"..."}
{"deviceId":"7f3c...","provider":"codex", "day":"2026-05-04","costUSD":1.18,"recordedAt":"..."}
```

The local SQLite mirror (in `~/Library/Application Support/MyUsage/ledger.db`) is the source of truth on each Mac; the JSONL is the published-to-peers form. JSONL was chosen over JSON-array because append-only files diff much more cleanly through sync transports — most of them (iCloud, Syncthing) handle a one-line append far better than a rewritten JSON array.

## Device identity — why this is hard

The naive approach to device identity is "make up a UUID on first launch and stash it in `UserDefaults`." That's what MyUsage did for the first few releases. It has a problem: if the user reinstalls (drag the app to Trash, then reinstall from a fresh download), `UserDefaults` may or may not be cleared depending on how thorough the cleanup was, and the app generates a *new* UUID. The sync folder now thinks there's a third Mac that doesn't really exist.

The fix landed in v0.5.0: derive a **stable device ID from a hardware-rooted token**, and cache the derivation in `UserDefaults` (not the source of truth — just an optimization to avoid re-deriving on every launch). When the cache is missing, re-derive from hardware and re-populate. No more ghost devices.

### The derivation

```
deviceID = hex(SHA256(salt || IOPlatformUUID))[:32]
```

Where:

- `IOPlatformUUID` is read from IOKit's registry. It's a fixed-per-Mac string — survives reinstalls, doesn't change unless you wipe and re-pair hardware.
- `salt` is a constant baked into the binary, scoped to MyUsage. The salt's only job is to make sure you can't trivially reverse the deviceID back into the raw `IOPlatformUUID` if a sync folder leaks. With the salt in the picture, an attacker who finds a `devices/7f3c...8a/` folder learns nothing about your hardware.
- `SHA-256` because it's the boring, audited, fast hash everybody has.
- We take 32 hex characters (128 bits) — enough collision resistance for the realistic device count (you, your team, in a sync folder), short enough to be readable in the file path.

Why not just use `IOPlatformUUID` directly? Because you don't want a hardware identifier sitting in a folder that might get shared, backed up, screenshotted, or accidentally posted in an issue. The salted hash is irreversible — even if an adversary knows the salt (it's not a secret; it's a domain separator), they'd need to brute-force every possible `IOPlatformUUID` to learn yours. Realistically that's not worth anyone's time, but the discipline of "raw hardware IDs never leave the process" is the right default.

The raw `IOPlatformUUID` is read once per launch into a stack-local string, hashed, and discarded. The derived ID is cached in `UserDefaults` for fast access on subsequent launches.

## What gets synced — and what doesn't

MyUsage's sync folder contains only the artifacts above:

- **`manifest.json`** per device — small structured summary
- **`ledger.jsonl`** per device — daily cost log

What is **not** in the sync folder:

- **Auth tokens or credentials.** Each Mac reads its own `~/.claude/.credentials.json` or `~/.codex/auth.json`. These never leave the device that owns them.
- **Live usage windows** (5 h sessions, weekly windows). Those are read from each provider's API in real time, per-device. The sync folder is for the *history* (cost ledger), not the *current state* (live API responses).
- **Prompts, code, or any conversation content.** MyUsage doesn't see those — it only reads aggregate token / cost numbers from each provider's billing APIs.

So the worst outcome of a leaked sync folder is "an adversary can see how many dollars you spent on Claude per day for the last few months." Not great, but not catastrophic — and that's the threshold MyUsage was designed against.

## Conflict resolution

What happens when two Macs write to their respective folders within the same sync round?

Nothing tricky — they write to *different* subfolders (each Mac owns `devices/<its-own-id>/` and never touches anyone else's). The sync transport sees independent file changes and propagates them independently. There's no merge conflict because there's never a write contest on the same file.

Where the lack of locking does matter: when a single Mac writes its own `manifest.json` and `ledger.jsonl` rapidly. MyUsage uses **atomic writes** (write-to-temp + rename) for the manifest and **append-only** writes for the JSONL, so partial reads from a sync transport mid-write either see the previous version (atomic case) or a syntactically-valid prefix (JSONL case). No half-written state ends up in the popover.

## Forgetting a peer

When you retire a Mac (sell it, replace its hard drive, etc.), its `devices/<old-id>/` folder will sit in your sync folder forever unless something explicitly removes it. MyUsage's **Settings → Devices** tab lists every peer it sees, with last-seen times. Click **Forget** on a stale peer and MyUsage **deletes that peer's entire `devices/<id>/` subfolder** from the sync root. The deletion propagates through your sync transport; all your other Macs see the peer disappear within one sync cycle.

The peer being forgotten could itself be running and re-publishing. That's not a bug — if you forget it on Mac A while Mac B is still running, Mac B will republish itself moments later. The forget operation is meant for *retired* devices that aren't running; it's not a permanent ban.

## Edge cases

A few realities you might hit:

- **Empty popover on a freshly-installed Mac.** First launch reads the sync folder and finds N peer manifests but no local ledger yet. The aggregate row shows N peers' contributions; the local Mac contributes $0 until its first refresh cycle completes.
- **Sync transport offline.** If iCloud is unreachable, the app keeps running, just doesn't see new peer data until iCloud comes back. The local manifest is still updated locally; it'll publish when iCloud reconnects.
- **iCloud's "evict" feature.** macOS may evict files from a synced folder to save disk space. MyUsage uses `URLSession.startAccessingSecurityScopedResource` and `NSFileCoordinator` paths so iCloud will rehydrate evicted files transparently.
- **Different Macs, different time zones.** All `day` keys in the ledger are computed in UTC, so cross-time-zone aggregation works without surprise. The "today" the popover shows on each Mac follows that Mac's local clock for display purposes only.

## Trying it

The simplest setup: turn on iCloud Drive on every Mac you care about, then in **Settings → General → Sync folder**, click **Choose…** and pick the same folder on each Mac (e.g. `~/Library/Mobile Documents/com~apple~CloudDocs/MyUsage-sync`). Click refresh in the popover and within a sync cycle every Mac will see every other Mac's contribution.

If iCloud isn't your thing, **Syncthing** is the recommended alternative — it's peer-to-peer (no third-party cloud), free, and the folder semantics are identical from MyUsage's perspective. **Dropbox** and **Google Drive** also work, but they're a bit slower to propagate single-line JSONL appends.

## What this design isn't

It's worth being explicit about what multi-device sync **doesn't** try to do, because the BYO-folder design implicitly rules these out:

- **Real-time collaboration.** Sync latency is "as fast as your transport" — minutes for iCloud, near-real-time for Syncthing on LAN. Don't expect sub-second consistency.
- **A team dashboard.** This is for *your* Macs syncing to *your* folder. If you wanted a multi-user team view, you'd need a server, and MyUsage doesn't have one.
- **Historical reconstruction across devices.** If a device dies before its first sync, that data is lost. Each device's *future* writes are sync'd; its *past local-only* state isn't reconstructible from peers.

If those constraints are deal-breakers for your use case, you'd want a different architecture — but for the "I have 2-3 Macs and want to know my real total" use case, this is the simplest thing that works, and importantly, the only design where MyUsage doesn't need to operate a server.
