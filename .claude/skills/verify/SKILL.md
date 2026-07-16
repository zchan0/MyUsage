---
name: verify
description: Verify MyUsage UI/behavior changes by driving the real app headlessly and rendering the popover panel to a PNG. Use after changing any Views/, MenuBar/, or provider-facing code.
---

# Verifying MyUsage changes

The surface is a macOS menu bar app. Do NOT try to click the status
item via System Events / accessibility — dev builds may stall on a
Keychain dialog before the item exists. Use the in-process autopilot
instead (DEBUG builds only).

## Render the popover to a PNG

```bash
swift build
SCRATCH=$(mktemp -d)
MYUSAGE_AUTOPILOT=open:0 \
MYUSAGE_SNAPSHOT=$SCRATCH/panel.png \
MYUSAGE_NO_PROMPT=1 \
MYUSAGE_DEBUG_LOG=$SCRATCH/autopilot.log \
.build/debug/MyUsage > /dev/null 2>&1 &
APP_PID=$!
# Poll for completion (timeline: ~4s toggle + ~6s settle + snapshot):
for i in $(seq 1 30); do
  sleep 1
  grep -q "AUTOPILOT open:0 done" $SCRATCH/autopilot.log 2>/dev/null && break
done
kill $APP_PID
```

Then Read `$SCRATCH/panel.png`. Renders with the machine's live
provider data and current system appearance (light/dark follows the
OS — you don't get to pick).

## Gotchas

- `MYUSAGE_NO_PROMPT=1` is belt-and-braces; despite the non-.app
  prompt-suppression policy in ClaudeCredentialStore, a bare-binary
  launch has been observed to throw the macOS Keychain password
  dialog for "Claude Code-credentials" (blocks startup until
  dismissed — a policy regression worth checking if it recurs).
- The autopilot toggle occasionally doesn't fire (startup race);
  if the log stops at `setPanelFrame` lines with no `click`, just
  relaunch — second attempt has always worked.
- `open:N` opens status item N (merged mode → 0). `MYUSAGE_AUTOPILOT=1`
  instead runs the mode-switch walk (merged→separate→merged) with
  log breadcrumbs; no snapshot.
- NSLog is unreliable for bare binaries — always pass
  MYUSAGE_DEBUG_LOG and read the file. Don't use `swift run`
  (buffers child output); run `.build/debug/MyUsage` directly.
- There is no autopilot verb for switching popover tabs yet: the
  snapshot shows the Overview page only. Detail pages need a human
  eyeball (or extend the autopilot in MyUsageApp.swift).
