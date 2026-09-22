import Foundation
import CryptoKit

struct LiteLLMAdapter: GatewayAdapter {
    let transport: any GatewayTransport
    init(transport: any GatewayTransport = GatewayURLTransport()) { self.transport = transport }

    func checkConnection(_ context: GatewayRequestContext) async throws -> GatewayConnectionCheck {
        var check = GatewayConnectionCheck(checkedAt: .now, scopes: [], issues: [])
        var userID = context.connection.explicitUserID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if userID?.isEmpty == true { userID = nil }
        do {
            let key: KeyEnvelope = try await get("key/info", context: context)
            userID = key.info.userID ?? userID
            let scope = keyScope(context.apiKey)
            let summary = try key.info.summary(scope: scope)
            check.scopes.append(.init(scope: scope, summary: .init(value: summary, updatedAt: .now),
                                      history: .init(issue: .unsupported)))
        } catch {
            try rethrowCancellation(error)
            let issue = issue(error); check.issues.append(issue)
            if issue == .authentication { return check }
            if case .rateLimited = issue { return check }
        }
        guard let userID, !userID.isEmpty else {
            check.issues.append(.identityUnknown); return check
        }
        let scope = GatewayScope(kind: .user, id: userID)
        var userContext = context
        var connection = context.connection; connection.scope = scope
        userContext = .init(connection: connection, apiKey: context.apiKey)
        let summary = try await fetchSummary(userContext)
        var history = GatewayBlock<GatewayHistory>(issue: .notChecked)
        if summary.value != nil {
            let end = GatewayCalendar.day(.now)
            let start = GatewayCalendar.day(Date.now.addingTimeInterval(-86_400))
            history = try await fetchHistory(userContext, start: start, end: end, probe: true)
        }
        check.scopes.append(.init(scope: scope, summary: summary, history: history))
        return check
    }

    func fetchSummary(_ context: GatewayRequestContext) async throws -> GatewayBlock<GatewaySummary> {
        do {
            guard let scope = context.connection.scope else { throw GatewayIssue.identityUnknown }
            let summary: GatewaySummary
            switch scope.kind {
            case .key:
                guard scope == keyScope(context.apiKey) else { throw GatewayIssue.identityUnknown }
                let result: KeyEnvelope = try await get("key/info", context: context)
                summary = try result.info.summary(scope: scope)
            case .user:
                guard !scope.id.isEmpty else { throw GatewayIssue.identityUnknown }
                let result: UserEnvelope = try await get("user/info", query: [.init(name: "user_id", value: scope.id)], context: context)
                guard (result.userID ?? result.userInfo.userID) == scope.id,
                      result.userInfo.userID == nil || result.userInfo.userID == scope.id else { throw GatewayIssue.invalidResponse }
                summary = try result.userInfo.summary(scope: scope)
            }
            return .init(value: summary, updatedAt: .now)
        } catch {
            try rethrowCancellation(error)
            return .init(issue: issue(error))
        }
    }

