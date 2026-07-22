import SwiftUI

/// Enum representing each supported AI provider.
enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case claude = "claude"
    case codex = "codex"
    case cursor = "cursor"
    case antigravity = "antigravity"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        }
    }

    /// One-word name for tight spots (summary-tile captions) where
    /// "Claude Code · 5h" would overflow a 9pt line.
    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        }
    }

    /// Brand color for the provider.
    var accentColor: Color {
        switch self {
        case .claude: Color(red: 0.84, green: 0.52, blue: 0.36)     // Anthropic warm orange
        case .codex: Color(red: 0.29, green: 0.29, blue: 0.29)      // OpenAI dark gray
        case .cursor: Color(red: 0.38, green: 0.65, blue: 0.98)     // Cursor blue
        case .antigravity: Color(red: 0.18, green: 0.78, blue: 0.68) // Windsurf teal
        }
    }

    /// Color used as the *background fill* of the rounded brand-icon tile in
    /// the popover provider card. Tracks the canonical brand mark closely
    /// (matches the v7 mockup) — distinct from `accentColor`, which is kept
    /// as-is for backwards compatibility with menu-bar tinting and other
    /// callers that already calibrated against it.
    var brandTileColor: Color {
        switch self {
        case .claude:      Color(hue: 14.0/360.0,  saturation: 0.76, brightness: 0.92) // terracotta
        case .codex:       Color(hue: 220.0/360.0, saturation: 0.06, brightness: 0.30) // graphite
        case .cursor:      Color(hue: 0,           saturation: 0,    brightness: 0.12) // near-black
        case .antigravity: Color(hue: 257.0/360.0, saturation: 0.50, brightness: 0.72) // periwinkle
        }
    }

    /// Low-saturation rail tint used consistently in Overview and Detail.
    /// Risk remains encoded by the percent/forecast copy, so a provider does
    /// not switch visual identity when a limit crosses a threshold.
    var usageTint: Color {
        switch self {
        case .claude:      Color(red: 0.79, green: 0.43, blue: 0.29).opacity(0.82)
        case .codex:       Color(red: 0.48, green: 0.51, blue: 0.55).opacity(0.72)
        case .cursor:      Color(red: 0.31, green: 0.33, blue: 0.36).opacity(0.76)
        case .antigravity: Color(red: 0.50, green: 0.37, blue: 0.72).opacity(0.72)
        }
    }
}

/// Safety thresholds for limit pressure across all providers. Same scale used
/// for 5-hour, weekly, billing-cycle, on-demand, and per-model bars so the
/// reading is consistent across the popover.
enum LimitSafety {
    static let warnThreshold: Double = 75
    static let critThreshold: Double = 90

    enum Level: Comparable {
        case healthy, warn, crit

        /// Numeric weight so callers can `max(a, b)` two levels — used by
        /// `LimitBar.level` to take the higher of (current-usage band,
        /// projection-alarm band).
        var severity: Int {
            switch self {
            case .healthy: 0
            case .warn:    1
            case .crit:    2
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.severity < rhs.severity
        }
    }

    static func level(for percent: Double) -> Level {
        if percent >= critThreshold { return .crit }
        if percent >= warnThreshold { return .warn }
        return .healthy
    }
}
