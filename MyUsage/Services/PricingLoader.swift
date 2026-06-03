import Foundation
import os
import Observation

/// Where the currently-active pricing table came from.
/// - `.bundled`: the snapshot shipped with this app build.
/// - `.cachedRemote`: a previously-fetched remote table, served from
///   `~/Library/Caches/MyUsage/pricing-remote.json` because the user
///   is offline or the latest fetch attempt failed.
/// - `.freshRemote`: a remote table fetched during this app launch.
///
/// The associated `Date` is the file's `updated` field (when present)
/// or the fetch timestamp — whichever is more meaningful for the UI's
/// "Last fetched YYYY-MM-DD" line.
enum PricingSource: Equatable, Sendable {
    case bundled
    case cachedRemote(updatedAt: Date?, fetchedAt: Date)
    case freshRemote(updatedAt: Date?, fetchedAt: Date)
}

/// Owns the precedence `bundled → cachedRemote → freshRemote` and
/// keeps `PricingCatalog.shared` in sync with the active catalog so
/// cost math from any thread always reads the user's preferred
/// source. SwiftUI reads `.source` / `.autoUpdatePricing` /
/// `.optInDecided` for the Cost tab's pricing block.
@MainActor
@Observable
final class PricingLoader {

    static let shared = PricingLoader()

    // MARK: - Observable state

    /// What's currently driving cost numbers. Mirrored to
    /// `PricingCatalog.shared` whenever it changes.
    private(set) var source: PricingSource

    /// `pricing.json` `updated` field (ISO-ish "YYYY-MM-DD"). Shown as
    /// the build/fetched provenance under the Cost tab toggle.
    private(set) var bundledUpdated: String?

    /// User-toggleable: when off, all remote fetches are short-
    /// circuited and `source` is forced back to `.bundled`. Persists
    /// to `UserDefaults`.
    var autoUpdatePricing: Bool {
        didSet {
            UserDefaults.standard.set(autoUpdatePricing, forKey: Keys.autoUpdate)
            if !autoUpdatePricing {
                PricingCatalog.resetSharedToBundled()
                source = .bundled
            }
        }
    }

    /// Distinguishes "user has answered the first-run prompt" from
    /// "still need to ask". Fresh installs default to `true` so the
    /// prompt is upgrade-only, per spec § "Pricing source switch".
    var optInDecided: Bool {
        didSet {
            UserDefaults.standard.set(optInDecided, forKey: Keys.optInDecided)
        }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        // Default-on for fresh installs (no prior key present);
        // upgrades fall through to `false` until the first-run prompt
        // resolves. `register` covers the never-launched case; the
        // explicit `object(forKey:)` check catches mid-install
        // upgrades that set the toggle implicitly.
        defaults.register(defaults: [
            Keys.autoUpdate: true,
            Keys.optInDecided: false
        ])
        self.autoUpdatePricing = defaults.bool(forKey: Keys.autoUpdate)
        self.optInDecided = defaults.bool(forKey: Keys.optInDecided)

        // Start from the bundled snapshot so cost math has *some*
        // catalog even before the first remote fetch finishes.
        let bundled = (try? PricingCatalog.loadBundled())
            ?? PricingCatalog(file: PricingFile(version: 0, updated: nil, models: [:]))
        self.bundledUpdated = bundled.updated
        PricingCatalog.shared = bundled
        self.source = .bundled

        // Try to upgrade to a cached-remote table immediately if one
        // exists and auto-update is on. Cheap file read, no network.
        if autoUpdatePricing {
            loadCachedRemoteIfPresent()
        }
    }

    // MARK: - Cache I/O

    /// `~/Library/Caches/MyUsage/pricing-remote.json` — populated by
    /// `PricingRemoteFetcher` on successful fetches.
    nonisolated static var cachedRemoteFileURL: URL {
        ClaudeCostCache.defaultDirectory
            .appendingPathComponent("pricing-remote.json")
    }

    /// Sidecar file for the last-known ETag, so the next fetch can
    /// send `If-None-Match` and short-circuit on 304.
    nonisolated static var cachedRemoteETagURL: URL {
        ClaudeCostCache.defaultDirectory
            .appendingPathComponent("pricing-remote.etag")
    }

    private func loadCachedRemoteIfPresent() {
        let url = Self.cachedRemoteFileURL
        guard let data = try? Data(contentsOf: url) else { return }
        guard let catalog = try? PricingCatalog.load(from: data) else {
            Logger.pricing.error("Cached remote pricing.json failed to decode")
            return
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .now
        PricingCatalog.shared = catalog
        source = .cachedRemote(
            updatedAt: parseUpdated(catalog.updated),
            fetchedAt: mtime
        )
    }

    // MARK: - Public mutations

    /// Apply a freshly-fetched remote catalog. Called by
    /// `PricingRemoteFetcher` after the file has been written to disk.
    func applyFreshRemote(_ catalog: PricingCatalog, fetchedAt: Date) {
        PricingCatalog.shared = catalog
        source = .freshRemote(
            updatedAt: parseUpdated(catalog.updated),
            fetchedAt: fetchedAt
        )
    }

    /// User clicked "Check for updates" — bypass the weekly throttle.
    /// No-op when auto-update is off (the button is disabled in that
    /// case anyway).
    func checkForUpdatesNow() async {
        guard autoUpdatePricing else { return }
        await PricingRemoteFetcher.shared.fetch(force: true)
    }

    /// Resolve the first-run opt-in prompt. `allow=true` flips
    /// auto-update on and triggers a non-blocking background fetch;
    /// `allow=false` leaves auto-update off and stays on bundled.
    func resolveFirstRunOptIn(allow: Bool) {
        optInDecided = true
        autoUpdatePricing = allow
        if allow {
            Task { await PricingRemoteFetcher.shared.fetch(force: true) }
        }
    }

    // MARK: - Helpers

    private func parseUpdated(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    private enum Keys {
        static let autoUpdate = "pricingRemoteAutoUpdate"
        static let optInDecided = "pricingRemoteOptInDecided"
    }
}
