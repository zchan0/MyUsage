#if DEBUG
import SwiftUI

@MainActor
enum GatewayPreviewFixtures {
    enum Shape: String, CaseIterable { case full, tokens, noHistory, empty, stale }
    static let instanceID = id(index: 0)
    static func id(index: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", index + 1))!
    }

    static func provider(_ shape: Shape = .full, index: Int = 0) -> GatewayProvider {
        let scope = GatewayScope(kind: .user, id: "preview-user")
        let connection = GatewayConnection(id: id(index: index), name: index == 0 ? "Company gateway" : "Company gateway \(index + 1)", baseURL: URL(string: "https://ai.example.com")!, scope: scope)
        let summary = GatewaySummary(scope: scope, spend: 42.10, budget: shape == .tokens ? .unspecified : .finite(100),
                                     currency: "USD", budgetDuration: "1mo", resetsAt: Date.now.addingTimeInterval(8 * 86_400))
        let end = GatewayCalendar.day(.now), start = String(end.prefix(7)) + "-01"
        let days = (0..<7).map { index in
            var metrics = GatewayMetrics(cost: shape == .tokens ? nil : Decimal(index + 1) / 2,
                                         totalTokens: Int64(index + 1) * 12000, inputTokens: Int64(index + 1) * 10000,
                                         outputTokens: Int64(index + 1) * 2000, cacheReadTokens: Int64(index + 1) * 4000, cacheWriteTokens: Int64(index + 1) * 1000, requests: Int64(index + 1) * 10)
            var models = [index % 2 == 0 ? "company-sonnet" : "coding-model-alias": metrics]
            if shape == .full, index == 0 {
                let free = GatewayMetrics(cost: 0, totalTokens: 400, inputTokens: 300, outputTokens: 100,
                                          cacheReadTokens: 0, cacheWriteTokens: 0, requests: 1)
                let small = GatewayMetrics(cost: Decimal(string: "0.001"), totalTokens: 10, inputTokens: 8, outputTokens: 2,
                                           cacheReadTokens: 0, cacheWriteTokens: 0, requests: 1)
                models["free-model-hidden"] = free
                models["small-paid-model"] = small
                metrics = .sum([metrics, free, small])
            }
            return GatewayHistory.Day(date: String(start.prefix(8)) + String(format: "%02d", index + 1), metrics: metrics,
                                      models: models)
        }
        let history = GatewayHistory(scope: scope, startDate: start, endDate: end, days: shape == .empty ? [] : days, complete: true)
        let adapter = PreviewGatewayAdapter(summary: summary, history: history, shape: shape)
        return GatewayProvider(connection: connection, credentials: PreviewGatewayCredentials(), adapter: adapter,
                               initial: .init(scope: scope, summary: .init(value: summary, updatedAt: .now,
                                                                          issue: shape == .stale ? .network : nil), history: .init()))
    }
}

private struct PreviewGatewayCredentials: GatewayCredentialStore {
    func read(_ reference: String, allowUI: Bool) throws -> String { "preview-placeholder" }
    func write(_ key: String, reference: String) throws { throw GatewayStoreError.keychain }
    func delete(_ reference: String) throws { }
}

private struct PreviewGatewayAdapter: GatewayAdapter {
    let summary: GatewaySummary
    let history: GatewayHistory
    let shape: GatewayPreviewFixtures.Shape
    func checkConnection(_ context: GatewayRequestContext) async throws -> GatewayConnectionCheck {
        .init(checkedAt: .now, scopes: [.init(scope: summary.scope, summary: .init(value: summary, updatedAt: .now), history: .init())], issues: [])
    }
    func fetchSummary(_ context: GatewayRequestContext) async throws -> GatewayBlock<GatewaySummary> {
        shape == .stale ? .init(issue: .network) : .init(value: summary, updatedAt: .now)
    }
    func fetchHistory(_ context: GatewayRequestContext, start: String, end: String, probe: Bool) async throws -> GatewayBlock<GatewayHistory> {
        shape == .noHistory ? .init(issue: .forbidden) : .init(value: history, updatedAt: .now)
    }
}

#Preview("Gateway · budget and models") {
    GatewayProviderDeck(provider: GatewayPreviewFixtures.provider()).frame(width: PopoverLayout.width)
}
#Preview("Gateway · tokens only") {
    GatewayProviderDeck(provider: GatewayPreviewFixtures.provider(.tokens)).frame(width: PopoverLayout.width)
}
#Preview("Gateway · history forbidden") {
    GatewayProviderDeck(provider: GatewayPreviewFixtures.provider(.noHistory)).frame(width: PopoverLayout.width)
}
#Preview("Gateway · stale") {
    GatewayProviderDeck(provider: GatewayPreviewFixtures.provider(.stale)).frame(width: PopoverLayout.width)
}
#Preview("Gateway · empty history") {
    GatewayProviderDeck(provider: GatewayPreviewFixtures.provider(.empty)).frame(width: PopoverLayout.width)
}
#Preview("Gateway · connection editor") {
    GatewayConnectionEditor(connection: nil).environment(PreviewFixtures.manager())
}
#endif
