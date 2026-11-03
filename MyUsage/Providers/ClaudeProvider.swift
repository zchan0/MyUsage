import Foundation
import os

/// Claude quota comes exclusively from explicit, local statusline integration.
@Observable
@MainActor
final class ClaudeProvider: BuiltinUsageProvider {
    enum DataState: String {
        case notConnected, waiting, valid, stale, invalid
    }

    let kind = ProviderKind.claude
    var isAvailable: Bool { connected || receipt != nil }
    var isEnabled = true
    private(set) var isLoading = false
    private(set) var receipt: ClaudeStatuslineSnapshot?
    private var readIssue: String?
    private var connected = false
    private var monthlyCost: Double?
    private var costHistoryIssue: String?
    private var timeRevision = 0
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    private let store: ClaudeStatuslineStore
    let bridge: ClaudeStatuslineBridge
    private let logRoots: [URL]
    private let costCacheURL: URL
    private let now: @Sendable () -> Date
    private weak var ledger: LedgerSync?

    /// An age policy for local receipts, never a claim about server freshness.
    nonisolated static let staleAfter: TimeInterval = 15 * 60

    init(
        ledger: LedgerSync? = nil,
        directory: URL = ClaudeStatuslineStore.defaultDirectory,
        bridge: ClaudeStatuslineBridge? = nil,
        logRoots: [URL]? = nil,
        costCacheURL: URL = ClaudeCostCache.defaultFileURL,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.ledger = ledger
        self.store = ClaudeStatuslineStore(directory: directory)
        self.bridge = bridge ?? ClaudeStatuslineBridge(directory: directory)
        self.logRoots = logRoots ?? ClaudeLogParser.defaultRoots()
        self.costCacheURL = costCacheURL
        self.now = now
        readLocalQuota()
    }

    var dataState: DataState {
        _ = timeRevision
        if readIssue != nil { return .invalid }
        guard connected else { return .notConnected }
        guard let receipt else { return .waiting }
        let windows = [receipt.rateLimits.fiveHour, receipt.rateLimits.sevenDay].compactMap { $0 }
        guard !windows.isEmpty else { return .waiting }
        let age = now().timeIntervalSince1970 - receipt.receivedAt
        if age < -60 || age > Self.staleAfter || windows.contains(where: { $0.resetsAt <= now().timeIntervalSince1970 }) {
            return .stale
        }
        return .valid
    }

    var stateLabel: String {
        switch dataState {
        case .notConnected: "Statusline not connected"
        case .waiting: "Waiting for first quota data"
        case .valid: "Local statusline snapshot"
        case .stale: "Old statusline snapshot"
        case .invalid: "Statusline data unavailable"
        }
    }

    var sourceMessage: String {
        var message = stateLabel + ". "
        if let receipt {
            let date = Date(timeIntervalSince1970: receipt.receivedAt)
            message += "Received locally \(date.formatted(date: .abbreviated, time: .standard)). "
        }
        if let readIssue { message += readIssue + " " }
        switch dataState {
        case .notConnected: message += "Enable in Settings → Providers. "
        case .waiting: message += "Rate limits appear only for eligible subscriptions after the first API response. "
        case .stale: message += "No new quota data; expired windows are hidden. "
        case .valid, .invalid: break
        }
        message += "Server sample time is not provided. Refresh reads local files only."
        if let costHistoryIssue { message += " " + costHistoryIssue }
        return message
    }

    var error: String? {
        dataState == .valid ? nil : sourceMessage
    }

    /// Re-evaluate resets at read time so an expired window cannot remain a current limit.
    var snapshot: UsageSnapshot? {
        _ = timeRevision
        var result = receipt.map { Self.mapToSnapshot($0, now: now()) } ?? UsageSnapshot()
        result.monthlyEstimatedCost = monthlyCost
        return result
    }

    func refresh() async { await refresh(trigger: .automatic) }

