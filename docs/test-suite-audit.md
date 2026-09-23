# Test suite audit — 2026-09-23

This review follows the v0.18.2 release. Its cleanup is recorded separately;
it is not part of the published tag. The review used the current production
call sites and assertions, rather than test age or a target test count.

## Removed: 19 tests

| Tests | Count | Evidence and retained coverage |
| --- | ---: | --- |
| Old `OverviewSummary` tile aggregation, deltas, series and next-reset selection | 15 | The current UI uses `FocusOverview` and `CapacityFocus`. Production callers use only `OverviewSummary.shortCountdown`; the other helpers were reachable only from these tests. Removed the unused helpers together with their tests, retaining the countdown implementation and test. |
| `AntigravityProviderTests.extractFlag` | 1 | Split a fixed string with the standard library and checked its PID. It never called `ProcessHelper` or an Antigravity parser, so it could not detect application parsing regressions. |
| `ClaudeDelegatedRefreshTests.binaryResolution` | 1 | Could return without any assertion when the CLI was absent. When present, it repeated the resolver's executable check, without verifying location precedence or PATH behavior. |
| `ProviderKindTests.displayProperties` | 1 | Nonempty names were already checked more strictly by `displayNames`. Despite its title, it did not assert anything about accent colors. |
| `PricingCatalogTests.exactMatch` | 1 | Only checked that a lookup was non-nil. The same fixture/model lookup is covered by `anthropicCacheFields`, which checks all parsed rates. |

## Repaired tests

- `LedgerParserTests`: three tests previously returned successfully without
  asserting anything when `PricingCatalog.shared` lacked a model. They now pass
  a fixed fixture catalog and assert literal expected costs. The server-cost
  tests also use that catalog, avoiding reads from a user's cached prices.
- The opt-in PTY test now requires an installed Claude CLI, a real launch attempt
  and a subsequent cooldown result. `cliUnavailable` can no longer masquerade
  as successful execution. It remains disabled in the ordinary unit-test run.

## Kept deliberately

- Legacy ledger spellings, schema migration and old cache-TTL encodings still
  protect reading users' existing history and sync data.
- `AccountIdentity` is still used by Claude/Codex refreshes and ledger writes.
- Gateway authorization, cancellation, failed-save preservation and refresh
  isolation tests protect active behavior, including the v0.18.2 fix.
- Fixed historical dates and model names in fixtures are not expiration dates
  for tests; the assertions must be judged against their explicit inputs.

## Verification

- Before cleanup: 458 declared tests; 457 passed and one opt-in PTY test skipped.
- After cleanup: 439 declared tests; 438 passed (156 XCTest + 282 Swift Testing),
  with the same one PTY test skipped. Zero failures.
- Relevant tests ran first, followed by `swift test` and the CI macOS
  `xcodebuild build -scheme MyUsage -destination 'platform=macOS'
  -skipPackagePluginValidation` check. Both completed successfully.
- `git diff --check` passed. The countdown helper body is unchanged; no UI
  layout or active calculation behavior was changed. The real CLI PTY flow and
  the released gateway's system authorization dialog were not exercised here.

Changed files: `MyUsage/Utilities/OverviewSummary.swift`,
`MyUsageTests/OverviewSummaryTests.swift`, `AntigravityProviderTests.swift`,
`ClaudeDelegatedRefreshTests.swift`, `LedgerParserTests.swift`,
`PricingCatalogTests.swift`, `ProviderKindTests.swift`, and this report. All test
filenames above are under `MyUsageTests/`.
