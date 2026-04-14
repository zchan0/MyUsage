import Foundation

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
    private var csrfToken: String?

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
        guard let processInfo = ProcessHelper.findAntigravityProcess() else {
            isAvailable = false
            error = "IDE not running"
            return
        }

        isAvailable = true
        csrfToken = processInfo.csrfToken

        // 2. Find connect port
        if connectPort == nil {
            connectPort = await discoverConnectPort(pid: processInfo.pid, httpPort: processInfo.httpPort)
        }

        guard let port = connectPort else {
            error = "Could not find language server port"
            return
        }

        // 3. Fetch user status
        do {
            let statusResponse = try await fetchUserStatus(port: port)
            snapshot = Self.mapToSnapshot(statusResponse)
        } catch {
            // 4. Fallback to GetCommandModelConfigs
            do {
                let configsResponse = try await fetchModelConfigs(port: port)
                snapshot = Self.mapConfigsToSnapshot(configsResponse)
            } catch {
                connectPort = nil  // Reset for next retry
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Detection

    private func detectAvailability() {
        isAvailable = ProcessHelper.findAntigravityProcess() != nil
    }

    // MARK: - Port Discovery

    private func discoverConnectPort(pid: Int, httpPort: Int?) async -> Int? {
        let ports = ProcessHelper.findListeningPorts(pid: pid)
        guard let token = csrfToken else { return nil }

        // Probe each port
        for port in ports {
            for scheme in ["https", "http"] {
                let urlString = "\(scheme)://127.0.0.1:\(port)\(Self.getUnleashDataPath)"
                guard let url = URL(string: urlString) else { continue }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
                request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
                request.httpBody = "{}".data(using: .utf8)
                request.timeoutInterval = 3

                do {
                    let session = Self.makeInsecureSession()
                    let (_, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        return port
                    }
                } catch {
                    continue
                }
            }
        }

        // Fallback to httpPort
        return httpPort
    }

    // MARK: - API Calls

    private func fetchUserStatus(port: Int) async throws -> AntigravityUserStatusResponse {
        let data = try await makeRequest(port: port, path: Self.getUserStatusPath)
        return try JSONDecoder().decode(AntigravityUserStatusResponse.self, from: data)
    }

    private func fetchModelConfigs(port: Int) async throws -> AntigravityModelConfigsResponse {
        let data = try await makeRequest(port: port, path: Self.getModelConfigsPath)
        return try JSONDecoder().decode(AntigravityModelConfigsResponse.self, from: data)
    }

    private func makeRequest(port: Int, path: String) async throws -> Data {
        guard let token = csrfToken else { throw ProviderError.notConfigured }

        // Try HTTPS first, then HTTP
        for scheme in ["https", "http"] {
            guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
            request.httpBody = Self.requestBody
            request.timeoutInterval = 10

            do {
                let session = Self.makeInsecureSession()
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw ProviderError.apiFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                return data
            } catch let error as ProviderError {
                throw error
            } catch {
                // Try next scheme
                continue
            }
        }

        throw ProviderError.apiFailed(statusCode: -1)
    }

    // MARK: - Insecure session for self-signed certs

    private static func makeInsecureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        let delegate = InsecureDelegate()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
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

// MARK: - Insecure TLS delegate

private final class InsecureDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
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
