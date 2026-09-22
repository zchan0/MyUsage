import Foundation
import Observation

@Observable @MainActor
final class GatewayProvider: UsageProvider {
    private(set) var connection: GatewayConnection
    private(set) var snapshot = GatewaySnapshot()
    private(set) var isLoading = false
    private(set) var isLoadingHistory = false
    var isEnabled = true
    var isHistoryVisible = false
    var id: ProviderID { connection.providerID }
    var source: ProviderSource { .gateway(connection.vendor) }
    var displayName: String { connection.name }
    var shortName: String { connection.name }
    var payload: ProviderPayload? { .gateway(snapshot) }
    var isAvailable: Bool { snapshot.summary.value != nil }
    var error: String? { snapshot.summary.issue?.message }
    private let credentials: any GatewayCredentialStore
    private let adapter: any GatewayAdapter
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var retryAfter: Date?
    private var lastHistoryAttempt: Date?

    init(connection: GatewayConnection, credentials: any GatewayCredentialStore,
         adapter: (any GatewayAdapter)? = nil, initial: GatewayScopeCheck? = nil) {
        self.connection = connection; self.credentials = credentials
        self.adapter = adapter ?? GatewayAdapters.adapter(for: connection.vendor)
        if let initial, initial.scope == connection.scope {
            snapshot.summary = initial.summary
            if case .rateLimited(let until) = initial.history.issue { retryAfter = until ?? .now.addingTimeInterval(60) }
        }
    }
    func update(_ connection: GatewayConnection, initial: GatewayScopeCheck? = nil) {
        let changed = self.connection.baseURL != connection.baseURL
            || self.connection.credentialReference != connection.credentialReference || self.connection.scope != connection.scope
            || self.connection.explicitUserID != connection.explicitUserID
        self.connection = connection
        guard changed else { return }
        invalidate(); snapshot = GatewaySnapshot(); retryAfter = nil; lastHistoryAttempt = nil
        if let initial, initial.scope == connection.scope {
            snapshot.summary = initial.summary
            if case .rateLimited(let until) = initial.history.issue { retryAfter = until ?? .now.addingTimeInterval(60) }
        }
    }
    func invalidate() {
        revision = UUID(); task?.cancel(); historyTask?.cancel()
        task = nil; historyTask = nil; isLoading = false; isLoadingHistory = false
    }
    func refresh() async { await refresh(trigger: .automatic) }
    func refresh(trigger: UsageRefreshTrigger) async {
        if let task { await task.value; return }
        if let retryAfter, retryAfter > .now { return }
        let current = revision
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if revision == current { isLoading = false; task = nil } }
            do {
                let key = try credentials.read(connection.credentialReference)
                var context = GatewayRequestContext(connection: connection, apiKey: key)
                if connection.scope == nil {
                    let check = try await adapter.checkConnection(context)
                    guard revision == current, !Task.isCancelled else { return }
                    guard let scope = check.preferredScope else {
                        let issue = check.issues.first ?? check.scopes.first?.summary.issue ?? .identityUnknown
                        snapshot.summary.issue = issue
                        if case .rateLimited(let until) = issue { retryAfter = until ?? .now.addingTimeInterval(60) }
                        return
                    }
                    // Draft saves can discover a scope on a later successful connection.
                    connection.scope = scope; context = .init(connection: connection, apiKey: key)
                    if let result = check.scopes.first(where: { $0.scope == scope }) { snapshot.summary.merge(result.summary) }
                } else {
                    let result = try await adapter.fetchSummary(context)
                    guard revision == current, !Task.isCancelled else { return }
                    snapshot.summary.merge(result)
                    if case .rateLimited(let until) = result.issue { retryAfter = until ?? .now.addingTimeInterval(60) }
                }
                if isHistoryVisible, snapshot.summary.issue != .authentication { await loadHistory(force: trigger == .manual) }
            } catch is CancellationError { }
            catch {
                guard revision == current else { return }
                snapshot.summary.issue = (error as? GatewayIssue) ?? .network
            }
        }
        await task?.value
    }
    func loadHistory(force: Bool = false) async {
        if let historyTask { await historyTask.value; return }
        let end = GatewayCalendar.day(.now)
        let start = String(end.prefix(7)) + "-01"
        if !force, let date = lastHistoryAttempt,
           GatewayCalendar.day(date).prefix(7) == end.prefix(7), Date.now.timeIntervalSince(date) < 300 { return }
        if let retryAfter, retryAfter > .now { return }
        guard connection.scope != nil else { return }
        let current = revision
        lastHistoryAttempt = .now
        isLoadingHistory = true
        historyTask = Task { [weak self] in
            guard let self else { return }
            defer { if revision == current { isLoadingHistory = false; historyTask = nil } }
            do {
                let key = try credentials.read(connection.credentialReference)
                let result = try await adapter.fetchHistory(.init(connection: connection, apiKey: key), start: start, end: end, probe: false)
                guard revision == current, !Task.isCancelled else { return }
                // Never retain last month's totals under this month's label.
                if snapshot.history.value?.startDate != start { snapshot.history = result }
                else { snapshot.history.merge(result) }
                if case .rateLimited(let until) = result.issue { retryAfter = until ?? .now.addingTimeInterval(60) }
            } catch is CancellationError { }
            catch { if revision == current { snapshot.history.issue = (error as? GatewayIssue) ?? .network } }
        }
        await historyTask?.value
    }
}
