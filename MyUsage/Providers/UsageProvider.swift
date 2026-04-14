import Foundation

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
}
