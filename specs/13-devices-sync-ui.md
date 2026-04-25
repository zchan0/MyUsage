# Spec 13 — Devices + Sync UI refresh

## Goal

Make the sync experience feel explicit and trustworthy: users should know which folder is syncing, which Macs have published data, when the last manual/automatic sync ran, and why a device row is or is not contributing Claude/Codex cost.

## Scope

- Move the user-facing Sync folder controls from General to the top of Devices.
- Keep General focused on app-wide behavior: refresh interval, menu bar icon, display toggles, launch at login.
- Redesign Devices as a two-part view:
  - Sync folder status and actions.
  - Device contribution table for the current month.
- Add a clear manual action: **Sync Now** publishes this Mac's ledger files and imports peers.
- Improve device identity visuals, including a Mac mini icon when the device name suggests one.
- Fix row alignment: icon, device name, ID, provider costs, total cost, and actions should align across rows.

## Proposed layout

```
Devices

Sync folder
  ~/Sync/MyUsage                                      [Choose...] [Reveal] [Sync Now]
  green dot  Available · file events + 30s polling · last change 12s ago

This month
  Device                         Claude       Codex       Total      Actions
  [macbook] Zheng's MacBook Pro   $12.34      $1.20      $13.54
            this Mac · A1B2C3D4
  [macmini] Mac mini              $8.00       -          $8.00      Forget
            peer · D4C3B2A1
```

## Device icons

Use SF Symbols where available:

- Self device: infer from current device name first, fallback to `laptopcomputer`.
- Names containing `Mac mini` / `mini`: `macmini`.
- Names containing `Mac Studio` / `Studio`: `macstudio`.
- Names containing `iMac`: `desktopcomputer`.
- Names containing `MacBook` / `Laptop`: `laptopcomputer`.
- Unknown peer fallback: `desktopcomputer`.

If a symbol is unavailable on the deployment target, fallback to `desktopcomputer`.

## Interaction details

- **Sync Now** calls `LedgerSync.syncNow()` and shows inline progress.
- **Choose...** keeps the same folder picker behavior, but stays in the Devices context.
- **Reveal** is icon-only or compact text depending on available width.
- **Forget** is peer-only (the "this Mac" row never shows it). As of v0.5.0 it deletes both the local rows + peer offset *and* the peer's `<sync-root>/devices/<id>/` folder, fronted by a confirmation dialog. If the peer is still active and publishes again, a fresh folder will be created — that's expected, not a bug. Local cleanup always runs even if remote cleanup fails (folder unreachable, permission denied); failures are logged. See spec 14.
- A peer with only `manifest.json` and no ledger rows can appear as "No current-month cost" once manifest-backed discovery is added. This is optional for the first pass.

## Visual requirements

- Use a grid/table-like layout with fixed numeric columns so provider totals align.
- Device icon frame is fixed width and vertically aligned with the device name block.
- Device name uses the row's primary baseline; the ID/status line is secondary.
- Avoid nested cards. The tab can use grouped sections or simple full-width bands.
- Text must truncate in the middle for long paths and at the tail for device names.

## Tests / verification

- Preview with at least:
  - This Mac with both Claude and Codex cost.
  - Mac mini peer with Claude-only cost.
  - Unknown peer with no cost.
  - Long sync path.
  - Unavailable sync folder.
- Manual verification:
  - Pick a sync folder from Devices and confirm `devices/<selfID>/ledger.jsonl` and `manifest.json` are written immediately.
  - Click Sync Now after deleting local sync files and confirm they are recreated.
  - Confirm Mac mini row uses the Mac mini symbol and all names/costs align.
