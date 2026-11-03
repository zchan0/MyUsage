import Foundation

/// Read-only app identity helpers used by network clients and the UI.
enum AppInfo {
    /// App version from Info.plist (`CFBundleShortVersionString`). Falls back to
    /// `"dev"` in non-bundled contexts (e.g. `swift run`).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Build number from Info.plist (`CFBundleVersion`). Falls back to `"0"`.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// `0.10.7 (19)` — version with build in parens. Lets the user confirm
    /// at a glance which exact build is running (two builds can share a
    /// version string during development).
    static var versionWithBuild: String {
        "\(version) (\(build))"
    }

}
