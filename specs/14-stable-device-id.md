# Spec 14 — Stable Device ID (postmortem + design)

## Incident

After reinstalling MyUsage on one of two registered Macs, a *third* folder
appeared under `<sync-root>/devices/`. Settings → Devices showed three rows
where there should have been two. The two "Cc's Mac" rows had identical
monthly totals, confirming they represented the same physical Mac under two
different IDs.

```
<sync>/devices/
  06D8D765-...   "Cc's Mac mini"   971.74   ← peer
  D8E87EC9-...   "Cc's Mac"        338.30   ← this Mac, pre-reinstall
  B8E5C72A-...   "Cc's Mac"        338.30   ← this Mac, post-reinstall
```

## Root cause

`DeviceIdentity.currentID()` treated `UserDefaults.standard["MyUsage.deviceID"]`
as the *sole source of truth* for device identity. On first launch it minted a
random `UUIDv4` and persisted it; every subsequent launch read it back.

Anything that drops the preferences plist — manual `defaults delete`, a clean
reinstall that wipes `~/Library/Preferences/<bundle-id>.plist`, sandbox
container reset, bundle-ID change — caused the next launch to mint a *new*
UUID. The old folder under `<sync-root>/devices/` was orphaned: nothing in
the writer's contract authorizes touching peer files, so the stale identity
lived on in the shared directory and inflated the device count forever (or
until the user manually invoked Settings → Devices → Forget + deleted the
remote folder).

The header comment in the original `DeviceIdentity.swift` acknowledged the
behavior ("Wiping `~/Library/Preferences` produces a new device ID") and
treated it as acceptable per spec 12. In practice it is not — a single
reinstall is enough to trigger it.

## Resolution

Identity is now **derived** from a stable hardware fingerprint and only
*cached* in `UserDefaults`.

```
IOPlatformUUID  →  SHA-256("MyUsage.v1|" + IOPlatformUUID)  →  first 16 bytes
                                                              → set v4 + variant bits
                                                              → format 8-4-4-4-12
                                                              → cache in UserDefaults
```

Properties:

- **Stable across reinstalls.** The same Mac always derives the same ID,
  whether the cache exists or not.
- **Privacy-preserving.** The raw `IOPlatformUUID` never leaves the process.
  Only the salted SHA-256 digest is written to disk or the sync folder.
- **Namespace-isolated.** The `"MyUsage.v1"` salt prevents collisions with
  any other app that derives values from the same hardware ID.
- **Format-compatible.** The output is a valid RFC 4122 UUIDv4 string, so
  the existing SQLite schema, JSONL layout, and folder structure need no
  changes. Foundation's `UUID(uuidString:)` round-trips it.
- **Fallback path.** When IOKit cannot return a platform UUID (very rare:
  some VMs, future API change), we mint a random UUIDv4 and log a warning
  via `Logger.ledger.error`. Such a machine reverts to the old behavior
  (new ID per reinstall), but the case is loud rather than silent.

## Code

- `MyUsage/Services/Ledger/DeviceIdentity.swift` — new derivation logic,
  IOKit reader, fallback warning.
- `MyUsageTests/DeviceIdentityTests.swift` — six tests covering: persistence,
  re-derivation after `UserDefaults` wipe, deterministic stable ID, distinct
  IDs for distinct hardware, valid RFC 4122 v4 string output, fallback.

## Migration

None for new installs (the bug only affects machines that have already
generated a random ID). For existing users who already have a non-derived
ID in `UserDefaults`, `currentID()` keeps returning the cached value — no
forced re-identification, no orphan churn. If a user wants to migrate to a
derived ID, the workaround is `defaults delete com.zchan0.MyUsage
MyUsage.deviceID` followed by a relaunch; the old folder under
`<sync>/devices/<old-uuid>/` then needs to be removed by hand or via
Settings → Devices → Forget.

## Follow-ups

### Done in v0.5.0

- **Forget peer now deletes the remote folder too.** Previously Forget only
  dropped local SQLite rows, so the peer reappeared on the next 30-second
  poll — effectively a no-op. `LedgerSync.forgetPeer` now also removes
  `<sync-root>/devices/<id>/`; the Devices tab fronts it with a
  confirmation dialog. If the peer is still active and publishes again,
  a fresh folder is created — that's the correct behavior, not a bug.
- **Multi-device integration test suite** (`LedgerSyncIntegrationTests`)
  pins the cross-device contract end-to-end, including a regression
  test that reinstalling on the same hardware does not create a
  duplicate device folder.

### Open

- **UI hint for orphans.** Devices tab could detect rows with the same
  `deviceName` as the current Mac but a different ID and offer a
  one-click "Merge into this Mac" that removes the row locally *and*
  deletes the remote folder. Useful only for users still carrying
  pre-v0.5.0 orphans; can wait until someone reports needing it.
