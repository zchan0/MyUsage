import Foundation
import os

/// Keeps model pricing current without app releases — the same data source
/// ccusage uses. Fetches LiteLLM's public price table, converts the entries
/// we care about (Anthropic + OpenAI coding models) to our per-million
/// schema, validates, caches to disk, and hot-swaps `PricingCatalog.shared`.
///
/// New models therefore price correctly the day LiteLLM lists them —
/// previously they silently cost $0 until we shipped a new pricing.json
/// (which is exactly how Fable usage vanished into "Other").
enum PricingUpdater {

    static let sourceURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    /// Re-fetch when the disk cache is older than this.
    static let maxAge: TimeInterval = 24 * 3600

    /// `PricingFile.version` written into remote-derived files. Matches the
    /// bundled schema version — the format is identical.
    static let remoteFileVersion = 2

    static let cacheFileURL = ClaudeCostCache.defaultDirectory
        .appendingPathComponent("pricing-remote.json")

    // MARK: - Startup load

    /// The validated remote cache from a previous run, or nil when absent /
    /// unreadable / implausible. Freshness is deliberately NOT checked here:
    /// a week-old remote table still beats the bundled file it superseded.
    static func loadCachedCatalog(from url: URL = cacheFileURL) -> PricingCatalog? {
        guard let catalog = try? PricingCatalog.load(from: url),
              isPlausible(catalog) else { return nil }
        return catalog
    }

    // MARK: - Refresh

    /// Fetch + install when the cache is stale. Never throws — pricing
    /// updates are best-effort and the bundled table is always there.
    /// Single-flight: concurrent callers coalesce into one fetch.
    static func refreshIfStale(now: Date = .now) async {
        guard cacheAge(now: now) ?? .infinity >= maxAge else { return }
        guard await gate.begin() else { return }
        defer { Task { await gate.end() } }

        do {
            let (data, response) = try await URLSession.shared.data(from: sourceURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Logger.general.error("Pricing fetch failed: non-200 response")
                return
            }
            let file = try convert(litellmData: data, fetchedAt: now)
            let catalog = PricingCatalog(file: file)
            guard isPlausible(catalog) else {
                Logger.general.error("Pricing fetch discarded: implausible catalog (\(catalog.modelCount, privacy: .public) models)")
                return
            }

            let encoded = try JSONEncoder().encode(file)
            try FileManager.default.createDirectory(
                at: cacheFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoded.write(to: cacheFileURL, options: .atomic)

            PricingCatalog.install(catalog)
            Logger.general.info("Pricing catalog refreshed: \(catalog.modelCount, privacy: .public) models")
        } catch {
            Logger.general.error("Pricing refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Conversion

    /// Convert LiteLLM's `model_prices_and_context_window.json` to our
    /// `PricingFile`. Uses JSONSerialization because the source mixes model
    /// entries with a `sample_spec` whose fields are documentation strings.
    static func convert(litellmData: Data, fetchedAt: Date = .now) throws -> PricingFile {
        guard let root = try JSONSerialization.jsonObject(with: litellmData) as? [String: Any] else {
            throw ConversionError.notADictionary
        }

        var models: [String: ModelPricing] = [:]
        for (key, value) in root {
            guard isRelevant(key: key),
                  let entry = value as? [String: Any],
                  let inputPerToken = entry["input_cost_per_token"] as? Double,
                  let outputPerToken = entry["output_cost_per_token"] as? Double,
                  inputPerToken > 0 || outputPerToken > 0
            else { continue }

            let cacheRead = entry["cache_read_input_token_cost"] as? Double
            let cacheWrite = entry["cache_creation_input_token_cost"] as? Double

            if key.hasPrefix("claude-") {
                models[key] = ModelPricing(
                    input: inputPerToken * 1_000_000,
                    output: outputPerToken * 1_000_000,
                    cacheWrite: cacheWrite.map { $0 * 1_000_000 },
                    cacheRead: cacheRead.map { $0 * 1_000_000 },
                    cachedInput: nil
                )
            } else {
                models[key] = ModelPricing(
                    input: inputPerToken * 1_000_000,
                    output: outputPerToken * 1_000_000,
                    cacheWrite: nil,
                    cacheRead: nil,
                    cachedInput: cacheRead.map { $0 * 1_000_000 }
                )
            }
        }

        let formatter = ISO8601DateFormatter()
        return PricingFile(
            version: remoteFileVersion,
            updated: formatter.string(from: fetchedAt),
            models: models
        )
    }

    /// Only bare model IDs for the providers we price locally. Keys with a
    /// provider path prefix ("openrouter/…", "bedrock/…") are duplicates of
    /// the bare entries with routing markup we'd have to strip — skip them.
    static func isRelevant(key: String) -> Bool {
        guard !key.contains("/") else { return false }
        return key.hasPrefix("claude-")
            || key.hasPrefix("gpt-")
            || key.hasPrefix("codex-")
            || key.hasPrefix("o3")
            || key.hasPrefix("o4")
    }

    enum ConversionError: Error {
        case notADictionary
    }

    /// Sanity gate before a remote table replaces anything: it must be a
    /// real price table, not an error page or a format change we silently
    /// mis-parsed. Checks known anchor models rather than just counting.
    static func isPlausible(_ catalog: PricingCatalog) -> Bool {
        catalog.modelCount >= 10
            && catalog.pricing(for: "claude-sonnet-4-5") != nil
            && catalog.pricing(for: "gpt-5") != nil
    }

    // MARK: - Internals

    private static func cacheAge(now: Date) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFileURL.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return now.timeIntervalSince(mtime)
    }

    /// Single-flight gate so overlapping refresh ticks don't stack fetches.
    private actor Gate {
        private var inFlight = false
        func begin() -> Bool {
            if inFlight { return false }
            inFlight = true
            return true
        }
        func end() { inFlight = false }
    }

    private static let gate = Gate()
}
