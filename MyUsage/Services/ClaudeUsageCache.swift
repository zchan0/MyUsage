import CryptoKit
import Foundation
import os

/// Disk cache for the `/api/oauth/usage` response so the Claude card can
/// render last-known numbers when the endpoint is unreachable (expired
/// token, 429, 5xx, offline) — see `specs/11-claude-data-sources.md`.
///
/// The cache file lives under `~/Library/Caches/MyUsage/` (OS-reclaimable,
/// not backed up, not synced). Payload carries a credential fingerprint so
/// we never show one account's numbers to another after an account switch.
enum ClaudeUsageCache {

    // MARK: - Schema

    /// Bump this when `Payload` changes shape. Older caches are silently
    /// discarded — the data is reconstructible from one fresh fetch, so
    /// migration is not worth the complexity.
    static let currentVersion = 1

    struct Payload: Codable, Sendable {
        /// Schema version; see `currentVersion`.
        let v: Int
        /// First 12 hex chars of SHA-256(`refreshToken`). Guards against
        /// serving one account's cache to another.
        let credentialFingerprint: String
        /// Wall-clock time when the server response was received. Drives
        /// the "Last refreshed N min ago" label.
        let fetchedAt: Date
        /// Verbatim OAuth endpoint response.
        let response: ClaudeUsageResponse
    }

    // MARK: - Paths

    /// Default on-disk location, `~/Library/Caches/MyUsage/claude-usage.json`.
    static let defaultFileURL: URL = defaultDirectory
        .appendingPathComponent("claude-usage.json")

    static let defaultDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("MyUsage", isDirectory: true)
    }()

    // MARK: - Fingerprint

    /// First 12 hex characters of SHA-256 of the credential's refresh token.
    ///
    /// Claude Code CLI rotates refresh tokens each time it refreshes the
    /// access token (roughly once a day for an active user), so this
    /// fingerprint shifts at the same cadence. Cache miss on rotation is
    /// invisible to the user: the next fetch fills a new cache in seconds.
    static func fingerprint(refreshToken: String) -> String {
        let digest = SHA256.hash(data: Data(refreshToken.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    // MARK: - Read

    /// Returns the cached payload, or `nil` if any of:
    /// - the file doesn't exist,
    /// - the file contents are not valid JSON,
    /// - the payload's schema version doesn't match `currentVersion`,
    /// - `matching` is non-nil and doesn't match `credentialFingerprint`.
    ///
    /// Never throws — callers should treat "no cache" and "unusable cache"
    /// identically.
    static func read(
        from url: URL = defaultFileURL,
        matching fingerprint: String? = nil
    ) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        guard payload.v == currentVersion else { return nil }
        if let fingerprint, payload.credentialFingerprint != fingerprint { return nil }
        return payload
    }

    // MARK: - Write

    /// Atomically writes the given response to `url`, creating intermediate
    /// directories as needed. Throws on filesystem / encode errors; callers
    /// should log and continue — cache is best-effort.
    static func write(
        response: ClaudeUsageResponse,
        fingerprint: String,
        at date: Date = .now,
        to url: URL = defaultFileURL
    ) throws {
        let payload = Payload(
            v: currentVersion,
            credentialFingerprint: fingerprint,
            fetchedAt: date,
            response: response
        )
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Codec

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