    func fetchHistory(_ context: GatewayRequestContext, start: String, end: String, probe: Bool = false) async throws -> GatewayBlock<GatewayHistory> {
        guard let scope = context.connection.scope else { return .init(issue: .identityUnknown) }
        guard scope.kind == .user else { return .init(issue: .unsupported) }
        var days: [GatewayHistory.Day] = []
        var dates: Set<String> = []
        var complete = false
        var failure: GatewayIssue?
        let pageSize = probe ? 1 : 100
        let deadline = Date.now.addingTimeInterval(probe ? 3 : 20)
        for page in 1...(probe ? 1 : 10) {
            do {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw GatewayIssue.network }
                let result: HistoryEnvelope = try await get("user/daily/activity", query: [
                    .init(name: "user_id", value: scope.id), .init(name: "start_date", value: start),
                    .init(name: "end_date", value: end), .init(name: "page", value: String(page)),
                    .init(name: "page_size", value: String(pageSize))
                ], context: context, timeout: min(probe ? 3 : 8, remaining))
                for row in result.results {
                    guard row.date >= start, row.date <= end, dates.insert(row.date).inserted,
                          GatewayCalendar.parseDay(row.date) != nil else { throw GatewayIssue.invalidResponse }
                    days.append(.init(date: row.date, metrics: try row.metrics.mapped(),
                                      models: try (row.breakdown?.models ?? [:]).mapValues { try $0.mapped() },
                                      modelsReported: row.breakdown?.models != nil))
                }
                let hasMore = result.metadata?.hasMore ?? result.metadata?.hasMorePages
                    ?? result.metadata?.totalPages.map { page < $0 }
                    ?? (result.results.count == pageSize)
                if !hasMore { complete = true; break }
                if result.results.isEmpty { throw GatewayIssue.invalidResponse }
            } catch {
                try rethrowCancellation(error); failure = issue(error); break
            }
        }
        if days.isEmpty, let failure { return .init(issue: failure) }
        return .init(value: GatewayHistory(scope: scope, startDate: start, endDate: end,
                                           days: days.sorted { $0.date < $1.date }, complete: complete),
                     updatedAt: .now, issue: failure)
    }

    private func keyScope(_ key: String) -> GatewayScope {
        .init(kind: .key, id: SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    private func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [],
                                              context: GatewayRequestContext, timeout: Double = 4) async throws -> T {
        try Task.checkCancellation()
        guard !context.apiKey.isEmpty, !context.apiKey.contains(where: { $0.isNewline }) else { throw GatewayIssue.missingCredential }
        let base = try GatewayAddress.normalize(context.connection.baseURL.absoluteString)
        // LiteLLM management routes live beside its inference /v1 routes.
        let management = base.lastPathComponent == "v1" ? base.deletingLastPathComponent() : base
        var parts = URLComponents(url: management.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw GatewayIssue.invalidConfiguration }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(context.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let requestToSend = request
        let (data, response) = try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await transport.data(for: requestToSend) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GatewayIssue.network
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        switch response.statusCode {
        case 200: break
        case 401: throw GatewayIssue.authentication
        case 403: throw GatewayIssue.forbidden
        case 404: throw GatewayIssue.endpointUnavailable
        case 429:
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap { RetryAfterParser.seconds(from: $0) }
            throw GatewayIssue.rateLimited(until: seconds.map { Date.now.addingTimeInterval(max(0, $0)) })
        default: throw GatewayIssue.network
        }
        guard data.count < 8_000_000 else { throw GatewayIssue.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GatewayIssue.invalidResponse }
    }

    private func issue(_ error: Error) -> GatewayIssue { error as? GatewayIssue ?? .network }
    private func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct Number: Decodable, Sendable {
    let value: Decimal
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let string = try? c.decode(String.self), string.range(of: #"^[+]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
           let number = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) {
            value = number
        } else { value = try c.decode(Decimal.self) }
        guard !value.isNaN, value >= 0 else { throw GatewayIssue.invalidResponse }
    }
    var count: Int64? {
        let number = NSDecimalNumber(decimal: value)
        let count = number.int64Value
        return count >= 0 && Decimal(count) == value ? count : nil
    }
}

private struct KeyEnvelope: Decodable, Sendable { let info: Info }
private struct UserEnvelope: Decodable, Sendable {
    let userID: String?
    let userInfo: Info
    enum CodingKeys: String, CodingKey { case userID = "user_id", userInfo = "user_info" }
}
private struct Info: Decodable, Sendable {
    let userID: String?
    let spend: Number?
    let maxBudget: Number?
    let budgetDuration: String?
    let budgetResetAt: String?
    let hasBudgetField: Bool
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", spend, maxBudget = "max_budget", budgetDuration = "budget_duration", budgetResetAt = "budget_reset_at"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
        spend = try c.decodeIfPresent(Number.self, forKey: .spend)
        maxBudget = try c.decodeIfPresent(Number.self, forKey: .maxBudget)
        hasBudgetField = c.contains(.maxBudget)
        budgetDuration = try c.decodeIfPresent(String.self, forKey: .budgetDuration)
        budgetResetAt = try c.decodeIfPresent(String.self, forKey: .budgetResetAt)
    }
    func summary(scope: GatewayScope) throws -> GatewaySummary {
        guard spend != nil || maxBudget != nil else { throw GatewayIssue.invalidResponse }
        return .init(scope: scope, spend: spend?.value,
                     budget: maxBudget.map { .finite($0.value) } ?? (hasBudgetField ? .unbounded : .unspecified),
                     currency: "USD", budgetDuration: budgetDuration, resetsAt: LiteLLMAdapter.date(budgetResetAt))
    }
}

private struct HistoryEnvelope: Decodable, Sendable {
    let results: [Row]
    let metadata: Metadata?
    struct Row: Decodable, Sendable {
        let date: String
        let metrics: Metrics
        let breakdown: Breakdown?
    }
    struct Breakdown: Decodable, Sendable { let models: [String: ModelMetrics]? }
    struct Metadata: Decodable, Sendable {
        let totalPages: Int?
        let hasMore: Bool?
        let hasMorePages: Bool?
        enum CodingKeys: String, CodingKey { case totalPages = "total_pages", hasMore = "has_more", hasMorePages = "has_more_pages" }
    }
}

private struct Metrics: Decodable, Sendable {
    let spend: Number?
    let total: Number?
    let input: Number?
    let output: Number?
    let cacheRead: Number?
    let cacheWrite: Number?
    let requests: Number?
    enum CodingKeys: String, CodingKey {
        case spend, total = "total_tokens", input = "prompt_tokens", output = "completion_tokens"
        case cacheRead = "cache_read_input_tokens", cacheWrite = "cache_creation_input_tokens", requests = "api_requests"
    }
    func mapped() throws -> GatewayMetrics {
        guard spend != nil || total != nil || input != nil || output != nil || requests != nil else { throw GatewayIssue.invalidResponse }
        return .init(cost: spend?.value, totalTokens: total?.count, inputTokens: input?.count,
                     outputTokens: output?.count, cacheReadTokens: cacheRead?.count,
                     cacheWriteTokens: cacheWrite?.count, requests: requests?.count)
    }
}

private struct ModelMetrics: Decodable, Sendable {
    let metrics: Metrics?
    let direct: Metrics
    enum CodingKeys: String, CodingKey { case metrics }
    init(from decoder: Decoder) throws {
        metrics = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Metrics.self, forKey: .metrics)
        direct = try Metrics(from: decoder)
    }
    func mapped() throws -> GatewayMetrics { try (metrics ?? direct).mapped() }
}
