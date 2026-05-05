---
title: "No backend, locally-computed cost: how MyUsage aggregates AI usage across multiple Macs"
description: "Two engineering decisions behind a serverless multi-Mac AI usage tracker — BYO sync folder for cross-device aggregation, and locally-computed dollar costs because the providers don't tell you the dollars."
pubDate: 2026-05-05
---

I built [MyUsage](https://github.com/zchan0/MyUsage) because every AI coding tool's official UI lies to me. Not on purpose — they just only know about the device they're running on. If you have a laptop and a desktop and you run Claude Code on both, the Claude window on either Mac shows you "53% of your weekly limit remaining," but neither one knows what the other one burned through this morning. So you sit down on Friday afternoon, the laptop says you have headroom, you start a 90-minute pairing session, and 12 minutes in you hit the wall.

The interesting part of MyUsage isn't the menu bar widget or the SwiftUI views. It's the two design decisions underneath: **no backend** for cross-device aggregation, and **locally-computed cost** because most providers don't actually tell you the dollar amount.

This post is about both.

## Why no backend

The sane default for "I want N devices to share state" is a tiny server: each Mac POSTs its numbers to your-app.com, the popover GETs the totals. I considered it for about ten minutes and dropped it. Three reasons:

**Deployment friction.** A free macOS app shouldn't require a server I have to keep alive. Anything that fronts an API needs a domain, TLS, a host that doesn't go down, monitoring that someone is paid to look at. None of that exists for a side project, and the failure mode of "MyUsage is down because I forgot to renew a Vercel project" is worse than the problem MyUsage is trying to solve.

**Privacy posture.** Your AI usage stats are not catastrophic if leaked, but they're not nothing either — they reveal which models you use, how heavily, and (for Claude/Codex) the rough shape of your work patterns. The right default is "this data never leaves your devices and the sync transport you already trust." Adding a server I run breaks that without earning anything.

**Credentials trust.** MyUsage talks to four providers using each Mac's *own* OAuth credentials, sitting at `~/.claude/.credentials.json` and friends. To make a server work, those credentials would have to either flow through the server (terrifying) or stay on each Mac with the server only seeing aggregated numbers (in which case the server is doing very little work for the operational cost it imposes).

The architectural alternative is **bring your own sync folder**. The user already syncs *some* folder across their Macs — iCloud Drive, Syncthing, Dropbox, an NFS mount, anything. MyUsage writes per-device files into that folder. Each Mac reads everyone else's files and totals them. There is genuinely no MyUsage server anywhere in this picture.

## The folder layout

Inside whatever folder you point at, MyUsage builds this:

```
<your-sync-folder>/
└── devices/
    ├── 7F3CA5E1-9B2D-4F8A-A1C8-5E3D2B4F6A7C/
    │   ├── manifest.json
    │   └── ledger.jsonl
    ├── 4E91B8D7-2C3A-4D6F-8B5E-1A9C3F7E2D4B/
    │   ├── manifest.json
    │   └── ledger.jsonl
    └── ...
```

Each Mac owns exactly one subfolder under `devices/`, named by its derived ID. It writes only its own subfolder and reads every other subfolder. There's no merge conflict because there's never a write contest on the same file.

The two artifacts inside each device folder do different jobs:

- **`manifest.json`** is a small structured summary — device ID, display name, total row count, and per-month rollups. The popover reads this from every peer to render the aggregate cost row. The full ledger isn't needed for the running total, which means a freshly-installed Mac doesn't have to download every peer's full history just to show "$543 across all your Macs this month."
- **`ledger.jsonl`** is the raw daily-cost log, one JSON object per line. The local SQLite mirror at `~/Library/Application Support/MyUsage/ledger.db` is the source of truth on each Mac; the JSONL is the published-to-peers projection of it. JSONL was chosen over a JSON array because append-only files diff cleanly through every sync transport — most of them (iCloud, Syncthing) handle a single line append far better than a rewritten array.

Atomic write for the manifest (write-to-temp + rename), append-only for the JSONL. Either way a partial read mid-sync sees the previous version or a syntactically valid prefix; nothing half-written ends up in the popover.

## Device identity is the hard part

The naive approach — generate a random UUID on first launch, stash in `UserDefaults` — has a bug that took me a few weeks to notice in real use. If you reinstall the app (or `defaults delete com.zchan0.MyUsage`), `UserDefaults` is wiped, the next launch generates a *new* UUID, the sync folder grows a third subfolder for what's actually the same Mac, and the popover starts reporting your monthly cost as larger than it really is. Ghost devices.

The fix that landed in v0.5.0 derives device identity from a **hardware-rooted token, salted, hashed, and reshaped to a UUID**:

```swift
static func stableID(platformUUID: String) -> String {
    let digest = SHA256.hash(data: Data("\(salt)|\(platformUUID)".utf8))
    var bytes = Array(digest.prefix(16))
    // RFC 4122: version 4 in the high nibble of byte 6, variant 10 in the
    // top two bits of byte 8. Anything else is just a hex blob.
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80

    let hex = bytes.map { String(format: "%02X", $0) }.joined()
    return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-..."
}
```

Four design choices, each justified:

1. **`IOPlatformUUID` as the source.** It's a fixed-per-Mac string from IOKit; it survives reinstalls, doesn't change unless you wipe and re-pair hardware. We never write it to disk — only the salted hash.
2. **A salt, with a version (`MyUsage.v1`).** The salt's job is irreversibility: if a sync folder leaks, the device subfolder names are not enough to reconstruct anyone's `IOPlatformUUID`. The version suffix gives me room to migrate later (`MyUsage.v2`) without confusing existing clients about which scheme produced their cached ID.
3. **Reshape to RFC 4122 UUIDv4 form.** Setting bits in bytes 6 and 8 makes the output indistinguishable from a randomly-generated UUID to any consumer that validates UUID shape. This matters because the device ID flows into file paths, log lines, sometimes telemetry — anywhere a "raw 32-char hex" might trip a strict UUID validator.
4. **`UserDefaults` cache as an optimization, not source of truth.** The cached ID is read on launch for speed; if it's missing, we re-derive from hardware and re-populate. So preferences wipes can't cause ghost devices anymore — the same Mac always derives the same ID.

The raw `IOPlatformUUID` is read once into a stack-local string, hashed, and discarded. The discipline is "raw hardware identifiers never leave the process." That's not because of any specific threat — `IOPlatformUUID` isn't a secret in the cryptographic sense — it's because the salted-hash version is no harder to use and removes a class of mistakes.

[`DeviceIdentity.swift`](https://github.com/zchan0/MyUsage/blob/main/MyUsage/Services/Ledger/DeviceIdentity.swift) is 93 lines. Most of them are this derivation and its tests.

## Cost calculation: providers don't tell you the dollars

The naive expectation is that every AI provider's API has a "how much have I spent this month" endpoint. It does not work this way for the providers MyUsage cares about.

There are three flavours:

- **Claude Code, Codex** report **utilization percentages**, not dollars. Anthropic's `/api/oauth/usage` returns rows like `{"window": "weekly", "utilization_pct": 47.3}`. There's no USD field. To know the dollar cost you have to read the local session logs at `~/.claude/projects/**/*.jsonl`, count tokens by model, and multiply by published prices.
- **Cursor** reports **dollars** via its billing API, because it operates a hosted billing system on top of the underlying providers. MyUsage just receives the dollar amounts and stores them.
- **Antigravity** doesn't report dollars at all — it's a per-model quota system ("Sonnet: 47 / 200 calls used today"). MyUsage shows the quotas and never tries to attach a price.

So for two of the four providers, MyUsage has to do its own pricing. The contract is:

```swift
static func cost(usage: TokenUsage, model: String, catalog: PricingCatalog) -> Double {
    guard let price = catalog.pricing(for: model) else { return 0 }
    var total = 0.0
    total += Double(usage.input)  * price.input  / 1_000_000
    total += Double(usage.output) * price.output / 1_000_000
    if let cw = price.cacheWrite { total += Double(usage.cacheWrite) * cw / 1_000_000 }
    if let cr = price.cacheRead  { total += Double(usage.cacheRead)  * cr / 1_000_000 }
    if let ci = price.cachedInput {
        total += Double(usage.cachedInput) * ci / 1_000_000
    }
    return total
}
```

Standard per-million-token pricing, with three pricing tiers because both Anthropic and OpenAI charge differently for cached input — Anthropic distinguishes cache *write* from cache *read*, OpenAI calls it *cached input*. The pricing data lives in a bundled `pricing.json` and is loaded once at startup.

There are two failure modes the design has to absorb:

**New model release.** Anthropic releases Sonnet 4.6 on a Thursday. The model string in the JSONL becomes `claude-sonnet-4-6-20261001`. Our `pricing.json` has no entry for that exact string. Without help, every cost calculation involving the new model returns 0 until I ship a new app version with the updated catalog.

The mitigation is **longest-prefix matching** in [`PricingCatalog.pricing(for:)`](https://github.com/zchan0/MyUsage/blob/main/MyUsage/Services/PricingCatalog.swift):

```swift
func pricing(for modelName: String) -> ModelPricing? {
    let name = modelName.lowercased()
    if let exact = models[name] { return exact }
    for key in sortedKeys where name.hasPrefix(key) {
        return models[key]
    }
    return nil
}
```

The catalog has entries like `"claude-sonnet-4-5"`, sorted by descending length. A new model `claude-sonnet-4-5-20251201` matches the existing prefix immediately and uses the same pricing. New *families* still need a catalog edit, but minor model dates don't break the cost numbers.

**Mixed cost reconstruction.** Some Claude JSONL rows carry a server-provided `costUSD` (when Anthropic computed it server-side); most don't. The local pass walks every row, takes the server cost if present, otherwise computes from tokens. The two numbers feed into the same daily total.

The performance issue underneath all this is that re-parsing tens of megabytes of JSONL on every 60-second refresh tick is wasteful. The cache is keyed on `(currentMonth, max-source-file mtime)`: as long as no JSONL file's modification time has advanced since the last successful scan, the cached total is reused. When a new message gets written anywhere, the file system bumps that file's mtime, our stat pass picks it up, and the cache invalidates into a full rescan. Month rollover invalidates by the month-key check.

That's the cost computation pipeline end to end. Local input data, local pricing table, local cache, local output. The only network calls are to the providers' own APIs to discover *that* there are new logs to scan; the dollars themselves never round-trip.

## Wire-level details that matter

A few choices that the popover never surfaces but that matter for cross-device correctness:

**UTC day buckets.** All `day` keys in the ledger are computed in UTC via [`LedgerCalendar`](https://github.com/zchan0/MyUsage/blob/main/MyUsage/Services/Ledger/LedgerEntry.swift). This sounds boring until you have one Mac in San Francisco and one in Shenzhen and the local-day cutoffs disagree by 16 hours. With UTC, "Tuesday" means the same window on both Macs, and totaling them is straightforward addition. The popover shows the local clock for display — UTC is purely the storage format.

**Frozen costs.** A row's `costUSD` is computed at write time and never recomputed. If I edit `pricing.json` in a future release, past rows keep the prices that were authoritative when they were written. This is a deliberate non-goal: I do not want a release-time pricing edit to retroactively change someone's "this month so far" number, because then the number is no longer auditable against their actual provider bill.

**Schema versioning.** Every JSONL row carries a `v: 1` field, and [`LedgerEntry`](https://github.com/zchan0/MyUsage/blob/main/MyUsage/Services/Ledger/LedgerEntry.swift) has a parallel `LegacyCodingKeys` decoder that accepts the v0 snake_case shape. New shapes can land without breaking existing peers — readers silently drop unknown versions instead of crashing.

**Atomic writes for the manifest, append-only for the ledger.** A partial sync mid-write either sees the previous manifest (atomic guarantee) or a JSONL prefix that ends at a real newline (append guarantee). The popover never sees half-written state.

These all exist because I imagined the worst-case sync transport — Dropbox uploading a partial file while another Mac downloads it — and worked backward.

## Forgetting devices and edge cases

When you retire a Mac, its `devices/<old-id>/` subfolder will sit in the sync folder forever unless something explicitly removes it. Settings → Devices in the popover lists every peer with last-seen times; clicking **Forget** on a stale peer deletes that subfolder from the sync root. The deletion propagates through your sync transport; all your other Macs see the peer disappear within one sync cycle.

Forgetting is meant for *retired* devices. If you forget a peer that's still running, it'll just republish itself moments later — no permanent ban, by design.

Other edge cases the system handles without ceremony: iCloud's "evict to save space" feature (we use `NSFileCoordinator` so eviction is transparent), first launch on a fresh Mac (sees N peer manifests but contributes 0 until its first refresh completes), and sync transport offline (local writes still happen and publish when the transport comes back).

## What this isn't

Three things the BYO-folder design explicitly doesn't try to do:

1. **Real-time collaboration.** Sync latency is "as fast as your transport" — minutes for iCloud, near-real-time for Syncthing on LAN. This is a glance tool, not a coordination one.
2. **A team dashboard.** *Your* Macs, *your* folder. If you wanted a multi-user view with permissions, you'd need a server, and MyUsage doesn't have one.
3. **Historical reconstruction across devices.** If a Mac dies before its first sync, its local-only data is lost. Each device's *future* writes are sync'd; its *past* state isn't reconstructible from peers.

If those are deal-breakers for your case, you'd want a different architecture. But for the actual problem — "I have two or three Macs and want to know my real total" — this is the simplest design that works, and importantly, the only design where MyUsage doesn't need to operate a server.

The whole sync layer is about 300 lines of Swift across [`LedgerStore`](https://github.com/zchan0/MyUsage/blob/main/MyUsage/Services/Ledger/LedgerStore.swift), [`LedgerWriter`](https://github.com/zchan0/MyUsage/blob/main/MyUsage/Services/Ledger/LedgerWriter.swift), [`LedgerReader`](https://github.com/zchan0/MyUsage/blob/main/MyUsage/Services/Ledger/LedgerReader.swift), and [`DeviceIdentity`](https://github.com/zchan0/MyUsage/blob/main/MyUsage/Services/Ledger/DeviceIdentity.swift). Cost calculation is another 200 across [`CostCalculator`](https://github.com/zchan0/MyUsage/blob/main/MyUsage/Services/CostCalculator.swift), [`PricingCatalog`](https://github.com/zchan0/MyUsage/blob/main/MyUsage/Services/PricingCatalog.swift), and the cache. None of it is rocket science. The interesting part is that almost every line is in service of *not* needing a server.

If you want to try it yourself, MyUsage is on GitHub: [zchan0/MyUsage](https://github.com/zchan0/MyUsage). MIT licensed, macOS 14+, zero third-party dependencies.
