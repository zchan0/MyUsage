import Foundation
import os

// MARK: - Antigravity Data Models

/// Antigravity RetrieveUserQuotaSummary response (Antigravity 2.0+ / grouped 5h & 7d quotas).
/// Accepts both direct Connect-RPC JSON (`{ "groups": [...] }` / `{ "quotaGroups": [...] }`)
/// and Cloud Code envelope JSON (`{ "response": { "groups": [...] } }`).
struct AntigravityQuotaSummaryResponse: Codable, Sendable {
    let groups: [AntigravityQuotaGroup]?
    let quotaGroups: [AntigravityQuotaGroup]?
    let response: AntigravityQuotaSummaryEnvelope?
    let quotaSummary: AntigravityQuotaSummaryEnvelope?

    var resolvedGroups: [AntigravityQuotaGroup] {
        if let groups, !groups.isEmpty { return groups }
        if let quotaGroups, !quotaGroups.isEmpty { return quotaGroups }
        if let groups = response?.groups, !groups.isEmpty { return groups }
        if let quotaGroups = response?.quotaGroups, !quotaGroups.isEmpty { return quotaGroups }
        if let groups = quotaSummary?.groups, !groups.isEmpty { return groups }
        if let quotaGroups = quotaSummary?.quotaGroups, !quotaGroups.isEmpty { return quotaGroups }
        return []
    }
}

struct AntigravityQuotaSummaryEnvelope: Codable, Sendable {
    let groups: [AntigravityQuotaGroup]?
    let quotaGroups: [AntigravityQuotaGroup]?
}

struct AntigravityQuotaGroup: Codable, Sendable {
    let displayName: String?
    let name: String?
    let groupName: String?
    let label: String?
    let buckets: [AntigravityQuotaBucket]?
    let quotaBuckets: [AntigravityQuotaBucket]?
    let windows: [AntigravityQuotaBucket]?

    init(
        displayName: String? = nil,
        name: String? = nil,
        groupName: String? = nil,
        label: String? = nil,
        buckets: [AntigravityQuotaBucket]? = nil,
        quotaBuckets: [AntigravityQuotaBucket]? = nil,
        windows: [AntigravityQuotaBucket]? = nil
    ) {
        self.displayName = displayName
        self.name = name
        self.groupName = groupName
        self.label = label
        self.buckets = buckets
        self.quotaBuckets = quotaBuckets
        self.windows = windows
    }

