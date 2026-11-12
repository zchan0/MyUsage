import SwiftUI

/// A quiet data-state mark, separate from account and plan details.
struct StatuslineDataIndicator: View {
    let state: StatuslineDataState

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9))
            .foregroundStyle(state == .valid || state == .waiting ? Color.secondary : Color.orange)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .valid: "internaldrive"
        case .stale: "clock"
        case .notConnected: "link.badge.plus"
        case .waiting: "hourglass"
        case .invalid: "exclamationmark.circle"
        }
    }

    private var label: String {
        switch state {
        case .valid: "Local usage data"
        case .stale: "Usage data is old"
        case .notConnected: "Usage data is not connected"
        case .waiting: "Waiting for quota"
        case .invalid: "Usage data is unavailable"
        }
    }
}

typealias ClaudeDataIndicator = StatuslineDataIndicator

#Preview("Statusline data states") {
    HStack(spacing: 16) {
        StatuslineDataIndicator(state: .valid)
        StatuslineDataIndicator(state: .stale)
        StatuslineDataIndicator(state: .notConnected)
        StatuslineDataIndicator(state: .waiting)
        StatuslineDataIndicator(state: .invalid)
    }
    .padding(16)
}
