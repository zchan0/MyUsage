import Foundation
import os

/// Background-fetches `pricing/v1.json` from the project's GitHub
/// raw URL on a slow cadence (default: once per 7 days), with ETag
/// support so unchanged responses cost only one round-trip and no
/// disk write.
///
/// Never blocks the UI: callers fire-and-forget a `Task` that calls
/// `fetch(force:)`. The fetcher itself decides whether enough time
/// has passed since the last successful attempt; on failure it logs
/// and leaves the existing cached body untouched, so the user always
/// has either a remote table or the bundled fallback to fall back on.
@MainActor
final class PricingRemoteFetcher {

    static let shared = PricingRemoteFetcher()

    /// Where remote `pricing/v1.json` lives. Pinned to `main` so a
    /// release tag is not required to push a price correction.
    static let endpoint = URL(
        string: "https://raw.githubusercontent.com/zchan0/MyUsage/main/pricing/v1.json"
    )!

    /// Minimum interval between automatic fetches. `force=true` (the
    /// "Check for updates" button) bypasses this.
    static let throttleInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Highest `version` field this build understands. A `pricing.json`
    /// with a higher version is rejected so a future schema change
    /// can't poison the existing user base.
    static let supportedSchemaVersion = 1

    /// Currently in-flight fetch, if any. Reused so a UI button-press
    /// while the launch-time fetch is still running doesn't queue a
    /// second round-trip.
    private var inflight: Task<FetchOutcome, Never>?

    enum FetchOutcome: Sendable {
        case skippedDisabled
        case skippedThrottled
        case skippedInflight
        case notModified
        case updated(updatedAt: String?)
        case failed(reason: String)
    }

    // MARK: - Public

    /// Fetch the remote catalog. Honors the user's auto-update toggle
    /// and the 7-day throttle. Returns the outcome for tests / the
    /// "Check for updates" button UI. Safe to call from any actor.
    @discardableResult
    func fetch(force: Bool) async -> FetchOutcome {
        guard PricingLoader.shared.autoUpdatePricing else {
            return .skippedDisabled
        }
        if let existing = inflight {
            // Dedupe: a second caller (e.g. user clicked "Check for
            // updates" while the launch-time fetch was still running)
            // joins the in-flight task instead of triggering a second
            // round-trip.
            return await existing.value
        }
        if !force, !isThrottleElapsed() {
            return .skippedThrottled
        }
        let task = Task<FetchOutcome, Never> { [weak self] in
            guard let self else { return .failed(reason: "deallocated") }
            return await self.performFetch()
        }
        inflight = task
        defer { inflight = nil }
        return await task.value
    }

    // MARK: - Internals

    private func performFetch() async -> FetchOutcome {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = cachedETag() {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        // Short timeout: this is a small static file, and we never
        // want a hung fetch to delay the next refresh tick.
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return failed("non-HTTP response")
            }
            if http.statusCode == 304 {
                stampThrottle(now: .now)
                return .notModified
            }
            guard http.statusCode == 200 else {
                return failed("HTTP \(http.statusCode)")
            }

            // Verify schema BEFORE writing — we never want to poison
            // the cache with garbage that a later launch will keep
            // serving in lieu of bundled.
            let decoded: PricingFile
            do {
                decoded = try JSONDecoder().decode(PricingFile.self, from: data)
            } catch {
                return failed("decode: \(error.localizedDescription)")
            }
            guard decoded.version <= Self.supportedSchemaVersion else {
                return failed("schema version \(decoded.version) > supported \(Self.supportedSchemaVersion)")
            }

            let catalog = PricingCatalog(file: decoded)
            do {
                try writeCache(data: data, etag: http.value(forHTTPHeaderField: "Etag"))
            } catch {
                // Cache write failure is non-fatal — we still apply
                // the catalog in-memory for this session.
                Logger.pricing.error(
                    "pricing-remote cache write failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            let now = Date.now
            stampThrottle(now: now)
            PricingLoader.shared.applyFreshRemote(catalog, fetchedAt: now)
            return .updated(updatedAt: decoded.updated)
        } catch {
            return failed(error.localizedDescription)
        }
    }

    private func failed(_ reason: String) -> FetchOutcome {
        Logger.pricing.error("pricing-remote fetch failed: \(reason, privacy: .public)")
        return .failed(reason: reason)
    }

    // MARK: - Throttle

    private func isThrottleElapsed(now: Date = .now) -> Bool {
        guard let last = UserDefaults.standard.object(forKey: Keys.lastFetched) as? Date else {
            return true
        }
        return now.timeIntervalSince(last) >= Self.throttleInterval
    }

    private func stampThrottle(now: Date) {
        UserDefaults.standard.set(now, forKey: Keys.lastFetched)
    }

    /// Last successful fetch (or 304 hit) timestamp. Surfaced in the
    /// Cost tab's "Last fetched YYYY-MM-DD" line.
    var lastFetched: Date? {
        UserDefaults.standard.object(forKey: Keys.lastFetched) as? Date
    }

    // MARK: - Disk cache

    private func cachedETag() -> String? {
        guard let data = try? Data(contentsOf: PricingLoader.cachedRemoteETagURL),
              let etag = String(data: data, encoding: .utf8),
              !etag.isEmpty else {
            return nil
        }
        return etag
    }

    private func writeCache(data: Data, etag: String?) throws {
        let directory = PricingLoader.cachedRemoteFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try data.write(to: PricingLoader.cachedRemoteFileURL, options: .atomic)
        if let etag, let etagData = etag.data(using: .utf8) {
            try etagData.write(to: PricingLoader.cachedRemoteETagURL, options: .atomic)
        }
    }

    private enum Keys {
        static let lastFetched = "pricingRemoteLastFetched"
    }
}
