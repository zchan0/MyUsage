import Foundation

/// Why a refresh was started. Providers normally treat both cases the same;
/// credential-gated providers can reserve interactive authorization for a
/// deliberate user action.
enum UsageRefreshTrigger: Sendable, Equatable {
    case automatic
    case manual
}

/// Protocol that all usage providers must conform to.
@MainActor
protocol UsageProvider: AnyObject {
    /// The kind of provider.
    var kind: ProviderKind { get }

    /// Whether credentials are found on the device.
    var isAvailable: Bool { get }

    /// User-controlled toggle.
    var isEnabled: Bool { get set }

    /// Latest usage data, nil if never fetched.
    var snapshot: UsageSnapshot? { get }

    /// Last error message, nil if last fetch succeeded.
    var error: String? { get }

    /// Whether a fetch is in progress.
    var isLoading: Bool { get }

    /// Fetch/refresh usage data.
    func refresh() async

    /// Refresh with the initiating context. The default implementation keeps
    /// existing providers source-compatible and delegates to `refresh()`.
    func refresh(trigger: UsageRefreshTrigger) async
}

extension UsageProvider {
    func refresh(trigger: UsageRefreshTrigger) async {
        await refresh()
    }
}
