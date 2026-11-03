import Foundation

enum ProviderError: LocalizedError {
    case tokenRefreshFailed
    case apiFailed(statusCode: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .tokenRefreshFailed: "Token refresh failed"
        case .apiFailed(let code): "API error (\(code))"
        case .rateLimited(let retry):
            if let retry, retry > 0 {
                "Rate limited (retry in \(Self.formatRetryDelay(retry)))"
            } else {
                "Rate limited"
            }
        case .notConfigured: "Not configured"
        }
    }
    private static func formatRetryDelay(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let totalMinutes = Int((Double(total) / 60).rounded())
        if totalMinutes < 60 { return "~\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "~\(hours)h" : "~\(hours)h \(minutes)m"
    }
}
