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

    /// Accent color for the provider icon.
    var accentColor: Color {
        switch self {
        case .claude: Color(red: 0.65, green: 0.55, blue: 0.98)     // #a78bfa
        case .codex: Color(red: 0.29, green: 0.87, blue: 0.50)      // #4ade80
        case .cursor: Color(red: 0.38, green: 0.65, blue: 0.98)     // #60a5fa
        case .antigravity: Color(red: 0.18, green: 0.83, blue: 0.75) // #2dd4bf
        }
    }

    /// SF Symbol name for the provider.
    var iconName: String {
        switch self {
        case .claude: "brain.head.profile"
        case .codex: "terminal"
        case .cursor: "cursorarrow.click.2"
        case .antigravity: "sparkles"
        }
    }
}
