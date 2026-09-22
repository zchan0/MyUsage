import XCTest
import Foundation
@testable import MyUsage

private actor FixtureGatewayTransport: GatewayTransport {
    struct Reply: Sendable {
        var status = 200
        var json: String
        var headers: [String: String] = [:]
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw GatewayIssue.network }
        let reply = replies.removeFirst()
        return (Data(reply.json.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status,
                httpVersion: nil, headerFields: reply.headers)!)
    }
}

final class GatewayAdapterTests: XCTestCase, @unchecked Sendable {
    private let keyInfo = #"{"info":{"user_id":"fixture-user","spend":12.34,"max_budget":100,"budget_duration":"1mo","budget_reset_at":"2026-10-01T00:00:00Z"}}"#
    private let userInfo = #"{"user_id":"fixture-user","user_info":{"user_id":"fixture-user","spend":"34.56","max_budget":200,"budget_duration":"1mo"}}"#
    private let emptyHistory = #"{"results":[],"metadata":{"has_more":false}}"#
    private func context(scope: GatewayScope? = nil) -> GatewayRequestContext {
        .init(connection: .init(name: "Fixture", baseURL: URL(string: "https://fixture.example/proxy/v1")!, scope: scope), apiKey: "fixture-not-a-real-key")
    }

    func testCheckUsesOwnKeyAndExplicitUserThenBoundedHistory() async throws {
        let transport = FixtureGatewayTransport([.init(json: keyInfo), .init(json: userInfo), .init(json: emptyHistory)])
        let check = try await LiteLLMAdapter(transport: transport).checkConnection(context())
        XCTAssertEqual(check.usableScopes.count, 2)
        XCTAssertEqual(check.preferredScope, .init(kind: .user, id: "fixture-user"))
        XCTAssertEqual(check.scopes[0].summary.value?.spend, Decimal(string: "12.34"))
        XCTAssertEqual(check.scopes[1].summary.value?.spend, Decimal(string: "34.56"))
        XCTAssertNil(check.scopes[1].history.value?.totals.cost, "Empty history does not prove zero month spend")
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/proxy/key/info", "/proxy/user/info", "/proxy/user/daily/activity"])
        XCTAssertNil(requests[0].url?.query)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-not-a-real-key")
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-not-a-real-key"))
        }
        let query = URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "user_id" }?.value, "fixture-user")
        XCTAssertEqual(query.first { $0.name == "page_size" }?.value, "1")
    }

    func testForbiddenUserRetainsKeySummaryAndSkipsHistory() async throws {
        let transport = FixtureGatewayTransport([.init(json: keyInfo), .init(status: 403, json: "{}")])
        let check = try await LiteLLMAdapter(transport: transport).checkConnection(context())
        XCTAssertEqual(check.usableScopes.count, 1)
        XCTAssertEqual(check.preferredScope?.kind, .key)
        XCTAssertEqual(check.scopes.last?.summary.issue, .forbidden)
        let count = await transport.requests.count; XCTAssertEqual(count, 2)
    }

    func testExplicitUserCanBeCheckedWhenKeyInfoIsForbidden() async throws {
        let transport = FixtureGatewayTransport([.init(status: 403, json: "{}"), .init(json: userInfo), .init(status: 403, json: "{}")])
        var connection = context().connection; connection.explicitUserID = "fixture-user"
        let check = try await LiteLLMAdapter(transport: transport).checkConnection(.init(connection: connection, apiKey: "fixture"))
        XCTAssertEqual(check.usableScopes.count, 1)
        XCTAssertEqual(check.preferredScope?.kind, .user)
        XCTAssertEqual(check.scopes.first?.history.issue, .forbidden)
    }

    func testNoUserIdentityNeverQueriesGlobalUserInfo() async throws {
        let transport = FixtureGatewayTransport([.init(json: #"{"info":{"spend":1,"max_budget":null}}"#)])
        let check = try await LiteLLMAdapter(transport: transport).checkConnection(context())
        XCTAssertEqual(check.usableScopes.count, 1)
        XCTAssertTrue(check.issues.contains(.identityUnknown))
        XCTAssertEqual(check.scopes[0].summary.value?.budget, .unbounded)
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }

    func testAuthenticationFailureStopsCheck() async throws {
        let transport = FixtureGatewayTransport([.init(status: 401, json: "{}")])
        let check = try await LiteLLMAdapter(transport: transport).checkConnection(context())
        XCTAssertTrue(check.usableScopes.isEmpty)
        XCTAssertEqual(check.issues, [.authentication])
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }

    func testHTMLAndErrorJSONCannotPassUsageCheck() async throws {
        for json in ["<html>Sign in</html>", #"{"error":"not allowed"}"#, #"{"info":{"models":["model-a"]}}"#] {
            let transport = FixtureGatewayTransport([.init(json: json)])
            let check = try await LiteLLMAdapter(transport: transport).checkConnection(context())
            XCTAssertTrue(check.usableScopes.isEmpty)
            XCTAssertTrue(check.issues.contains(.invalidResponse))
        }
    }

    func testMismatchedUserIsRejected() async throws {
        let transport = FixtureGatewayTransport([.init(json: #"{"user_id":"someone-else","user_info":{"spend":10}}"#)])
        let block = try await LiteLLMAdapter(transport: transport).fetchSummary(context(scope: .init(kind: .user, id: "fixture-user")))
        XCTAssertNil(block.value); XCTAssertEqual(block.issue, .invalidResponse)
    }

    func testBudgetZeroMissingAndNullStayDistinct() async throws {
        for (suffix, expected) in [("", GatewayBudget.unspecified), (",\"max_budget\":null", .unbounded), (",\"max_budget\":0", .finite(0))] {
            let transport = FixtureGatewayTransport([.init(json: "{\"user_id\":\"fixture-user\",\"user_info\":{\"spend\":0\(suffix)}}")])
            let block = try await LiteLLMAdapter(transport: transport).fetchSummary(context(scope: .init(kind: .user, id: "fixture-user")))
            XCTAssertEqual(block.value?.budget, expected); XCTAssertNil(block.value?.percentUsed)
        }
    }

    func testPagedHistoryDoesNotAddCacheToTotalAndKeepsMissingFieldsUnknown() async throws {
        let a = #"{"results":[{"date":"2026-09-01","metrics":{"spend":1.25,"total_tokens":100,"prompt_tokens":80,"completion_tokens":20,"cache_read_input_tokens":60},"breakdown":{"model_groups":{"alias-a":{"spend":1.25,"total_tokens":100}}}}],"metadata":{"has_more":true}}"#
        let b = #"{"results":[{"date":"2026-09-02","metrics":{"spend":2.50,"total_tokens":200,"prompt_tokens":180,"completion_tokens":20},"breakdown":{"model_groups":{"alias-a":{"metrics":{"spend":2.5,"total_tokens":200}}}}}],"metadata":{"has_more":false}}"#
        let transport = FixtureGatewayTransport([.init(json: a), .init(json: b)])
        let block = try await LiteLLMAdapter(transport: transport).fetchHistory(context(scope: .init(kind: .user, id: "fixture-user")), start: "2026-09-01", end: "2026-09-22", probe: false)
        let history = try XCTUnwrap(block.value)
        XCTAssertTrue(history.complete); XCTAssertEqual(history.totals.cost, Decimal(string: "3.75"))
        XCTAssertEqual(history.totals.totalTokens, 300); XCTAssertNil(history.totals.cacheReadTokens)
        XCTAssertEqual(history.models.first?.name, "alias-a"); XCTAssertEqual(history.models.first?.metrics.totalTokens, 300)
    }

    func testHistoryUsesModelGroupsForAliasesAndRequestsIncludingFailures() async throws {
        let json = #"""
        {"results":[{"date":"2026-09-01",
          "metrics":{"spend":1.25,"total_tokens":100,"api_requests":6},
          "breakdown":{
            "model_groups":{
              "codex-alias":{"metrics":{"spend":1.25,"total_tokens":100,"api_requests":4,"successful_requests":3,"failed_requests":1}},
              "cc-alias":{"metrics":{"spend":0,"total_tokens":0,"api_requests":2,"successful_requests":0,"failed_requests":2}}
            },
            "models":{"custom-model-b12":{"metrics":{"spend":1.25,"total_tokens":100,"api_requests":3,"successful_requests":3,"failed_requests":0}}}
          }
        }],"metadata":{"has_more":false}}
        """#
        let adapter = LiteLLMAdapter(transport: FixtureGatewayTransport([.init(json: json)]))
        let block = try await adapter.fetchHistory(context(scope: .init(kind: .user, id: "fixture-user")), start: "2026-09-01", end: "2026-09-22")
        let history = try XCTUnwrap(block.value)
        XCTAssertNil(block.issue)
        XCTAssertTrue(history.hasCompleteModelBreakdown)
        let day = try XCTUnwrap(history.days.first)
        XCTAssertEqual(Set(day.models.keys), ["codex-alias", "cc-alias"])
        XCTAssertEqual(day.models["codex-alias"]?.requests, 4)
        XCTAssertEqual(day.models["cc-alias"]?.requests, 2, "Failed-only groups remain in the mapped history")
        XCTAssertEqual(history.models.map(\.name), ["codex-alias"], "Existing zero-cost row filtering still applies")
        XCTAssertEqual(history.models.first?.metrics.requests, 4)
        XCTAssertEqual(history.totals.requests, 6)
        XCTAssertEqual(history.totals.cost, Decimal(string: "1.25"))
        XCTAssertEqual(history.totals.totalTokens, 100)
    }

    func testMissingOrNullModelGroupsDoNotUseDeploymentModels() async throws {
        for groupField in ["", #""model_groups":null,"#] {
            let json = """
            {"results":[{"date":"2026-09-01","metrics":{"spend":1,"api_requests":2},
              "breakdown":{\(groupField)"models":{"custom-model-b12":{"metrics":{"spend":1,"api_requests":1}}}}
            }],"metadata":{"has_more":false}}
            """
            let adapter = LiteLLMAdapter(transport: FixtureGatewayTransport([.init(json: json)]))
            let block = try await adapter.fetchHistory(context(scope: .init(kind: .user, id: "fixture-user")), start: "2026-09-01", end: "2026-09-22")
            let history = try XCTUnwrap(block.value)
            XCTAssertNil(block.issue)
            XCTAssertTrue(history.complete)
            XCTAssertFalse(history.hasCompleteModelBreakdown)
            XCTAssertTrue(history.models.isEmpty)
            XCTAssertEqual(history.days.first?.modelsReported, false)
            XCTAssertEqual(history.totals.requests, 2)
            XCTAssertEqual(history.totals.cost, 1)
        }
    }

    func testEmptyModelGroupsAreReportedWithoutFallingBackToDeploymentModels() async throws {
        let json = #"{"results":[{"date":"2026-09-01","metrics":{"spend":1},"breakdown":{"model_groups":{},"models":{"custom-model-b12":{"spend":1}}}}],"metadata":{"has_more":false}}"#
        let adapter = LiteLLMAdapter(transport: FixtureGatewayTransport([.init(json: json)]))
        let block = try await adapter.fetchHistory(context(scope: .init(kind: .user, id: "fixture-user")), start: "2026-09-01", end: "2026-09-22")
        let history = try XCTUnwrap(block.value)
        XCTAssertTrue(history.hasCompleteModelBreakdown)
        XCTAssertTrue(history.models.isEmpty)
        XCTAssertEqual(history.totals.cost, 1)
    }

    func testUnusedDeploymentModelsCannotInvalidateModelGroups() async throws {
        let json = #"{"results":[{"date":"2026-09-01","metrics":{"spend":1},"breakdown":{"model_groups":{"codex-alias":{"spend":1}},"models":{"custom-model-b12":{"spend":"invalid"}}}}],"metadata":{"has_more":false}}"#
        let adapter = LiteLLMAdapter(transport: FixtureGatewayTransport([.init(json: json)]))
        let block = try await adapter.fetchHistory(context(scope: .init(kind: .user, id: "fixture-user")), start: "2026-09-01", end: "2026-09-22")
        XCTAssertNil(block.issue)
        XCTAssertEqual(block.value?.models.map(\.name), ["codex-alias"])
    }

    func testHistoryPaginationFailureIsPartialNotFullMonth() async throws {
        let a = #"{"results":[{"date":"2026-09-01","metrics":{"spend":1}}],"metadata":{"has_more":true}}"#
        let transport = FixtureGatewayTransport([.init(json: a), .init(status: 500, json: "{}")])
        let block = try await LiteLLMAdapter(transport: transport).fetchHistory(context(scope: .init(kind: .user, id: "fixture-user")), start: "2026-09-01", end: "2026-09-22", probe: false)
        XCTAssertEqual(block.value?.complete, false); XCTAssertEqual(block.issue, .network)
        XCTAssertEqual(block.value?.totals.cost, 1)
    }

    func testKeyHistoryIsNotSubstitutedWithUserHistory() async throws {
        let transport = FixtureGatewayTransport([])
        let block = try await LiteLLMAdapter(transport: transport).fetchHistory(context(scope: .init(kind: .key, id: "fixture")), start: "2026-09-01", end: "2026-09-22", probe: false)
        XCTAssertEqual(block.issue, .unsupported)
        let count = await transport.requests.count; XCTAssertEqual(count, 0)
    }

    func testRateLimitCarriesRetryAfterWithoutRetrying() async throws {
        let transport = FixtureGatewayTransport([.init(status: 429, json: "{}", headers: ["Retry-After":"120"])])
        let block = try await LiteLLMAdapter(transport: transport).fetchSummary(context(scope: .init(kind: .user, id: "fixture-user")))
        guard case .rateLimited(let until) = block.issue else { return XCTFail("Expected rate limit") }
        XCTAssertGreaterThan(until!.timeIntervalSinceNow, 115)
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }

    func testAddressValidationKeepsDeploymentPathAndRejectsEmbeddedCredentials() throws {
        XCTAssertEqual(try GatewayAddress.normalize("https://EXAMPLE.com/proxy/").absoluteString, "https://example.com/proxy")
        XCTAssertNoThrow(try GatewayAddress.normalize("http://localhost:4000"))
        for address in ["http://example.com", "https://user:password@example.com", "https://example.com?key=secret", "file:///tmp/key"] {
            XCTAssertThrowsError(try GatewayAddress.normalize(address))
        }
    }

    func testRateLimitStopsCheckEvenWithExplicitUserID() async throws {
        let transport = FixtureGatewayTransport([.init(status: 429, json: "{}", headers: ["Retry-After": "120"])])
        var connection = context().connection; connection.explicitUserID = "fixture-user"
        let result = try await LiteLLMAdapter(transport: transport).checkConnection(.init(connection: connection, apiKey: "fixture-key"))
        XCTAssertTrue(result.usableScopes.isEmpty)
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testTokenOnlyModelsSortByUsageAndMissingModelBreakdownStaysPartial() async throws {
        let json = #"{"results":[{"date":"2026-09-01","metrics":{"total_tokens":300},"breakdown":{"model_groups":{"smaller":{"total_tokens":100},"bigger":{"total_tokens":200}}}},{"date":"2026-09-02","metrics":{"total_tokens":50}}],"metadata":{"has_more":false}}"#
        let adapter = LiteLLMAdapter(transport: FixtureGatewayTransport([.init(json: json)]))
        let result = try await adapter.fetchHistory(context(scope: .init(kind: .user, id: "fixture-user")), start: "2026-09-01", end: "2026-09-22")
        let history = try XCTUnwrap(result.value)
        XCTAssertTrue(history.complete)
        XCTAssertFalse(history.hasCompleteModelBreakdown)
        XCTAssertEqual(history.totals.totalTokens, 350)
        XCTAssertNil(history.totals.cost)
        XCTAssertEqual(history.models.map(\.name), ["bigger", "smaller"])
    }

    func testMalformedDecimalStringIsNotAcceptedAsMoney() async throws {
        let adapter = LiteLLMAdapter(transport: FixtureGatewayTransport([.init(json: #"{"user_id":"fixture-user","user_info":{"spend":"123abc"}}"#)]))
        let result = try await adapter.fetchSummary(context(scope: .init(kind: .user, id: "fixture-user")))
        XCTAssertEqual(result.issue, .invalidResponse)
    }
}
