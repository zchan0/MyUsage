import Foundation
import os

/// Claude quota comes exclusively from explicit, local statusline integration.
@Observable
@MainActor
final class ClaudeProvider: BuiltinUsageProvider {
    typealias DataState = StatuslineDataState

    let kind = ProviderKind.claude
    var isAvailable: Bool { connected || receipt != nil }
    var isEnabled = true
    private(set) var isLoading = false
    private(set) var receipt: ClaudeStatuslineSnapshot?
    private(set) var localAccount: ClaudeLocalAccount?
    private var readIssue: String?
    private var connected = false
    private(set) var bridgeState: StatuslineBridgeState = .notInstalled
    private var localUsage: LocalUsageReport?
    private var timeRevision = 0
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    private let store: ClaudeStatuslineStore
    let bridge: ClaudeStatuslineBridge
    private let logRoots: [URL]
    private let accountURL: URL
    private let now: @Sendable () -> Date

    /// An age policy for local receipts, never a claim about server freshness.
    nonisolated static let staleAfter: TimeInterval = 15 * 60

    init(
        directory: URL = ClaudeStatuslineStore.defaultDirectory,
        bridge: ClaudeStatuslineBridge? = nil,
        logRoots: [URL]? = nil,
        accountURL: URL = ClaudeLocalAccount.defaultURL(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = ClaudeStatuslineStore(directory: directory)
        self.bridge = bridge ?? ClaudeStatuslineBridge(directory: directory)
        self.logRoots = logRoots ?? ClaudeLogParser.defaultRoots()
        self.accountURL = accountURL
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

    var statuslineIssue: String? { readIssue }

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
        return message
    }

    var error: String? {
        dataState == .valid ? nil : sourceMessage
    }

    /// Re-evaluate resets at read time so an expired window cannot remain a current limit.
    var snapshot: UsageSnapshot? {
        _ = timeRevision
        var result = receipt.map { Self.mapToSnapshot($0, now: now()) } ?? UsageSnapshot()
        result.localUsage = localUsage
        return result
    }

    func refresh() async { await refresh(trigger: .automatic) }

    func refresh(trigger: UsageRefreshTrigger) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        readLocalQuota()
        let roots = logRoots
        let date = now()
        localUsage = await Task.detached(priority: .utility) {
            ClaudeLogParser.scanLocalUsage(roots: roots, now: date)
        }.value
    }

    private func readLocalQuota() {
        defer { scheduleTimeTransition() }
        localAccount = ClaudeLocalAccount.read(from: accountURL)
        let state = bridge.integrationState
        bridgeState = state
        connected = (state == .installed || state == .appMoved)
        readIssue = state == .modifiedExternally
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
                          receipt.receivedAt + Self.staleAfter + 0.01, receipt.receivedAt - 60].compactMap { $0 }
        let grantExpirations = receipt.resetCredits?.compactMap(\.endsAt) ?? []
        guard let next = (boundaries + grantExpirations).filter({ $0 > date }).min() else { return }
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
        if let grants = receipt.resetCredits {
            let active = grants.filter { grant in
                grant.isValid && grant.resetsLeft > 0 && grant.usableNow != false
                    && (grant.endsAt.map { $0 > now.timeIntervalSince1970 } ?? true)
            }
            if !active.isEmpty {
                let sorted = active.sorted { left, right in
                    switch (left.endsAt, right.endsAt) {
                    case let (a?, b?) where a != b: return a < b
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: return left.id < right.id
                    }
                }
                snapshot.resetCredits = ResetCreditInventory(
                    reportedAvailableCount: active.reduce(0) { $0 + $1.resetsLeft },
                    availableCredits: sorted.map { grant in
                        ResetCredit(
                            id: grant.id,
                            label: grant.label,
                            count: grant.resetsLeft,
                            expiresAt: grant.endsAt.map { Date(timeIntervalSince1970: $0) }
                        )
                    },
                    fetchedAt: snapshot.lastRefreshed
                )
            }
        }
        // Statusline provides no account/profile information or per-model subscription caps.
        return snapshot
    }
}
