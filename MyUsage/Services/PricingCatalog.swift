import CryptoKit
import Foundation

/// Looks up `ModelPricing` by model name, using longest-prefix matching.
///
/// Pricing data comes from the freshest available source: the remote
/// LiteLLM-derived cache maintained by `PricingUpdater`, falling back to
/// `Resources/pricing.json` bundled with the app. A catalog value is
/// immutable; `PricingCatalog.shared` can be hot-swapped via `install`.
struct PricingCatalog: Sendable {
    private let models: [String: ModelPricing]
    /// Keys sorted by length (desc) for longest-prefix matching.
    private let sortedKeys: [String]

    let version: Int
    let updated: String?

    /// Stable digest of the price table itself (keys + input/output rates).
    /// Cost caches store this so a price update forces one recompute; it
    /// deliberately ignores `updated` so a daily re-fetch with identical
    /// prices doesn't churn the caches.
    let fingerprint: String

    init(file: PricingFile) {
        self.models = file.models
        self.sortedKeys = file.models.keys.sorted { $0.count > $1.count }
        self.version = file.version
        self.updated = file.updated

        let canonical = file.models
            .map { "\($0.key):\($0.value.input):\($0.value.output)" }
            .sorted()
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        self.fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Look up pricing for a model name. Matches the longest key that is a prefix of `modelName`.
    /// Returns nil if no key matches.
    func pricing(for modelName: String) -> ModelPricing? {
        let name = modelName.lowercased()
        if let exact = models[name] { return exact }
        for key in sortedKeys where name.hasPrefix(key) {
            return models[key]
        }
        return nil
    }

    /// Convenience: number of models in the catalog.
    var modelCount: Int { models.count }
}

// MARK: - Loading

extension PricingCatalog {

    enum LoadError: Error, LocalizedError {
        case resourceNotFound
        case decodingFailed(Error)

        var errorDescription: String? {
            switch self {
            case .resourceNotFound: "pricing.json not found in bundle"
            case .decodingFailed(let err): "pricing.json decode failed: \(err)"
            }
        }
    }

    /// Load the bundled `pricing.json`.
    static func loadBundled(bundle: Bundle? = nil) throws -> PricingCatalog {
        let resolvedBundle = bundle ?? AppResources.bundle ?? Bundle.main
        guard let url = resolvedBundle.url(forResource: "pricing", withExtension: "json") else {
            throw LoadError.resourceNotFound
        }
        return try load(from: url)
    }

    /// Load from a specific URL (useful for tests).
    static func load(from url: URL) throws -> PricingCatalog {
        let data = try Data(contentsOf: url)
        return try load(from: data)
    }

    /// Load from raw JSON data.
    static func load(from data: Data) throws -> PricingCatalog {
        do {
            let file = try JSONDecoder().decode(PricingFile.self, from: data)
            return PricingCatalog(file: file)
        } catch {
            throw LoadError.decodingFailed(error)
        }
    }

    /// Process-wide shared catalog. Seeds from the remote disk cache when
    /// one exists (any age — stale beats bundled, which is even staler),
    /// else the bundled JSON, else an empty catalog so `cost` returns 0
    /// everywhere rather than crashing. `PricingUpdater` hot-swaps a fresh
    /// remote catalog in via `install(_:)`.
    static var shared: PricingCatalog { store.current }

    /// Replace the live catalog (thread-safe). Called by `PricingUpdater`
    /// after a validated remote fetch.
    static func install(_ catalog: PricingCatalog) { store.replace(catalog) }

    private static let store = Store()

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var catalog: PricingCatalog

        init() {
            if let remote = PricingUpdater.loadCachedCatalog() {
                catalog = remote
            } else if let bundled = try? PricingCatalog.loadBundled() {
                catalog = bundled
            } else {
                catalog = PricingCatalog(file: PricingFile(version: 0, updated: nil, models: [:]))
            }
        }

        var current: PricingCatalog {
            lock.lock()
            defer { lock.unlock() }
            return catalog
        }

        func replace(_ new: PricingCatalog) {
            lock.lock()
            catalog = new
            lock.unlock()
        }
    }
}