    var resolvedName: String? {
        [displayName, groupName, label, name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var resolvedBuckets: [AntigravityQuotaBucket] {
        buckets ?? quotaBuckets ?? windows ?? []
    }
}

struct AntigravityQuotaBucket: Codable, Sendable {
    let bucketId: String?
    let id: String?
    let displayName: String?
    let label: String?
    let name: String?
    let window: String?
    let windowLabel: String?
    let cadence: String?
    let windowDuration: String?
    let duration: String?
    let remainingFraction: Double?
    let remaining: Double?
    let usedFraction: Double?
    let remainingPercentage: Double?
    let usedPercentage: Double?
    let resetTime: String?
    let resetsAt: String?
    let disabled: Bool?

    init(
        bucketId: String? = nil,
        id: String? = nil,
        displayName: String? = nil,
        label: String? = nil,
        name: String? = nil,
        window: String? = nil,
        windowLabel: String? = nil,
        cadence: String? = nil,
        windowDuration: String? = nil,
        duration: String? = nil,
        remainingFraction: Double? = nil,
        remaining: Double? = nil,
        usedFraction: Double? = nil,
        remainingPercentage: Double? = nil,
        usedPercentage: Double? = nil,
        resetTime: String? = nil,
        resetsAt: String? = nil,
        disabled: Bool? = nil
    ) {
        self.bucketId = bucketId
        self.id = id
        self.displayName = displayName
        self.label = label
        self.name = name
        self.window = window
        self.windowLabel = windowLabel
        self.cadence = cadence
        self.windowDuration = windowDuration
        self.duration = duration
        self.remainingFraction = remainingFraction
        self.remaining = remaining
        self.usedFraction = usedFraction
        self.remainingPercentage = remainingPercentage
        self.usedPercentage = usedPercentage
        self.resetTime = resetTime
        self.resetsAt = resetsAt
        self.disabled = disabled
    }

    var resolvedBucketId: String? {
        [bucketId, id]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var resolvedDisplayName: String? {
        [displayName, label, name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var resolvedResetTime: String? { resetTime ?? resetsAt }

    /// Remaining fraction in 0.0...1.0.
    /// Proto3 JSON omits 0.0 for default double fields; when `resetTime` is present
    /// on an enabled bucket without an explicit fraction, treat it as 0.0 (100% used).
    var resolvedRemainingFraction: Double? {
        if let value = remainingFraction ?? remaining {
            return max(0, min(1, value))
        }
        if let used = usedFraction {
            return max(0, min(1, 1 - used))
        }
        if let pct = remainingPercentage {
            return max(0, min(1, pct / 100))
        }
        if let pct = usedPercentage {
            return max(0, min(1, 1 - pct / 100))
        }
        if resolvedResetTime != nil, disabled != true {
            return 0
        }
        return nil
    }
}

/// Antigravity GetUserStatus response.
struct AntigravityUserStatusResponse: Codable, Sendable {
    let userStatus: AntigravityUserStatus?
}

struct AntigravityUserStatus: Codable, Sendable {
    let planStatus: AntigravityPlanStatus?
    let userTier: AntigravityUserTier?
    let cascadeModelConfigData: AntigravityCascadeData?
    let quotaGroups: [AntigravityQuotaGroup]?
    let groups: [AntigravityQuotaGroup]?
    let accountEmail: String?
    let email: String?

    init(
        planStatus: AntigravityPlanStatus? = nil,
        userTier: AntigravityUserTier? = nil,
        cascadeModelConfigData: AntigravityCascadeData? = nil,
        quotaGroups: [AntigravityQuotaGroup]? = nil,
        groups: [AntigravityQuotaGroup]? = nil,
        accountEmail: String? = nil,
        email: String? = nil
    ) {
        self.planStatus = planStatus
        self.userTier = userTier
        self.cascadeModelConfigData = cascadeModelConfigData
        self.quotaGroups = quotaGroups
        self.groups = groups
        self.accountEmail = accountEmail
        self.email = email
    }

    var resolvedEmail: String? {
        [accountEmail, email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var resolvedPlanName: String? {
        [userTier?.name, planStatus?.planInfo?.planName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var resolvedQuotaGroups: [AntigravityQuotaGroup] {
        if let quotaGroups, !quotaGroups.isEmpty { return quotaGroups }
        if let groups, !groups.isEmpty { return groups }
        return []
    }
}

struct AntigravityUserTier: Codable, Sendable {
    let id: String?
    let name: String?

    init(id: String? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

struct AntigravityPlanStatus: Codable, Sendable {
    let planInfo: AntigravityPlanInfo?
}

struct AntigravityPlanInfo: Codable, Sendable {
    let planName: String?
}

struct AntigravityCascadeData: Codable, Sendable {
    let clientModelConfigs: [AntigravityModelConfig]?
}

struct AntigravityModelConfig: Codable, Sendable {
    let label: String?
    let quotaInfo: AntigravityQuotaInfo?
}

struct AntigravityQuotaInfo: Codable, Sendable {
    let remainingFraction: Double?
    let resetTime: String?
}

/// Antigravity GetCommandModelConfigs fallback response.
struct AntigravityModelConfigsResponse: Codable, Sendable {
    let clientModelConfigs: [AntigravityModelConfig]?
}

// MARK: - Antigravity Provider

/// Antigravity usage provider — discovers the local language server process
/// spawned by Antigravity 2.0, Antigravity IDE, or the `agy` CLI, and supports
/// an opt-in local statusline fallback from Antigravity CLI (`agy`).
///
/// Primary live quota source is `RetrieveUserQuotaSummary` (grouped 5h / 7d rolling
/// buckets), enriched with account identity & tier from `GetUserStatus`, with
/// automatic fallback to legacy `GetUserStatus.clientModelConfigs` and
/// `GetCommandModelConfigs`. When live process RPC is unavailable (for example,
/// Antigravity 2.34+ hardened stdin bridge tokens or CLI-only sessions), MyUsage
/// reads private local statusline snapshots written by `--antigravity-statusline`.
@Observable
@MainActor
final class AntigravityProvider: BuiltinUsageProvider {
    typealias DataState = StatuslineDataState

    enum QuotaSource: String, Sendable, Equatable {
        case none
        case liveProcess
        case statusline
    }

    let kind = ProviderKind.antigravity
    var isEnabled = true
    private(set) var isLoading = false

    let bridge: AntigravityStatuslineBridge
    private let store: AntigravityStatuslineStore

    /// An age policy for local statusline receipts, never a claim about server freshness.
    nonisolated static let staleAfter: TimeInterval = 15 * 60

    // MARK: - Constants

    private static let retrieveQuotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let getUserStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let getModelConfigsPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"
    private static let getUnleashDataPath = "/exa.language_server_pb.LanguageServerService/GetUnleashData"

    private static let emptyBody = Data("{}".utf8)

    private static let requestBody: Data = {
        let payload: [String: Any] = [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en"
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }()

    // MARK: - State

    private var connectedPid: Int?
    private var connectPort: Int?
    private var connectScheme: String?
    private var csrfToken: String?
    private var liveSnapshot: UsageSnapshot?
    private var liveError: String?
    private var runningTokenlessProcess: AntigravityProcessInfo?
    private var lastRefreshDate: Date?
    private var hasLiveDetection = false
    private(set) var statuslineReceipt: AntigravityStatuslineSnapshot?
    private var statuslineConnected = false
    private(set) var statuslineBridgeState: StatuslineBridgeState = .notInstalled
    private var statuslineReadIssue: String?
    private var timeRevision = 0
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    private var localUsage: LocalUsageReport?
    private let logRoots: [URL]
    private let now: @Sendable () -> Date
    private let processFinder: @Sendable () async -> [AntigravityProcessInfo]
    private let hasLocalInstallation: @Sendable () -> Bool

    // MARK: - Constants (paths)

    private nonisolated static let installationPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.gemini/antigravity",
            "\(home)/.gemini/antigravity-cli",
            "\(home)/Library/Application Support/Antigravity/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Antigravity",
            "/Applications/Antigravity.app",
            "\(home)/Applications/Antigravity.app",
            "\(home)/Library/Application Support/Windsurf/User/globalStorage/state.vscdb",
        ]
    }()

    /// Resolved path of any detected Antigravity installation or state directory.
    private nonisolated static var detectedInstallationPath: String? {
        installationPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Init

    init(
        directory: URL = AntigravityStatuslineStore.defaultDirectory,
        bridge: AntigravityStatuslineBridge? = nil,
        logRoots: [URL]? = nil,
        now: @escaping @Sendable () -> Date = { .now },
        processFinder: (@Sendable () async -> [AntigravityProcessInfo])? = nil,
        hasLocalInstallation: (@Sendable () -> Bool)? = nil
    ) {
        self.store = AntigravityStatuslineStore(directory: directory)
        self.bridge = bridge ?? AntigravityStatuslineBridge(directory: directory)
        self.logRoots = logRoots ?? AntigravityLogParser.defaultRoots()
        self.now = now
        self.processFinder = processFinder ?? { await ProcessHelper.findAntigravityProcesses() }
        self.hasLocalInstallation = hasLocalInstallation ?? { Self.detectedInstallationPath != nil }
        detectAvailability()
        readLocalStatuslineQuota()
    }

    deinit { transitionTask?.cancel() }

    // MARK: - Derived State

    var isAvailable: Bool {
        hasLiveDetection
            || statuslineConnected
            || statuslineReceipt != nil
            || statuslineReadIssue != nil
            || localUsage != nil
    }

    var statuslineDataState: StatuslineDataState {
        _ = timeRevision
        if statuslineReadIssue != nil { return .invalid }
        guard statuslineConnected else { return .notConnected }
        guard let receipt = statuslineReceipt else { return .waiting }
        guard !receipt.quotas.isEmpty else { return .waiting }
        let current = now().timeIntervalSince1970
        let age = current - receipt.receivedAt
        if age < -60 || age > Self.staleAfter
            || receipt.quotas.contains(where: { ($0.resetsAt ?? .infinity) <= current }) {
            return .stale
        }
        return .valid
    }

    var quotaSource: QuotaSource {
        if liveSnapshot != nil { return .liveProcess }
        if statuslineConnected || statuslineReceipt != nil || statuslineReadIssue != nil {
            return .statusline
        }
        return .none
    }

    var isNotificationEligible: Bool {
        guard isEnabled else { return false }
        switch quotaSource {
        case .liveProcess:
            return liveError == nil && !(liveSnapshot?.modelQuotas.isEmpty ?? true)
        case .statusline:
            return statuslineDataState == .valid
        case .none:
            return false
        }
    }

    var statuslineIssue: String? { statuslineReadIssue }

    var statuslineStateLabel: String {
        switch statuslineDataState {
        case .notConnected: "Statusline not connected"
        case .waiting: "Waiting for first quota data"
        case .valid: "Local statusline snapshot"
        case .stale: "Old statusline snapshot"
        case .invalid: "Statusline data unavailable"
        }
    }

    var statuslineSourceMessage: String {
        var message = statuslineStateLabel + ". "
        if let receipt = statuslineReceipt {
            let date = Date(timeIntervalSince1970: receipt.receivedAt)
            message += "Received locally \(date.formatted(date: .abbreviated, time: .standard)). "
        }
        if let statuslineReadIssue { message += statuslineReadIssue + " " }
        switch statuslineDataState {
        case .notConnected:
            message += "Enable in Settings → Providers to read quota from Antigravity CLI (agy). "
        case .waiting:
            message += "Quota appears after an Antigravity CLI (agy) statusLine update reports quota buckets. "
        case .stale:
            message += "No new quota data; expired buckets are hidden. "
        case .valid, .invalid:
            break
        }
        message += "Server sample time is not provided. Statusline refresh reads local files only."
        return message
    }

    var error: String? {
        switch quotaSource {
        case .liveProcess:
            return liveError
        case .statusline:
            return statuslineDataState == .valid ? nil : statuslineSourceMessage
        case .none:
            return liveError
        }
    }

    /// Re-evaluate statusline bucket resets at read time so expired buckets cannot remain current limits.
    var snapshot: UsageSnapshot? {
        _ = timeRevision
        switch quotaSource {
        case .liveProcess:
            guard var result = liveSnapshot else { return nil }
            result.localUsage = localUsage
            return result
        case .statusline:
            var result = statuslineReceipt.map { Self.mapStatuslineToSnapshot($0, now: now()) } ?? UsageSnapshot()
            if result.planName == nil, let version = runningTokenlessProcess?.ideVersion {
                result.planName = "Antigravity \(version)"
            }
            result.localUsage = localUsage
            return result
        case .none:
            if let localUsage {
                var result = UsageSnapshot()
                result.planName = runningTokenlessProcess?.ideVersion.map { "Antigravity \($0)" }
                result.lastRefreshed = lastRefreshDate ?? now()
                result.localUsage = localUsage
                return result
            }
            if let process = runningTokenlessProcess {
                var result = UsageSnapshot()
                result.planName = process.ideVersion.map { "Antigravity \($0)" }
                result.lastRefreshed = lastRefreshDate ?? now()
                return result
            }
            return nil
        }
    }

    // MARK: - UsageProvider

    func refresh() async { await refresh(trigger: .automatic) }

    func refresh(trigger: UsageRefreshTrigger) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        readLocalStatuslineQuota()

        let roots = logRoots
        let date = now()
        lastRefreshDate = date
        async let localReportTask = Task.detached(priority: .utility) {
            AntigravityLogParser.scanLocalUsage(roots: roots, now: date)
        }.value

        // 1. Discover running language_server process(es)
        DebugLog.info("[1/4] Finding Antigravity process…")
        let processes = await processFinder()
        let scannedLocalUsage = await localReportTask
        let activeLocalUsage = scannedLocalUsage.summary30d.totalTokens > 0 ? scannedLocalUsage : nil
        localUsage = activeLocalUsage

        guard !processes.isEmpty else {
            clearConnection()
            liveSnapshot = nil
            runningTokenlessProcess = nil
            hasLiveDetection = hasLocalInstallation()
            liveError = "Antigravity not running"
            DebugLog.info("[1/4] No Antigravity process found")
            return
        }

        hasLiveDetection = true

        let authenticated = processes.filter(\.hasCSRFToken)
        guard !authenticated.isEmpty else {
            clearConnection()
            liveSnapshot = nil
            runningTokenlessProcess = processes.first
            liveError = Self.tokenlessStatusMessage(for: processes.first)
            DebugLog.info("[1/4] Antigravity is running without --csrf_token (pid=\(processes.first?.pid ?? -1), version=\(processes.first?.ideVersion ?? "unknown"))")
            return
        }

        // Prioritize the previously connected PID if it is still running.
        let orderedProcesses: [AntigravityProcessInfo]
        if let cachedPid = connectedPid,
           let match = authenticated.first(where: { $0.pid == cachedPid }) {
            orderedProcesses = [match] + authenticated.filter { $0.pid != cachedPid }
        } else {
            clearConnection()
            orderedProcesses = authenticated
        }

        var lastFailure: String = "Could not find language server port"

        for processInfo in orderedProcesses {
            guard let token = processInfo.csrfToken, !token.isEmpty else { continue }
            if connectedPid != processInfo.pid {
                clearConnection()
            }
            csrfToken = token
            DebugLog.info("[1/4] Trying pid=\(processInfo.pid) httpsPort=\(processInfo.httpsPort.map(String.init) ?? "nil") httpPort=\(processInfo.httpPort.map(String.init) ?? "nil") csrf=\(String(token.prefix(8)))…")

            // 2. Discover connect port (may preload RetrieveUserQuotaSummary during probe)
            var preloadedSummaryData: Data?
            if connectPort == nil {
                DebugLog.info("[2/4] Discovering connect port…")
                if let discovered = await discoverConnectPort(process: processInfo, token: token) {
                    connectedPid = processInfo.pid
                    connectPort = discovered.port
                    connectScheme = discovered.scheme
                    preloadedSummaryData = discovered.preloadedSummaryData
                    DebugLog.info("[2/4] Connect port: \(discovered.port) (\(discovered.scheme))")
                } else {
                    DebugLog.info("[2/4] Failed to discover any port for pid=\(processInfo.pid)")
                    continue
                }
            }

            guard let port = connectPort else { continue }

            // 3. Fetch RetrieveUserQuotaSummary (new Antigravity) + GetUserStatus (identity + legacy fallback)
            DebugLog.info("[3/4] Fetching quota summary & user status on port \(port)…")
            let summaryResponse = await fetchQuotaSummaryBestEffort(port: port, preloadedData: preloadedSummaryData)
            var statusResponse: AntigravityUserStatusResponse?
            var statusError: Error?
            do {
                statusResponse = try await fetchUserStatus(port: port)
            } catch {
                statusError = error
                DebugLog.info("[3/4] GetUserStatus failed: \(error)")
            }

            if summaryResponse != nil || statusResponse != nil {
                let mapped = Self.mapToSnapshot(quotaSummary: summaryResponse, userStatus: statusResponse)
                if !mapped.modelQuotas.isEmpty || mapped.planName != nil || mapped.email != nil {
                    liveSnapshot = mapped
                    runningTokenlessProcess = nil
                    liveError = nil
                    DebugLog.info("[3/4] Success — \(mapped.modelQuotas.count) quota(s), plan=\(mapped.planName ?? "nil")")
                    return
                }
            }

            // 4. Fallback to GetCommandModelConfigs
            DebugLog.info("[4/4] Falling back to GetCommandModelConfigs…")
            do {
                let configsResponse = try await fetchModelConfigs(port: port)
                let mapped = Self.mapConfigsToSnapshot(configsResponse)
                liveSnapshot = mapped
                runningTokenlessProcess = nil
                liveError = nil
                DebugLog.info("[4/4] Fallback success — \(mapped.modelQuotas.count) model(s)")
                return
            } catch {
                clearConnection()
                lastFailure = (statusError ?? error).localizedDescription
                DebugLog.info("[4/4] Fallback also failed: \(error)")
            }
        }

        liveSnapshot = nil
        runningTokenlessProcess = nil
        liveError = lastFailure
    }

    // MARK: - Local Statusline Reading

    private func readLocalStatuslineQuota() {
        defer { scheduleTimeTransition() }
        let state = bridge.integrationState
        statuslineBridgeState = state
        statuslineConnected = (state == .installed || state == .appMoved)
        statuslineReadIssue = state == .modifiedExternally
            ? "The configured Antigravity CLI statusLine no longer matches MyUsage. Your configuration was preserved."
            : nil
        do {
            let read = try store.read()
            statuslineReceipt = read.latest
            if read.hasInvalidFiles {
                statuslineReadIssue = "Some local snapshots are damaged or unsupported."
            }
        } catch {
            statuslineReceipt = nil
            statuslineReadIssue = error.localizedDescription
        }
    }

    /// Expire statusline UI/menu-bar values even with automatic polling disabled.
    /// This only advances local state; it never launches or probes external processes.
    private func scheduleTimeTransition() {
        transitionTask?.cancel()
        guard let receipt = statuslineReceipt else { return }
        let current = now().timeIntervalSince1970
        var boundaries: [Double] = [
            receipt.receivedAt + Self.staleAfter + 0.01,
            receipt.receivedAt - 60
        ]
        boundaries.append(contentsOf: receipt.quotas.compactMap(\.resetsAt))
        guard let next = boundaries.filter({ $0 > current }).min() else { return }
        transitionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(next - current)) } catch { return }
            guard let self else { return }
            self.timeRevision += 1
            self.scheduleTimeTransition()
        }
    }

    // MARK: - Detection

    private func detectAvailability() {
        hasLiveDetection = hasLocalInstallation()
    }

    private func clearConnection() {
        connectedPid = nil
        connectPort = nil
        connectScheme = nil
    }

    // MARK: - Port Discovery

    private struct DiscoveredPort: Sendable {
        let port: Int
        let scheme: String
        let preloadedSummaryData: Data?
    }

    nonisolated static func tokenlessStatusMessage(for process: AntigravityProcessInfo?) -> String {
        let appLabel = process?.ideVersion.map { "Antigravity \($0)" } ?? "Antigravity"
        if process?.usesStdinBridgeToken == true {
            return "\(appLabel) is running, but uses a private stdin token; local quota API is unavailable."
        }
        return "\(appLabel) is running, but does not expose a local quota token."
    }

    private func discoverConnectPort(process: AntigravityProcessInfo, token: String) async -> DiscoveredPort? {

        var candidates: [(port: Int, schemes: [String])] = []
        var seen = Set<Int>()

        if let httpsPort = process.httpsPort, seen.insert(httpsPort).inserted {
            candidates.append((httpsPort, ["https", "http"]))
        }
        if let httpPort = process.httpPort, seen.insert(httpPort).inserted {
            candidates.append((httpPort, ["http", "https"]))
        }

        // Probe explicit CLI ports first before paying for `lsof`.
        for candidate in candidates {
            DebugLog.info("  Probing explicit port \(candidate.port)…")
            if let probed = await probePort(candidate.port, token: token, schemes: candidate.schemes) {
                return probed
            }
        }

        let listeningPorts = await ProcessHelper.findListeningPorts(pid: process.pid)
        DebugLog.info("  lsof found \(listeningPorts.count) listening port(s): \(listeningPorts)")
        let remainingPorts = listeningPorts.filter { seen.insert($0).inserted }

        let probeTask = Task<DiscoveredPort?, Never> {
            for port in remainingPorts {
                if Task.isCancelled { break }
                DebugLog.info("  Probing listening port \(port)…")
                if let probed = await probePort(port, token: token, schemes: ["https", "http"]) {
                    return probed
                }
            }
            return nil
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(15))
            DebugLog.info("  Port probing timed out (15s)")
            probeTask.cancel()
        }

        let result = await probeTask.value
        timeoutTask.cancel()

        if let result { return result }
        if let fallbackPort = process.httpsPort {
            return DiscoveredPort(port: fallbackPort, scheme: "https", preloadedSummaryData: nil)
        }
        if let fallbackPort = process.httpPort {
            return DiscoveredPort(port: fallbackPort, scheme: "http", preloadedSummaryData: nil)
        }
        return nil
    }

    /// Probe a single port. Prefers `RetrieveUserQuotaSummary` so Antigravity 2.0
    /// succeeds in a single roundtrip, while still recognizing older IDEs via
    /// Connect 404/501 or `GetUnleashData`.
    private func probePort(_ port: Int, token: String, schemes: [String]) async -> DiscoveredPort? {
        for scheme in schemes {
            if let summaryResult = await probeEndpoint(
                scheme: scheme,
                port: port,
                path: Self.retrieveQuotaSummaryPath,
                token: token
            ) {
                if summaryResult.statusCode == 200 {
                    DebugLog.info("  Port \(port) responded 200 to RetrieveUserQuotaSummary via \(scheme)")
                    return DiscoveredPort(port: port, scheme: scheme, preloadedSummaryData: summaryResult.data)
                }
                if summaryResult.statusCode == 404 || summaryResult.statusCode == 501 {
                    // Connect server is alive on this port+scheme, just an older IDE without RetrieveUserQuotaSummary.
                    if let unleash = await probeEndpoint(
                        scheme: scheme,
                        port: port,
                        path: Self.getUnleashDataPath,
                        token: token
                    ), unleash.statusCode == 200 {
                        DebugLog.info("  Port \(port) responded 200 to GetUnleashData via \(scheme)")
                        return DiscoveredPort(port: port, scheme: scheme, preloadedSummaryData: nil)
                    }
                }
            } else if let unleash = await probeEndpoint(
                scheme: scheme,
                port: port,
                path: Self.getUnleashDataPath,
                token: token
            ), unleash.statusCode == 200 {
                DebugLog.info("  Port \(port) responded 200 to GetUnleashData via \(scheme)")
                return DiscoveredPort(port: port, scheme: scheme, preloadedSummaryData: nil)
            }
        }
        return nil
    }

    private func probeEndpoint(
        scheme: String,
        port: Int,
        path: String,
        token: String
    ) async -> (statusCode: Int, data: Data)? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = Self.emptyBody
        request.timeoutInterval = 3

        do {
            let response = try await Self.sendInsecureRawRequest(request)
            return (response.statusCode, response.data)
        } catch {
            DebugLog.info("  Probe \(scheme)://…:\(port)\(path) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - API Calls

    private func fetchQuotaSummaryBestEffort(port: Int, preloadedData: Data?) async -> AntigravityQuotaSummaryResponse? {
        if let preloadedData {
            DebugLog.info("  RetrieveUserQuotaSummary (preloaded, \(preloadedData.count) bytes)")
            if let decoded = try? JSONDecoder().decode(AntigravityQuotaSummaryResponse.self, from: preloadedData),
               !decoded.resolvedGroups.isEmpty {
                return decoded
            }
        }

        for body in [Self.emptyBody, Self.requestBody] {
            do {
                let data = try await makeRequest(port: port, path: Self.retrieveQuotaSummaryPath, body: body)
                DebugLog.info("  RetrieveUserQuotaSummary raw (\(data.count) bytes): \(String(data: data.prefix(500), encoding: .utf8) ?? "<binary>")")
                let decoded = try JSONDecoder().decode(AntigravityQuotaSummaryResponse.self, from: data)
                if !decoded.resolvedGroups.isEmpty {
                    return decoded
                }
            } catch {
                DebugLog.info("  RetrieveUserQuotaSummary failed: \(error)")
            }
        }
        return nil
    }

    private func fetchUserStatus(port: Int) async throws -> AntigravityUserStatusResponse {
        let data = try await makeRequest(port: port, path: Self.getUserStatusPath, body: Self.requestBody)
        DebugLog.info("  GetUserStatus raw (\(data.count) bytes): \(String(data: data.prefix(500), encoding: .utf8) ?? "<binary>")")
        return try JSONDecoder().decode(AntigravityUserStatusResponse.self, from: data)
    }

    private func fetchModelConfigs(port: Int) async throws -> AntigravityModelConfigsResponse {
        let data = try await makeRequest(port: port, path: Self.getModelConfigsPath, body: Self.requestBody)
        DebugLog.info("  GetModelConfigs raw (\(data.count) bytes): \(String(data: data.prefix(500), encoding: .utf8) ?? "<binary>")")
        return try JSONDecoder().decode(AntigravityModelConfigsResponse.self, from: data)
    }

    private func makeRequest(port: Int, path: String, body: Data) async throws -> Data {
        guard let token = csrfToken else { throw ProviderError.notConfigured }

        let schemes: [String]
        if let known = connectScheme {
            schemes = [known]
        } else {
            schemes = ["https", "http"]
        }

        var lastError: Error = ProviderError.apiFailed(statusCode: -1)
        for scheme in schemes {
            guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
            request.httpBody = body
            request.timeoutInterval = 8

            do {
                let response = try await Self.sendInsecureRawRequest(request)
                guard response.statusCode == 200 else {
                    lastError = ProviderError.apiFailed(statusCode: response.statusCode)
                    continue
                }
                return response.data
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError
    }

    /// Send a request using completion-handler-based URLSession to avoid
    /// async delegate deadlock with self-signed TLS certs.
    private static func sendInsecureRawRequest(_ request: URLRequest) async throws -> (statusCode: Int, data: Data) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = request.timeoutInterval
        config.waitsForConnectivity = false

        let delegate = LocalhostSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: ProviderError.apiFailed(statusCode: -1))
                    return
                }
                continuation.resume(returning: (http.statusCode, data))
            }
            task.resume()
        }
    }

    // MARK: - Snapshot Mapping

    nonisolated static func mapToSnapshot(
        quotaSummary: AntigravityQuotaSummaryResponse?,
        userStatus: AntigravityUserStatusResponse?
    ) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastRefreshed = .now

        if let status = userStatus?.userStatus {
            snapshot.planName = status.resolvedPlanName
            snapshot.email = status.resolvedEmail
        }

        let summaryGroups = quotaSummary?.resolvedGroups ?? []
        let statusGroups = userStatus?.userStatus?.resolvedQuotaGroups ?? []
        let activeGroups = !summaryGroups.isEmpty ? summaryGroups : statusGroups

        if !activeGroups.isEmpty {
            snapshot.modelQuotas = mapQuotaGroups(activeGroups)
        } else if let configs = userStatus?.userStatus?.cascadeModelConfigData?.clientModelConfigs {
            snapshot.modelQuotas = mapLegacyConfigs(configs)
        }

        return snapshot
    }

    nonisolated static func mapToSnapshot(_ response: AntigravityUserStatusResponse) -> UsageSnapshot {
        mapToSnapshot(quotaSummary: nil, userStatus: response)
    }

    nonisolated static func mapQuotaSummaryToSnapshot(_ response: AntigravityQuotaSummaryResponse) -> UsageSnapshot {
        mapToSnapshot(quotaSummary: response, userStatus: nil)
    }

    nonisolated static func mapConfigsToSnapshot(_ response: AntigravityModelConfigsResponse) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastRefreshed = .now

        if let configs = response.clientModelConfigs {
            snapshot.modelQuotas = mapLegacyConfigs(configs)
        }

        return snapshot
    }

    nonisolated static func mapStatuslineToSnapshot(
        _ receipt: AntigravityStatuslineSnapshot,
        now: Date = .now
    ) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.planName = receipt.planTier
        snapshot.email = receipt.email
        snapshot.lastRefreshed = Date(timeIntervalSince1970: receipt.receivedAt)

        let current = now.timeIntervalSince1970
        var groupedBuckets: [(key: String, title: String?, inferred: Bool, items: [ModelQuota])] = []
        var groupIndexByKey: [String: Int] = [:]

        for bucket in receipt.quotas {
            guard bucket.isValid else { continue }
            if let resetsAt = bucket.resetsAt, resetsAt <= current { continue }

            let inferredWindow = inferWindow(
                window: bucket.window,
                windowLabel: nil,
                cadence: nil,
                bucketId: bucket.bucketID,
                displayName: bucket.displayName,
                durationRaw: nil
            )
            let explicitGroup = bucket.groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedGroup: String?
            let groupWasInferred: Bool
            if let explicitGroup, !explicitGroup.isEmpty {
                resolvedGroup = explicitGroup
                groupWasInferred = false
            } else if inferredWindow.label != nil {
                resolvedGroup = inferStatuslineGroupName(for: bucket)
                groupWasInferred = resolvedGroup != nil
            } else {
                resolvedGroup = nil
                groupWasInferred = false
            }

            let fullLabel: String
            if let resolvedGroup, let windowLabel = inferredWindow.label {
                fullLabel = "\(resolvedGroup) · \(windowLabel)"
            } else if let resolvedGroup, let displayName = bucket.displayName {
                fullLabel = "\(resolvedGroup) · \(displayName)"
            } else {
                fullLabel = bucket.displayName ?? bucket.bucketID
            }

            let quota = ModelQuota(
                label: fullLabel,
                remainingFraction: bucket.remainingFraction,
                resetsAt: bucket.resetsAt.map { Date(timeIntervalSince1970: $0) },
                groupName: resolvedGroup,
                windowLabel: inferredWindow.label,
                windowDuration: inferredWindow.duration,
                bucketId: bucket.bucketID
            )

            let groupKey = resolvedGroup ?? ""
            if let idx = groupIndexByKey[groupKey] {
                groupedBuckets[idx].items.append(quota)
            } else {
                groupIndexByKey[groupKey] = groupedBuckets.count
                groupedBuckets.append((groupKey, resolvedGroup, groupWasInferred, [quota]))
            }
        }

        let orderedGroups: [(key: String, title: String?, inferred: Bool, items: [ModelQuota])]
        if groupedBuckets.contains(where: \.inferred) {
            orderedGroups = groupedBuckets.enumerated().sorted { lhs, rhs in
                let lr = statuslineGroupSortRank(lhs.element.title)
                let rr = statuslineGroupSortRank(rhs.element.title)
                if lr != rr { return lr < rr }
                return lhs.offset < rhs.offset
            }.map(\.element)
        } else {
            orderedGroups = groupedBuckets
        }

        var quotas: [ModelQuota] = []
        for group in orderedGroups {
            let sortedItems = group.items.sorted { lhs, rhs in
                let lr = windowSortRank(lhs.windowDuration)
                let rr = windowSortRank(rhs.windowDuration)
                if lr != rr { return lr < rr }
                return lhs.stableKey < rhs.stableKey
            }
            quotas.append(contentsOf: sortedItems)
        }
        snapshot.modelQuotas = quotas
        return snapshot
    }

    private nonisolated static func mapQuotaGroups(_ groups: [AntigravityQuotaGroup]) -> [ModelQuota] {
        var quotas: [ModelQuota] = []

        for group in groups {
            let groupName = group.resolvedName
            var groupQuotas: [ModelQuota] = []

            for bucket in group.resolvedBuckets {
                guard bucket.disabled != true,
                      let remaining = bucket.resolvedRemainingFraction else { continue }

                let inferred = inferWindow(for: bucket)
                let resetDate = bucket.resolvedResetTime.flatMap(parseISO8601)

                let fullLabel: String
                if let groupName, let windowLabel = inferred.label {
                    fullLabel = "\(groupName) · \(windowLabel)"
                } else if let groupName, let displayName = bucket.resolvedDisplayName {
                    fullLabel = "\(groupName) · \(displayName)"
                } else {
                    fullLabel = bucket.resolvedDisplayName ?? bucket.resolvedBucketId ?? groupName ?? "Quota"
                }

                groupQuotas.append(ModelQuota(
                    label: fullLabel,
                    remainingFraction: remaining,
                    resetsAt: resetDate,
                    groupName: groupName,
                    windowLabel: inferred.label,
                    windowDuration: inferred.duration,
                    bucketId: bucket.resolvedBucketId
                ))
            }

            // Show shorter rolling windows (5h) above longer windows (7d) within each group,
            // matching Claude and Codex.
            groupQuotas.sort { lhs, rhs in
                windowSortRank(lhs.windowDuration) < windowSortRank(rhs.windowDuration)
            }
            quotas.append(contentsOf: groupQuotas)
        }

        return quotas
    }

    private nonisolated static func mapLegacyConfigs(_ configs: [AntigravityModelConfig]) -> [ModelQuota] {
        configs.compactMap { config in
            guard let label = config.label,
                  let remaining = config.quotaInfo?.remainingFraction else { return nil }
            let resetDate = config.quotaInfo?.resetTime.flatMap(parseISO8601)
            return ModelQuota(
                label: label,
                remainingFraction: remaining,
                resetsAt: resetDate
            )
        }
    }

    private nonisolated static func windowSortRank(_ duration: TimeInterval?) -> Int {
        guard let duration else { return 3 }
        if duration <= 6 * 3_600 { return 0 }  // 5h first
        if duration < 6 * 86_400 { return 1 }  // intermediate (e.g. 24h)
        return 2                               // weekly / 7d
    }

    private nonisolated static func statuslineGroupSortRank(_ title: String?) -> Int {
        guard let title else { return 3 }
        let lower = title.lowercased()
        if lower.contains("gemini") { return 0 }
        if lower.contains("claude") || lower.contains("gpt") || lower.contains("3p") { return 1 }
        return 2
    }

    private nonisolated static func inferStatuslineGroupName(
        for bucket: AntigravityStatuslineSnapshot.QuotaBucket
    ) -> String? {
        let tokens = bucket.bucketID
            .lowercased()
            .split { $0 == "-" || $0 == "_" || $0.isWhitespace }
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        let singleWindowTokens: Set<String> = [
            "5h", "5hr", "5hour", "7d", "7day", "week", "weekly",
            "24h", "1d", "daily", "limit", "quota", "window", "rolling"
        ]
        let pairedWindowSuffixes: [(String, String)] = [
            ("5", "h"), ("5", "hr"), ("5", "hour"), ("5", "hours"),
            ("five", "hour"), ("five", "hours"),
            ("7", "d"), ("7", "day"), ("7", "days"),
            ("seven", "day"), ("seven", "days"),
            ("1", "d"), ("1", "day"), ("24", "h"), ("24", "hour"), ("24", "hours")
        ]

        var prefix = tokens
        var stripped = true
        while stripped, !prefix.isEmpty {
            stripped = false
            if prefix.count >= 2 {
                let pair = (prefix[prefix.count - 2], prefix[prefix.count - 1])
                if pairedWindowSuffixes.contains(where: { $0.0 == pair.0 && $0.1 == pair.1 }) {
                    prefix.removeLast(2)
                    stripped = true
                    continue
                }
            }
            if let last = prefix.last, singleWindowTokens.contains(last) {
                prefix.removeLast()
                stripped = true
            }
        }
        guard !prefix.isEmpty else { return nil }

        let joined = prefix.joined(separator: "-")
        switch joined {
        case "gemini", "google", "1p":
            return "Gemini Models"
        case "3p", "third-party", "thirdparty", "claude-gpt", "claude-and-gpt", "partner", "partners":
            return "Claude & GPT Models"
        case "claude", "anthropic":
            return "Claude Models"
        case "gpt", "openai":
            return "GPT Models"
        default:
            return prefix.map { token in
                switch token {
                case "gpt": "GPT"
                case "3p": "3P"
                case "ai": "AI"
                default: token.capitalized
                }
            }.joined(separator: " ")
        }
    }

    private nonisolated static func inferWindow(
        for bucket: AntigravityQuotaBucket
    ) -> (label: String?, duration: TimeInterval?) {
        inferWindow(
            window: bucket.window,
            windowLabel: bucket.windowLabel,
            cadence: bucket.cadence,
            bucketId: bucket.resolvedBucketId,
            displayName: bucket.resolvedDisplayName,
            durationRaw: bucket.windowDuration ?? bucket.duration
        )
    }

    private nonisolated static func inferWindow(
        window: String?,
        windowLabel: String?,
        cadence: String?,
        bucketId: String?,
        displayName: String?,
        durationRaw: String?
    ) -> (label: String?, duration: TimeInterval?) {
        let hints = [window, windowLabel, cadence, bucketId, displayName]
            .compactMap { $0?.lowercased().replacingOccurrences(of: "_", with: "-") }
            .joined(separator: " ")

        if hints.contains("weekly") || hints.contains("week") || hints.contains("7d") || hints.contains("7-d")
            || hints.contains("7-day") || hints.contains("7 day") || hints.contains("seven-day") || hints.contains("seven day") {
            return ("7d", 7 * 86_400)
        }
        if hints.contains("5h") || hints.contains("5-h") || hints.contains("5-hour") || hints.contains("5 hour")
            || hints.contains("five-hour") || hints.contains("five hour") {
            return ("5h", 5 * 3_600)
        }
        if hints.contains("24h") || hints.contains("24-h") || hints.contains("daily")
            || hints.contains("1d") || hints.contains("1-d") || hints.contains("1-day") || hints.contains("1 day") {
            return ("24h", 86_400)
        }

        if let seconds = parseDurationSeconds(durationRaw) {
            if abs(seconds - 7 * 86_400) < 60 { return ("7d", seconds) }
            if abs(seconds - 5 * 3_600) < 60 { return ("5h", seconds) }
            if seconds >= 86_400 {
                return ("\(Int((seconds / 86_400).rounded()))d", seconds)
            }
            if seconds >= 3_600 {
                return ("\(Int((seconds / 3_600).rounded()))h", seconds)
            }
            return (nil, seconds)
        }

        return (window ?? windowLabel, nil)
    }

    private nonisolated static func parseDurationSeconds(_ raw: String?) -> TimeInterval? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasSuffix("s"), let seconds = Double(trimmed.dropLast()), seconds > 0 {
            return seconds
        }
        if let seconds = Double(trimmed), seconds > 0 {
            return seconds
        }
        return nil
    }
}

// MARK: - Localhost TLS delegate (completionHandler-based, avoids async deadlock)

private final class LocalhostSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           (space.host == "127.0.0.1" || space.host == "localhost"),
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Shared helper

private func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    // Try without fractional seconds
    let basicFormatter = ISO8601DateFormatter()
    if let date = basicFormatter.date(from: string) { return date }
    // Try numeric epoch
    if let seconds = Double(string), seconds > 1_000_000_000 {
        return Date(timeIntervalSince1970: seconds)
    }
    return nil
}
