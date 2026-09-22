import Foundation

struct GatewayRequestContext: Sendable {
    let connection: GatewayConnection
    let apiKey: String
}

protocol GatewayAdapter: Sendable {
    func checkConnection(_ context: GatewayRequestContext) async throws -> GatewayConnectionCheck
    func fetchSummary(_ context: GatewayRequestContext) async throws -> GatewayBlock<GatewaySummary>
    func fetchHistory(_ context: GatewayRequestContext, start: String, end: String, probe: Bool) async throws -> GatewayBlock<GatewayHistory>
}

enum GatewayAdapters {
    static func adapter(for vendor: GatewayVendor) -> any GatewayAdapter {
        switch vendor { case .litellm: LiteLLMAdapter() }
    }
}

protocol GatewayTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Credentials never follow redirects, including redirects to a login page.
private final class GatewaySessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GatewayURLTransport: GatewayTransport {
    private static let session = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return config
    }(), delegate: GatewaySessionDelegate(), delegateQueue: nil)

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host ?? ""
        try await GatewayRequestLimiter.shared.acquire(host)
        do {
            try Task.checkCancellation()
            let (data, response) = try await Self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw GatewayIssue.invalidResponse }
            await GatewayRequestLimiter.shared.release(host)
            return (data, response)
        } catch {
            await GatewayRequestLimiter.shared.release(host)
            throw error
        }
    }
}

enum GatewayAddress {
    static func normalize(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw GatewayIssue.invalidConfiguration }
        parts.scheme = parts.scheme?.lowercased(); parts.host = host.lowercased()
        let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
        guard parts.scheme == "https" || (parts.scheme == "http" && local) else { throw GatewayIssue.invalidConfiguration }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw GatewayIssue.invalidConfiguration }
        return url
    }
}

/// Shared across instances: a slow deployment gets at most two active usage requests.
actor GatewayRequestLimiter {
    static let shared = GatewayRequestLimiter()
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var active: [String: Int] = [:]
    private var waiting: [String: [Waiter]] = [:]
    func acquire(_ host: String) async throws {
        try Task.checkCancellation()
        if active[host, default: 0] < 2 { active[host, default: 0] += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[host, default: []].append(.init(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id, host: host) }
        }
    }
    func release(_ host: String) {
        if var queue = waiting[host], !queue.isEmpty {
            let next = queue.removeFirst(); waiting[host] = queue
            next.continuation.resume()
        } else {
            active[host] = max(0, active[host, default: 0] - 1)
        }
    }
    private func cancel(_ id: UUID, host: String) {
        guard let index = waiting[host]?.firstIndex(where: { $0.id == id }) else { return }
        waiting[host]?.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
