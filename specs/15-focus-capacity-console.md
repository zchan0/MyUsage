# Feature 15 — Focus Capacity Console

## Goal

Make MyUsage's menu-bar popover faster to scan than a provider-card stack,
while preserving truthful source data and direct access to every provider.

## Behavior

- The desktop popover is 400pt wide and remains content-height driven.
- One enabled provider opens directly into its Deck detail page.
- Two or more providers open on Focus Overview with a flat provider rail.
- Focus selection is deterministic: reliable projected overshoot or >=75%
  usage first, then the soonest future reset, then highest reported usage.
- Focus retains sibling windows from the same provider; all other providers
  appear in a pressure-ordered watchlist.
- Provider detail uses side-by-side instruments for rolling windows.
- Estimated cost and history appear after capacity data.
- Codex reset credits show the authoritative available count and all reported
  non-expired available-credit expiry times.
- Reset-credit fetch failure does not fail the primary Codex usage refresh.
- Missing, malformed, or contradictory credit inventory is labeled
  `Unavailable`; zero is shown only when the endpoint reports zero.

## Manual Verification Checklist

- [x] 1-provider screenshot is 400pt wide, skips Overview/navigation, and
  shows Deck detail without clipping.
- [x] 2-provider screenshot is 400pt wide and shows Focus + one watch row.
- [x] 4-provider screenshot is 400pt wide, grows vertically, and shows three
  watch rows without overlap or truncated provider names.
- [x] Codex Deck shows reset-credit count, next expiry, and all mock expiry
  rows; no provider credit IDs are rendered.
- [x] Real Codex data renders a truthful `Unavailable` state when the endpoint
  does not return a trustworthy inventory.
- [x] Light appearance screenshots show legible hierarchy and separator
  contrast at Retina scale.
- [x] Single-provider and Focus popovers retain Refresh, Settings, About,
  Update, and Quit actions in the compact footer.
- [x] `swift test` passes all unit and Swift Testing suites.
- [x] `swift build -c release` succeeds.
