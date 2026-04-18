import Foundation

/// Looks up `ModelPricing` by model name, using longest-prefix matching.
///
/// Pricing data is loaded from `Resources/pricing.json` bundled with the app.
/// The catalog is immutable after construction; rebuild to pick up edits.
struct PricingCatalog: Sendable {
    private let models: [String: ModelPricing]
    /// Keys sorted by length (desc) for longest-prefix matching.
    private let sortedKeys: [String]

    let version: Int
    let updated: String?

    init(file: PricingFile) {
        self.models = file.models
        self.sortedKeys = file.models.keys.sorted { $0.count > $1.count }
        self.version = file.version
        self.updated = file.updated
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

    /// Process-wide shared catalog. Falls back to an empty catalog if the
    /// bundled JSON is missing or malformed — in that case `cost` returns 0
    /// everywhere rather than crashing.
    static let shared: PricingCatalog = {
        if let catalog = try? PricingCatalog.loadBundled() { return catalog }
        return PricingCatalog(file: PricingFile(version: 0, updated: nil, models: [:]))
    }()
}
