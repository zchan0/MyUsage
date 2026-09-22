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
    var id: ProviderID { get }
    var source: ProviderSource { get }
    var displayName: String { get }
    var shortName: String { get }
    var payload: ProviderPayload? { get }

    /// Whether credentials are found on the device.
    var isAvailable: Bool { get }

    /// User-controlled toggle.
    var isEnabled: Bool { get set }

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

/// Existing local/OAuth providers retain their original data model and parsers.
@MainActor
protocol BuiltinUsageProvider: UsageProvider {
    var kind: ProviderKind { get }
    var snapshot: UsageSnapshot? { get }
}

extension BuiltinUsageProvider {
    var id: ProviderID { .builtin(kind) }
    var source: ProviderSource { .builtin(kind) }
    var displayName: String { kind.displayName }
    var shortName: String { kind.shortName }
    var payload: ProviderPayload? { snapshot.map(ProviderPayload.builtin) }
}

extension UsageProvider {
    func refresh(trigger: UsageRefreshTrigger) async {
        await refresh()
    }
}
