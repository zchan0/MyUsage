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

    /// Brand color for the provider.
    var accentColor: Color {
        switch self {
        case .claude: Color(red: 0.84, green: 0.52, blue: 0.36)     // Anthropic warm orange
        case .codex: Color(red: 0.29, green: 0.29, blue: 0.29)      // OpenAI dark gray
        case .cursor: Color(red: 0.38, green: 0.65, blue: 0.98)     // Cursor blue
        case .antigravity: Color(red: 0.18, green: 0.78, blue: 0.68) // Windsurf teal
        }
    }
}
