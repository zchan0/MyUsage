import Darwin
import Foundation

/// Display-only CLI profile cache. It cannot identify the owner of a statusline receipt.
struct ClaudeLocalAccount: Sendable, Equatable {
    let email: String?
    let planName: String?
    let cachedAt: Date?

    static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let root = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home
        return root.appendingPathComponent(".claude.json")
    }

    /// Read one bounded, user-owned regular file without following a symlink or changing it.
    static func read(from url: URL) -> Self? {
        guard url.isFileURL else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        let maxBytes = 4 * 1_048_576
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= maxBytes,
              let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Self? {
        // Decode only these profile fields; do not retain the document or other configuration.
        struct Document: Decodable {
            let oauthAccount: Profile?
        }
        struct Profile: Decodable {
            let emailAddress: String?
            let organizationType: String?
            let profileFetchedAt: Double?
        }
        guard let profile = try? JSONDecoder().decode(Document.self, from: data).oauthAccount else { return nil }
        let email = profile.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validEmail = email.flatMap {
            !$0.isEmpty && $0.utf8.count <= 320 && $0.contains("@")
                && !$0.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
                ? $0 : nil
        }
        let plan: String? = switch profile.organizationType {
        case "claude_pro": "Pro"
        case "claude_max": "Max"
        case "claude_ultra": "Ultra"
        case "claude_team": "Team"
        case "claude_enterprise": "Enterprise"
        case "claude_free": "Free"
        default: nil
        }
        guard validEmail != nil || plan != nil else { return nil }
        let cachedAt = profile.profileFetchedAt.flatMap {
            $0.isFinite && $0 > 0 && $0 <= 253_402_300_799_000 ? Date(timeIntervalSince1970: $0 / 1000) : nil
        }
        return Self(email: validEmail, planName: plan, cachedAt: cachedAt)
    }

    var helpText: String {
        var text = "Account details cached locally by Claude Code."
        if let cachedAt { text += " Cached \(cachedAt.formatted(date: .abbreviated, time: .standard))." }
        return text + " May be outdated."
    }
}
