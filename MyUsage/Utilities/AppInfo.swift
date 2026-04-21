import Foundation

/// Read-only app identity helpers used by network clients and the UI.
enum AppInfo {
    /// App version from Info.plist (`CFBundleShortVersionString`). Falls back to
    /// `"dev"` in non-bundled contexts (e.g. `swift run`).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// User-Agent for Claude Code OAuth usage + refresh requests.
    ///
    /// Mirrors the shape the Claude CLI sends so Anthropic's edge treats us
    /// like a known client, while still identifying MyUsage for transparency.
    /// We pin the `claude-code/…` tag to the beta date we already declare via
    /// `anthropic-beta`, since probing the local `claude` CLI version on
    /// every request isn't worth the cost.
    static var claudeUserAgent: String {
        "claude-code/oauth-2025-04-20 (MyUsage/\(version))"
    }
}
