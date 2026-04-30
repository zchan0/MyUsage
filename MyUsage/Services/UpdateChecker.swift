import Foundation
import os

/// Polls GitHub Releases on launch and surfaces a banner when a newer
/// tag is available. Discovery-only — the user clicks through to the
/// release page to download. We never auto-update because the .app is
/// ad-hoc signed and Sparkle's safety guarantees would be weakened.
///
/// Lives as a singleton because the popover header and the Settings →
/// About card both want to read the same observable state, and threading
/// it through `@Environment` would force every preview / test seed site
/// to construct one.
@Observable
@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()

    /// What we know about the latest GitHub release (only set when the
    /// remote tag is strictly newer than the running build).
    struct ReleaseInfo: Equatable, Sendable {
        let tag: String         // "v0.6.2"
        let version: String     // "0.6.2" (tag with leading "v" stripped)
        let url: URL            // html_url of the GitHub Release page
        let publishedAt: Date?
        /// Direct download URL for `MyUsage-X.X.X.zip` if present in the
        /// release's assets list. `nil` when the workflow didn't upload
        /// one — UI falls back to opening `url`.
        let zipAssetURL: URL?
    }

    /// `nil` while we haven't checked, the local build is current, or the
    /// check failed. Views read this to decide whether to render the
    /// "Update available" affordance.
    private(set) var updateAvailable: ReleaseInfo?

    // MARK: - Configuration

    /// Override hooks for tests.
    private let session: URLSession
    private let defaults: UserDefaults
    private let now: () -> Date

    /// Repo to query. Hard-coded to the canonical fork; if the project ever
    /// gets forked into multiple maintained branches we'd parameterize.
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/zchan0/MyUsage/releases/latest"
    )!

    /// Skip a check if we already ran one less than this long ago. GitHub's
    /// unauthenticated rate limit is 60 requests/hour, so 24h is generously
    /// under the cap — we only call once per launch anyway.
    private static let debounceInterval: TimeInterval = 60 * 60 * 24

    /// UserDefaults key for the debounce timestamp.
    private static let lastCheckKey = "MyUsage.lastUpdateCheckAt"

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { .now }
    ) {
        self.session = session
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Public entry points

    /// Calls `check()` only if we haven't run one in the last 24h. Safe to
    /// invoke on every launch.
    func checkIfNeeded() async {
        let last = defaults.double(forKey: Self.lastCheckKey)
        if last > 0, now().timeIntervalSince1970 - last < Self.debounceInterval {
            return
        }
        await check()
    }

    /// Forced refresh — used by the "Check now" affordance in Settings.
    func check() async {
        // `swift run` / unbundled builds report version "dev", which would
        // parse to all-zeros and falsely flag any GitHub release as newer.
        // Devs running from source already have HEAD; nothing to upgrade to.
        let local = AppInfo.version
        guard local != "dev", local.split(separator: ".").contains(where: { Int($0) != nil }) else {
            return
        }

        do {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MyUsage/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 200 else {
                Logger.general.info(
                    "Update check: HTTP \(http?.statusCode ?? -1, privacy: .public)"
                )
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            defaults.set(now().timeIntervalSince1970, forKey: Self.lastCheckKey)

            let remoteVersion = Self.stripTagPrefix(release.tagName)

            if Self.isNewer(remote: remoteVersion, local: local) {
                let url = URL(string: release.htmlUrl)
                    ?? URL(string: "https://github.com/zchan0/MyUsage/releases")!
                let zipURL = release.assets?
                    .first(where: { $0.name.hasSuffix(".zip") })
                    .flatMap { URL(string: $0.browserDownloadUrl) }
                updateAvailable = ReleaseInfo(
                    tag: release.tagName,
                    version: remoteVersion,
                    url: url,
                    publishedAt: release.publishedAt.flatMap(Self.parseDate),
                    zipAssetURL: zipURL
                )
                Logger.general.info(
                    "Update available: \(release.tagName, privacy: .public)"
                )
            } else {
                updateAvailable = nil
            }
        } catch {
            Logger.general.error(
                "Update check failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Pure helpers (testable)

    /// "v0.6.2" → "0.6.2"; "0.6.2" → "0.6.2".
    nonisolated static func stripTagPrefix(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Strict-numeric semver compare, tolerant of differing component
    /// counts and any pre-release suffix ("1.0.0-rc.1" → "1.0.0"). Returns
    /// true iff `remote` is strictly greater than `local`.
    nonisolated static func isNewer(remote: String, local: String) -> Bool {
        let r = numericPart(remote).split(separator: ".").compactMap { Int($0) }
        let l = numericPart(local).split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    nonisolated private static func numericPart(_ s: String) -> String {
        s.split(separator: "-").first.map(String.init) ?? s
    }

    nonisolated private static func parseDate(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
    }
}

/// Subset of the GitHub Release JSON we care about.
private struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    let publishedAt: String?
    let assets: [Asset]?

    struct Asset: Codable {
        let name: String
        let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}
