import Foundation
import os

// MARK: - Antigravity Data Models

/// Antigravity GetUserStatus response.
struct AntigravityUserStatusResponse: Codable, Sendable {
    let userStatus: AntigravityUserStatus?
}

struct AntigravityUserStatus: Codable, Sendable {
    let planStatus: AntigravityPlanStatus?
    let cascadeModelConfigData: AntigravityCascadeData?
    let accountEmail: String?
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

/// Antigravity usage provider — discovers local language server process.
@Observable
@MainActor
final class AntigravityProvider: UsageProvider {

    let kind = ProviderKind.antigravity
    private(set) var isAvailable = false
    var isEnabled = true
    private(set) var snapshot: UsageSnapshot?
    private(set) var error: String?
    private(set) var isLoading = false

    // MARK: - Constants

    private static let getUserStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let getModelConfigsPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"
    private static let getUnleashDataPath = "/exa.language_server_pb.LanguageServerService/GetUnleashData"

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

    private var connectPort: Int?
    private var connectScheme: String?
    private var csrfToken: String?

    // MARK: - Constants (paths)

    private static let stateDbPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/Antigravity/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Windsurf/User/globalStorage/state.vscdb",
        ]
    }()

    /// Resolved path of the detected state.vscdb.
    private static var detectedDbPath: String? {
        stateDbPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Init

    init() {
        detectAvailability()
    }

    // MARK: - UsageProvider

    func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        // 1. Discover process
        DebugLog.info("[1/4] Finding Antigravity process…")
        guard let processInfo = await ProcessHelper.findAntigravityProcess() else {
            isAvailable = false
            error = "IDE not running"
            DebugLog.info("[1/4] No Antigravity process found")
            return
        }

        isAvailable = true
        csrfToken = processInfo.csrfToken
        DebugLog.info("[1/4] Found pid=\(processInfo.pid) httpPort=\(processInfo.httpPort.map(String.init) ?? "nil") csrf=\(String(processInfo.csrfToken.prefix(8)))…")

        // 2. Find connect port
        if connectPort == nil {
            DebugLog.info("[2/4] Discovering connect port…")
            connectPort = await discoverConnectPort(pid: processInfo.pid, httpPort: processInfo.httpPort)
            DebugLog.info("[2/4] Connect port: \(self.connectPort.map(String.init) ?? "nil")")
        }

        guard let port = connectPort else {
            error = "Could not find language server port"
            DebugLog.info("[2/4] Failed to discover any port")
            return
        }

        // 3. Fetch user status
        DebugLog.info("[3/4] Fetching GetUserStatus on port \(port)…")
        do {
            let statusResponse = try await fetchUserStatus(port: port)
            snapshot = Self.mapToSnapshot(statusResponse)
            DebugLog.info("[3/4] Success — \(self.snapshot?.modelQuotas.count ?? 0) model(s)")
        } catch {
            DebugLog.info("[3/4] GetUserStatus failed: \(error)")
            // 4. Fallback to GetCommandModelConfigs
            DebugLog.info("[4/4] Falling back to GetCommandModelConfigs…")
            do {
                let configsResponse = try await fetchModelConfigs(port: port)
                snapshot = Self.mapConfigsToSnapshot(configsResponse)
                DebugLog.info("[4/4] Fallback success — \(self.snapshot?.modelQuotas.count ?? 0) model(s)")
            } catch {
                connectPort = nil
                connectScheme = nil
                self.error = error.localizedDescription
                DebugLog.info("[4/4] Fallback also failed: \(error)")
            }
        }
    }

    // MARK: - Detection

    private func detectAvailability() {
        // Lightweight check: look for Antigravity app data, not running process.
        // Process discovery happens in refresh() which is async.
        isAvailable = Self.detectedDbPath != nil
    }

    // MARK: - Port Discovery

    private func discoverConnectPort(pid: Int, httpPort: Int?) async -> Int? {
        guard let token = csrfToken else { return nil }

        if let httpPort {
            DebugLog.info("  Probing extension_server_port \(httpPort) first…")
            if let scheme = await probePort(httpPort, token: token) {
                DebugLog.info("  extension_server_port \(httpPort) responded OK via \(scheme)")
                connectScheme = scheme
                return httpPort
            }
            DebugLog.info("  extension_server_port \(httpPort) did not respond")
        }

        let ports = await ProcessHelper.findListeningPorts(pid: pid)
        DebugLog.info("  lsof found \(ports.count) listening port(s): \(ports)")

        let probeTask = Task<(Int, String)?, Never> {
            for port in ports where port != httpPort {
                if Task.isCancelled { break }
                DebugLog.info("  Probing port \(port)…")
                if let scheme = await probePort(port, token: token) {
                    DebugLog.info("  Port \(port) responded OK via \(scheme)")
                    return (port, scheme)
                }
                DebugLog.info("  Port \(port) did not respond")
            }
            return nil
        }

        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(15))
            DebugLog.info("  Port probing timed out (15s)")
            probeTask.cancel()
        }

        let result = await probeTask.value
        timeoutTask.cancel()

        if let (port, scheme) = result {
            connectScheme = scheme
            return port
        }
        return httpPort
    }

    /// Probe a single port. Returns the working scheme ("http" or "https"), or nil.
    private func probePort(_ port: Int, token: String) async -> String? {
        for scheme in ["http", "https"] {
            guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(Self.getUnleashDataPath)") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
            request.httpBody = "{}".data(using: .utf8)
            request.timeoutInterval = 3

            do {
                _ = try await Self.sendInsecureRequest(request)
                return scheme
            } catch {
                DebugLog.info("  Probe \(scheme)://…:\(port) failed: \(error.localizedDescription)")
                continue
            }
        }
        return nil
    }

    // MARK: - API Calls

    private func fetchUserStatus(port: Int) async throws -> AntigravityUserStatusResponse {
        let data = try await makeRequest(port: port, path: Self.getUserStatusPath)
        DebugLog.info("  GetUserStatus raw (\(data.count) bytes): \(String(data: data.prefix(500), encoding: .utf8) ?? "<binary>")")
        return try JSONDecoder().decode(AntigravityUserStatusResponse.self, from: data)
    }

    private func fetchModelConfigs(port: Int) async throws -> AntigravityModelConfigsResponse {
        let data = try await makeRequest(port: port, path: Self.getModelConfigsPath)
        DebugLog.info("  GetModelConfigs raw (\(data.count) bytes): \(String(data: data.prefix(500), encoding: .utf8) ?? "<binary>")")
        return try JSONDecoder().decode(AntigravityModelConfigsResponse.self, from: data)
    }

    private func makeRequest(port: Int, path: String) async throws -> Data {
        guard let token = csrfToken else { throw ProviderError.notConfigured }

        // Use the scheme that worked during probing; fall back to trying both
        let schemes: [String]
        if let known = connectScheme {
            schemes = [known]
        } else {
            schemes = ["http", "https"]
        }

        var lastError: Error = ProviderError.apiFailed(statusCode: -1)
        for scheme in schemes {
            guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
            request.httpBody = Self.requestBody
            request.timeoutInterval = 8

            do {
                return try await Self.sendInsecureRequest(request)
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError
    }

    /// Send a request using completion-handler-based URLSession to avoid
    /// async delegate deadlock with self-signed TLS certs.
    private static func sendInsecureRequest(_ request: URLRequest) async throws -> Data {
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
                guard http.statusCode == 200 else {
                    continuation.resume(throwing: ProviderError.apiFailed(statusCode: http.statusCode))
                    return
                }
                continuation.resume(returning: data)
            }
            task.resume()
        }
    }

    // MARK: - Snapshot Mapping

    nonisolated static func mapToSnapshot(_ response: AntigravityUserStatusResponse) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastRefreshed = .now

        if let status = response.userStatus {
            snapshot.planName = status.planStatus?.planInfo?.planName
            snapshot.email = status.accountEmail

            if let configs = status.cascadeModelConfigData?.clientModelConfigs {
                snapshot.modelQuotas = configs.compactMap { config in
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
        }

        return snapshot
    }

    nonisolated static func mapConfigsToSnapshot(_ response: AntigravityModelConfigsResponse) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastRefreshed = .now

        if let configs = response.clientModelConfigs {
            snapshot.modelQuotas = configs.compactMap { config in
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

        return snapshot
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