    func refresh(trigger: UsageRefreshTrigger) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        readLocalQuota()
        let roots = logRoots
        let cache = costCacheURL
        let date = now()
        monthlyCost = await Task.detached(priority: .utility) {
            Self.computeMonthlyCostSync(roots: roots, now: date, cacheURL: cache)
        }.value
        await recordDailyCostsToLedger()
    }

    private func readLocalQuota() {
        defer { scheduleTimeTransition() }
        connected = bridge.isInstalled
        readIssue = bridge.hasInstallation && !connected
            ? "The configured statusline no longer matches MyUsage. Your configuration was preserved." : nil
        do {
            let read = try store.read()
            receipt = read.latest
            if read.hasInvalidFiles { readIssue = "Some local snapshots are damaged or unsupported." }
        } catch {
            receipt = nil
            readIssue = error.localizedDescription
        }
    }

    /// Expire UI/menu-bar values even with automatic polling disabled. This only advances local state.
    private func scheduleTimeTransition() {
        transitionTask?.cancel()
        guard let receipt else { return }
        let date = now().timeIntervalSince1970
        let boundaries = [receipt.rateLimits.fiveHour?.resetsAt, receipt.rateLimits.sevenDay?.resetsAt,
                          receipt.receivedAt + Self.staleAfter + 0.01, receipt.receivedAt - 60]
        guard let next = boundaries.compactMap({ $0 }).filter({ $0 > date }).min() else { return }
        transitionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(next - date)) } catch { return }
            guard let self else { return }
            self.timeRevision += 1
            self.scheduleTimeTransition()
        }
    }

    deinit { transitionTask?.cancel() }

    nonisolated static func mapToSnapshot(_ receipt: ClaudeStatuslineSnapshot, now: Date = .now) -> UsageSnapshot {
        func window(_ value: ClaudeStatuslineSnapshot.Window?, duration: TimeInterval) -> UsageWindow? {
            guard let value, value.isValid, value.resetsAt > now.timeIntervalSince1970 else { return nil }
            return UsageWindow(percentUsed: value.usedPercentage,
                               resetsAt: Date(timeIntervalSince1970: value.resetsAt), windowDuration: duration)
        }
        var snapshot = UsageSnapshot()
        snapshot.sessionUsage = window(receipt.rateLimits.fiveHour, duration: 5 * 3600)
        snapshot.weeklyUsage = window(receipt.rateLimits.sevenDay, duration: 7 * 86400)
        snapshot.lastRefreshed = Date(timeIntervalSince1970: receipt.receivedAt)
        // Statusline provides no account/profile information or per-model subscription caps.
        return snapshot
    }

    /// Scan `~/.claude/projects/**/*.jsonl` modified since the first of the
    /// current calendar month and compute estimated spend.
    ///
    /// Cache-gated: the per-file mtime walk is cheap; a full parse only
    /// happens when a JSONL has been appended to since the last scan or the
    /// calendar month has rolled over. See `specs/11-claude-data-sources.md`.
    nonisolated static func computeMonthlyCost() async -> Double {
        await Task.detached(priority: .utility) {
            Self.computeMonthlyCostSync(
                roots: ClaudeLogParser.defaultRoots(),
                now: .now,
                cacheURL: ClaudeCostCache.defaultFileURL
            )
        }.value
    }

    /// Testable synchronous core of `computeMonthlyCost`. Accepts injectable
    /// roots / now / cache URL so unit tests can use temp fixtures without
    /// touching the real `~/.claude/projects` or `~/Library/Caches`.
    nonisolated static func computeMonthlyCostSync(
        roots: [URL],
        now: Date,
        cacheURL: URL
    ) -> Double {
        let since = Date.startOfCurrentMonth(now: now)
        let month = ClaudeCostCache.monthKey(for: now)
        let catalog = PricingCatalog.shared

        // 1) Stat pass — cheap, no parse. `nil` means no in-scope files.
        let maxMtime = ClaudeLogParser.maxMtime(roots: roots, since: since)

        // 2) Cache hit? Require matching month, matching max mtime, AND a
        //    matching pricing fingerprint — a remote price update must not
        //    keep serving totals computed at superseded rates.
        if let cached = ClaudeCostCache.read(from: cacheURL),
           cached.month == month,
           cached.pricingFingerprint == catalog.fingerprint,
           let mtime = maxMtime,
           abs(cached.maxSourceMtime.timeIntervalSinceReferenceDate
               - mtime.timeIntervalSinceReferenceDate) < 1e-6 {
            return cached.totalUSD
        }

        // 3) Miss — full scan.
        let breakdown = ClaudeLogParser.scanBreakdown(roots: roots, since: since)
        let tokenCost = CostCalculator.totalCost(
            of: breakdown.tokensByModel,
            catalog: catalog
        )
        let total = breakdown.preComputedCost + tokenCost

        // 4) Persist (best-effort). Skip when no in-scope files, since we
        //    have nothing to pin the cache to for invalidation.
        if let mtime = maxMtime {
            let counts = breakdown.tokensByModel.mapValues(ClaudeCostCache.CachedTokenCounts.init)
            let payload = ClaudeCostCache.Payload(
                v: ClaudeCostCache.currentVersion,
                month: month,
                totalUSD: total,
                preComputedCost: breakdown.preComputedCost,
                tokensByModel: counts,
                maxSourceMtime: mtime,
                computedAt: now,
                pricingFingerprint: catalog.fingerprint
            )
            do {
                try ClaudeCostCache.write(payload, to: cacheURL)
            } catch {
                Logger.claude.error(
                    "Failed to write cost cache: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return total
    }

    // MARK: - Ledger

    private func recordDailyCostsToLedger() async {
        guard let ledger else { return }
        costHistoryIssue = nil
        let roots = logRoots
        let breakdown = await Task.detached(priority: .utility) {
            ClaudeLogParser.scanDailyBreakdown(
                roots: roots,
                since: Date.ledgerBackfillStart()
            )
        }.value
        guard !breakdown.total.isEmpty || !breakdown.tokensByDay.isEmpty else { return }
        do {
            // Reuse an existing daily storage key, without treating it as current account identity.
            // Moving the same full-day total to a new account bucket would double-count it.
            let existing = try ledger.store.entries(forDevice: ledger.selfDeviceID).filter { $0.provider == "claude" }
            let byDay = Dictionary(grouping: existing, by: \.day)
            let days = Set(breakdown.total.keys).union(breakdown.tokensByDay.keys)
            var daysByStorageKey: [String: Set<String>] = [:]
            for day in days {
                let prior = byDay[day] ?? []
                if prior.count > 1 || prior.first.map({ $0.sourceHash != day }) == true {
                    costHistoryIssue = "Ambiguous legacy cost days were preserved; current local cost estimates remain available."
                    continue
                }
                daysByStorageKey[prior.first?.accountId ?? "default", default: []].insert(day)
            }
            for (key, days) in daysByStorageKey {
                let models = breakdown.byModel.filter { days.contains($0.key) }
                let tokens = breakdown.tokensByDay.filter { days.contains($0.key) }
                await ledger.recordDailyCosts(
                    provider: .claude,
                    byDay: breakdown.total.filter { days.contains($0.key) },
                    perModelByDay: models.isEmpty ? nil : models,
                    tokensByDay: tokens.isEmpty ? nil : tokens,
                    accountID: key
                )
            }
        } catch {
            costHistoryIssue = "Could not read existing cost history; ledger writes were skipped to preserve it."
        }
    }

}
